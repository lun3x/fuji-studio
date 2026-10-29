// Historical diagnostic-only protocol spike; never shipping-core acceptance.
// Normal validation uses Tools/FujiCameraLaptop. No saved-setting or card writes.
import Foundation
import ImageCaptureCore
import ImageIO
import CryptoKit

func hex(_ value: UInt16) -> String { String(format: "0x%04X", value) }
func fail(_ reason: String) -> NSError { NSError(domain: reason, code: 1) }
func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset+1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[offset+$1]) << ($1*8) } }
    mutating func put(_ value: UInt32, at offset: Int, width: Int = 4) {
        for i in 0..<width { self[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
}
struct Reader {
    let data: Data
    var cursor = 0
    mutating func u16() throws -> UInt16 { guard cursor+2 <= data.count else { throw fail("truncated") }; defer { cursor += 2 }; return data.u16(cursor) }
    mutating func u32() throws -> UInt32 { guard cursor+4 <= data.count else { throw fail("truncated") }; defer { cursor += 4 }; return data.u32(cursor) }
    mutating func string() throws -> String {
        guard cursor < data.count else { throw fail("truncated") }
        let count = Int(data[cursor]); cursor += 1
        guard cursor+count*2 <= data.count else { throw fail("truncated") }
        defer { cursor += count*2 }
        if count == 0 { return "" }
        guard data[cursor+count*2-2..<cursor+count*2] == Data([0,0]),
              let result = String(data: data.subdata(in: cursor..<cursor+(count-1)*2), encoding: .utf16LittleEndian) else { throw fail("invalid-string") }
        return result
    }
    mutating func words() throws -> [UInt16] { let count = try u32(); guard count < 4096 else { throw fail("oversized") }; return try (0..<count).map { _ in try u16() } }
}
struct Options {
    let raw: URL?, directory: URL, trigger: UInt16?, patches: [(Int, UInt32)], cleanup: Bool, backup: Bool
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var raw: URL?, directory: URL?, trigger: UInt16?, patches: [(Int,UInt32)] = [], cleanup = false, backup = false
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--cleanup" { cleanup = true; continue }
            if key == "--backup" { backup = true; continue }
            guard !args.isEmpty else { throw fail("missing-argument") }
            let value = args.removeFirst()
            switch key {
            case "--raw": raw = URL(fileURLWithPath: value)
            case "--output": directory = URL(fileURLWithPath: value, isDirectory: true)
            case "--trigger": guard let number = UInt16(value), number <= 1 else { throw fail("invalid-trigger") }; trigger = number
            case "--set":
                let parts = value.split(separator: ":")
                guard parts.count == 2, let offset = Int(parts[0]), let number = Int64(parts[1]),
                      offset >= 513, (offset-513)%4 == 0, number >= Int64(Int32.min), number <= Int64(UInt32.max) else { throw fail("invalid-patch") }
                patches.append((offset, UInt32(truncatingIfNeeded: number)))
            default: throw fail("unknown-argument-\(key)")
            }
        }
        guard let directory, raw != nil || trigger == nil, raw != nil || patches.isEmpty, !backup || raw == nil else { throw fail("usage: --output DIRECTORY [--raw RAF] [--trigger 0|1] [--set BYTE_OFFSET:VALUE] [--cleanup] [--backup]") }
        self.raw = raw; self.directory = directory; self.trigger = trigger; self.patches = patches; self.cleanup = cleanup; self.backup = backup
    }
}
@MainActor final class Probe: NSObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    let options: Options
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var tx: UInt32 = 1
    var report: [String:Any] = ["savedSettingsWritten": false, "schema": "xe3-laptop-spike-v1"]
    var trace: [[String:Any]] = []
    var finished = false
    var pending: (PTPCommand, CheckedContinuation<PTPReply,Error>)?
    var commandToken: UInt = 0
    init(_ options: Options) { self.options = options; super.init() }
    func persist() {
        report["trace"] = trace
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: options.directory.appendingPathComponent("evidence-private.json"), options: .atomic)
        }
    }
    func log(_ message: String) { print("\(Date().formatted(.iso8601)) \(message)"); fflush(stdout) }
    func start() throws {
        guard !FileManager.default.fileExists(atPath: options.directory.path) else { throw fail("output-directory-exists") }
        try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        persist()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x101)!
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now()+30) { [weak self] in
            guard let self, !self.finished, self.camera?.hasOpenSession != true else { return }; self.finish("discovery-or-open-deadline")
        }
    }
    func finish(_ failure: String? = nil) {
        guard !finished else { return }; finished = true
        if let failure { report["failure"] = failure; log("Stopped: \(failure)") }
        persist()
        let end = {
            self.persist(); self.log("Evidence: \(self.options.directory.path)")
            exit(failure == nil && self.report["closeConfirmed"] as? Bool == true ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+15) {
            self.report["closeConfirmed"] = false; self.log("Closure not confirmed"); end()
        }
        if let camera, camera.hasOpenSession {
            camera.requestCloseSession(options: nil) { error in
                DispatchQueue.main.async {
                    self.report["closeConfirmed"] = error == nil
                    self.log("Closure confirmed: \(error == nil)"); end()
                }
            }
        } else { report["closeConfirmed"] = false; end() }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, device.usbVendorID == 0x04cb, let camera = device as? ICCameraDevice else { return }
        self.camera = camera; camera.delegate = self
        report["usbVendorID"] = device.usbVendorID; report["usbProductID"] = device.usbProductID
        log("Opening Fujifilm USB session")
        camera.requestOpenSession(options: nil) { error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("open-error-\((error! as NSError).code)"); return }
                Task { do { try await self.run(); self.finish() } catch { self.finish(String(describing: error)) } }
            }
        }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera, !finished { finish("removed") }
    }
    func command(_ opcode: UInt16, _ parameters: [UInt32] = [], _ data: Data? = nil) async throws -> PTPReply {
        guard !finished, pending == nil, let camera else { throw fail("session-unavailable") }
        let reads: Set<UInt16> = [0x1001,0x1005,0x1007,0x1008,0x1009,0x1014,0x1015]
        guard reads.contains(opcode) || [UInt16(0x900C),0x900D,0x100B].contains(opcode) ||
              (opcode == 0x1016 && (parameters == [0xD185] || parameters == [0xD183])) else { throw fail("operation-not-allowed") }
        guard (data?.count ?? 0) <= PTPCodec.maximumDataBytes else { throw fail("payload-too-large") }
        let submitted = PTPCommand(opcode: opcode, parameters: parameters, transactionID: tx); tx += 1
        let encoded = try PTPCodec.encode(submitted)
        commandToken += 1; let token = commandToken
        trace.append(["opcode":hex(opcode),"parameters":parameters,"outBytes":data?.count ?? 0,"started":Date().formatted(.iso8601)])
        persist(); log("Send \(hex(opcode)) \(parameters.map { String(format:"0x%X",$0) }) out=\(data?.count ?? 0)")
        return try await withCheckedThrowingContinuation { continuation in
            pending = (submitted, continuation)
            camera.requestSendPTPCommand(encoded, outData: data, sendCommandDelegate: self,
                didSendCommand: #selector(didSend(_:inData:response:error:contextInfo:)), contextInfo: UnsafeMutableRawPointer(bitPattern: token))
            DispatchQueue.main.asyncAfter(deadline: .now()+35) { [weak self] in
                guard let self, self.commandToken == token, let pending = self.pending, !self.finished else { return }
                self.pending = nil; self.report["uncertainCommand"] = hex(opcode); self.persist()
                self.finish("command-deadline-\(hex(opcode))")
                pending.1.resume(throwing: fail("command-deadline"))
            }
        }
    }
    @objc nonisolated func didSend(_ command: Data, inData: Data, response: Data, error: NSError?, contextInfo: UnsafeMutableRawPointer?) {
        let token = contextInfo.map { UInt(bitPattern: $0) }
        Task { @MainActor in self.receive(command, inData: inData, response: response, error: error, token: token) }
    }
    func receive(_ command: Data, inData: Data, response: Data, error: NSError?, token: UInt?) {
        guard token == commandToken, let pending, !finished else { return }
        self.pending = nil
        trace[trace.count-1]["inBytes"] = inData.count
        if response.count >= 12 { trace[trace.count-1]["response"] = hex(response.u16(6)); trace[trace.count-1]["wireTransactionID"] = response.u32(8) }
        trace[trace.count-1]["finished"] = Date().formatted(.iso8601); persist()
        do {
            if let error { throw error }
            let echo = try PTPCodec.validateCallbackCommand(command, for: pending.0)
            let reply = try PTPCodec.decodeFrameworkManaged(response: response, data: inData, for: pending.0, echoedCommand: echo)
            log("Received \(hex(pending.0.opcode)) \(hex(reply.responseCode)) bytes=\(inData.count)")
            pending.1.resume(returning: reply)
        } catch { pending.1.resume(throwing: error) }
    }
    func handles() async throws -> [UInt32] {
        let data = try await command(0x1007,[UInt32.max,0,0]).data
        guard data.count >= 4 else { throw fail("invalid-handles") }
        let count = Int(data.u32(0)); guard count <= 4096, data.count == 4+count*4 else { throw fail("invalid-handles") }
        let result = (0..<count).map { data.u32(4+$0*4) }
        guard Set(result).count == count, !result.contains(0), !result.contains(UInt32.max) else { throw fail("invalid-handles") }
        return result
    }
    func run() async throws {
        let identity = try await command(0x1001).data
        var reader = Reader(data: identity)
        _ = try reader.u16(); _ = try reader.u32(); _ = try reader.u16(); _ = try reader.string(); _ = try reader.u16()
        let ops = try reader.words(); _ = try reader.words(); let props = try reader.words(); _ = try reader.words(); _ = try reader.words()
        let make = try reader.string(), model = try reader.string(), firmware = try reader.string(); _ = try reader.string()
        report["manufacturer"] = make; report["model"] = model; report["firmware"] = firmware
        report["operations"] = ops.map(hex); report["properties"] = props.map(hex)
        guard make == "FUJIFILM", model == "X-E3", firmware == "1.30" else { throw fail("unmeasured-camera") }
        let mode = try await command(0x1015,[0xD16E]).data
        guard mode == Data([6,0]) else { throw fail("wrong-mode") }; report["usbMode"] = 6
        let before = try await handles(); report["beforeHandles"] = before; persist()
        guard before.isEmpty else { throw fail("preexisting-objects") }
        if options.backup {
            let info = try await command(0x1008,[0]).data
            guard info.count >= 12, info.u16(4) == 0x5000, info.u32(8) == 5660 else { throw fail("unmeasured-backup-info") }
            let backup = try await command(0x1009,[0]).data
            guard backup.count == 5660, backup.prefix(8) == Data("FUJIFILM".utf8),
                  String(decoding:backup[20..<52].prefix { $0 != 0 },as:UTF8.self) == "X-E3" else { throw fail("unmeasured-backup") }
            try backup.write(to:options.directory.appendingPathComponent("settings-backup-private.bin"))
            report["backupBytes"] = backup.count
            var properties: [[String:Any]] = []
            for code: UInt32 in [0x5005,0xD00B,0xD00C,0xD017] {
                do {
                    let value = try await command(0x1015,[code]).data
                    properties.append(["property":hex(UInt16(code)),"bytes":value.count,"hex":value.map { String(format:"%02x",$0) }.joined()])
                } catch PTPError.responseCode(let status) {
                    properties.append(["property":hex(UInt16(code)),"response":hex(status)])
                }
            }
            report["currentWBProperties"] = properties
            return
        }
        guard let rawURL = options.raw else { return }
        let raw = try Data(contentsOf: rawURL, options: .mappedIfSafe)
        guard raw.count > 112, raw.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8),
              String(decoding: raw[28..<60].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in:.whitespaces) == "X-E3",
              raw.count <= PTPCodec.maximumDataBytes else { throw fail("invalid-raw") }
        report["sourceSHA256"] = sha(raw); report["sourceBytes"] = raw.count; report["sourceFilename"] = rawURL.lastPathComponent
        var info = Data(repeating: 0, count: 52)
        info.put(0xF802, at:4, width:2); info.put(UInt32(raw.count), at:8)
        let filename = "FUP_FILE.dat"
        info.append(UInt8(filename.utf16.count+1))
        for unit in filename.utf16 { info.append(contentsOf:[UInt8(truncatingIfNeeded:unit),UInt8(unit>>8)]) }
        info.append(contentsOf:[0,0,0,0,0])
        _ = try await command(0x900C,[0,0,0],info)
        _ = try await command(0x900D,[],raw); report["uploadSucceeded"] = true; persist()
        let baseline = try await command(0x1015,[0xD185]).data
        guard !baseline.isEmpty, baseline.count <= 65536 else { throw fail("invalid-profile") }
        try baseline.write(to: options.directory.appendingPathComponent("baseline.bin"))
        report["baselineBytes"] = baseline.count; report["baselineSHA256"] = sha(baseline)
        log("Profile bytes=\(baseline.count), prefix=\(baseline.prefix(24).map { String(format:"%02x",$0) }.joined())")
        if baseline.count >= 513 {
            report["profileWords"] = stride(from:513,through:baseline.count-4,by:4).map { ["offset":$0,"signed":Int64(Int32(bitPattern:baseline.u32($0))),"unsigned":Int64(baseline.u32($0))] }
        }
        persist()
        if !options.patches.isEmpty {
            var candidate = baseline
            for (offset,value) in options.patches { guard offset <= baseline.count-4 else { throw fail("patch-outside-profile") }; candidate.put(value,at:offset) }
            try candidate.write(to: options.directory.appendingPathComponent("candidate.bin"))
            report["profileWriteIntent"] = true; persist()
            _ = try await command(0x1016,[0xD185],candidate)
            let readback = try await command(0x1015,[0xD185]).data
            try readback.write(to: options.directory.appendingPathComponent("readback.bin"))
            report["profileReadbackMatches"] = candidate == readback; persist()
            guard candidate == readback else { throw fail("profile-readback-mismatch") }
        }
        guard let trigger = options.trigger else { report["afterHandles"] = try await handles(); return }
        guard try await handles().isEmpty else { throw fail("object-before-trigger") }
        report["triggerIntent"] = trigger; persist()
        _ = try await command(0x1016,[0xD183],Data([UInt8(trigger),0])); report["triggerAcknowledged"] = true; persist()
        var output: UInt32?
        for _ in 0..<30 {
            let found = try await handles()
            guard found.count <= 1 else { throw fail("ambiguous-output") }
            if let handle = found.first { output = handle; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let output else { throw fail("output-timeout") }
        report["outputHandle"] = output; persist()
        let objectInfo = try await command(0x1008,[output]).data
        try objectInfo.write(to: options.directory.appendingPathComponent("object-info.bin"))
        guard objectInfo.count >= 52, objectInfo.u16(4) == 0x3801, objectInfo.u16(6) == 0,
              objectInfo.u32(8) > 0, objectInfo.u32(8) <= PTPCodec.maximumDataBytes else { throw fail("unexpected-output-info") }
        let storageID = objectInfo.u32(0)
        let storage = try await command(0x1005,[storageID]).data
        try storage.write(to: options.directory.appendingPathComponent("storage-info.bin"))
        guard storage.count >= 26 else { throw fail("invalid-storage") }
        report["storageType"] = storage.u16(0); report["filesystemType"] = storage.u16(2); report["storageAccess"] = storage.u16(4)
        guard try await handles() == [output] else { throw fail("ownership-changed") }
        let jpeg = try await command(0x1009,[output]).data
        guard jpeg.count == objectInfo.u32(8), try await handles() == [output],
              try await command(0x1008,[output]).data == objectInfo else { throw fail("output-changed") }
        try jpeg.write(to: options.directory.appendingPathComponent("output.JPG"))
        report["outputSHA256"] = sha(jpeg); report["outputBytes"] = jpeg.count
        guard let image = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [String:Any],
              let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String:Any],
              tiff[kCGImagePropertyTIFFModel as String] as? String == "X-E3" else { throw fail("invalid-jpeg-context") }
        report["outputWidth"] = metadata[kCGImagePropertyPixelWidth as String]
        report["outputHeight"] = metadata[kCGImagePropertyPixelHeight as String]
        report["outputOrientation"] = metadata[kCGImagePropertyOrientation as String] ?? 1
        report["afterHandles"] = [output]; persist()
        if options.cleanup {
            guard storage.u16(0) == 3, storage.u16(2) == 2, storage.u16(4) == 2 else { throw fail("unverified-virtual-storage") }
            guard try await handles() == [output], try await command(0x1008,[output]).data == objectInfo,
                  try await command(0x1005,[storageID]).data == storage,
                  sha(try await command(0x1009,[output]).data) == sha(jpeg), try await handles() == [output] else { throw fail("cleanup-ownership-changed") }
            report["deleteIntent"] = output; persist()
            _ = try await command(0x100B,[output,0])
            let remaining = try await handles(); report["afterCleanupHandles"] = remaining
            guard remaining.isEmpty else { throw fail("cleanup-not-empty") }; report["cleanupVerified"] = true
        }
    }
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable:Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { false }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }
}
@main struct Main {
    @MainActor static func main() {
        do { let probe = Probe(try Options()); try probe.start(); withExtendedLifetime(probe) { RunLoop.main.run() } }
        catch { fputs("\(error)\n",stderr); exit(2) }
    }
}
