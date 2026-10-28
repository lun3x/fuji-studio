@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

/// Phase A safety tests only: these do not claim conversion or seven-bank support.
struct XT5ConversionTests {
    @Test func readOnlyProbeNeverUploadsReadsProfileBaselineOrWritesSettings() async throws {
        let wire = ProbeWire()
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.model == "X-T5")
        #expect(report.firmware == "4.20")
        #expect(report.usbMode == 6)
        #expect(report.conversionValidated == false)
        let commands = await wire.commands
        #expect(commands.map(\.opcode) == [0x1001,0x1014,0x1015,0x1014,0x1014,0x1014])
        #expect(commands.filter { $0.opcode == 0x1015 }.map(\.parameters) == [[0xD16E]])
        #expect(commands.map(\.transactionID) == [1,2,3,4,5,6])
        #expect(await wire.outboundPayloadCount == 0)
    }
    @Test func sanitizedEvidenceContainsNoSerialNamesOrOpaqueProfileBytes() async throws {
        let report = try await XT5ProtocolProbe(transport: ProbeWire()).readEvidence()
        let json = String(decoding: try report.json(), as: UTF8.self)
        #expect(!json.contains("PRIVATE-SERIAL"))
        #expect(!json.contains("PRIVATE-BANK"))
        #expect(!json.contains("PRIVATE-PROFILE"))
        #expect(json.contains("4.20"))
        #expect(report.properties.first { $0.code == "0xD18D" }?.current == nil)
    }
    @Test func unsupportedBodyMakesNoVendorReads() async throws {
        let wire = ProbeWire(model: "X100VI")
        await #expect(throws: XT5ProtocolError.unsupportedCamera) { try await XT5ProtocolProbe(transport: wire).readEvidence() }
        #expect(await wire.commands.count == 1)
    }
    @Test func unadvertisedPropertiesAreNeverRequested() async throws {
        let wire = ProbeWire(properties: [])
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.usbMode == nil)
        #expect(report.properties.isEmpty)
        #expect(await wire.commands.count == 1)
    }
    @Test func rejectedDescriptorIsReportedWithoutAssumingAType() async throws {
        let wire = ProbeWire(rejectMode: true)
        let report = try await XT5ProtocolProbe(transport: wire).readEvidence()
        #expect(report.usbMode == nil)
        #expect(report.properties.first?.outcome == "PTP response 0x200A")
        #expect(await wire.commands.filter { $0.opcode == 0x1015 }.isEmpty)
    }
    @Test func sessionFailureStopsProbeWithoutRetryOrConversion() async throws {
        let wire = ProbeWire(failSession: true)
        await #expect(throws: PTPError.notConnected) { try await XT5ProtocolProbe(transport: wire).readEvidence() }
        #expect(await wire.commands.count == 2)
    }
    @Test func repeatedProbeUsesFreshLogicalTransactions() async throws {
        let wire = ProbeWire(properties: [])
        let probe = XT5ProtocolProbe(transport: wire)
        _ = try await probe.readEvidence(); _ = try await probe.readEvidence()
        #expect(await wire.commands.map(\.transactionID) == [1,2])
    }
}

private actor ProbeWire: PTPTransport {
    var commands: [PTPCommand] = []
    var outboundPayloadCount = 0
    let model: String
    let properties: [UInt16]
    let rejectMode: Bool
    let failSession: Bool
    init(model: String = "X-T5", properties: [UInt16] = [0xD16E,0xD185,0xD18C,0xD18D], rejectMode: Bool = false, failSession: Bool = false) {
        self.model = model; self.properties = properties; self.rejectMode = rejectMode; self.failSession = failSession
    }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        commands.append(command)
        if data != nil { outboundPayloadCount += 1 }
        let payload: Data
        switch (command.opcode, command.parameters) {
        case (0x1001, []): payload = ProtocolProbeFixtures.deviceInfo(model: model, properties: properties)
        case (0x1014, [0xD16E]):
            if failSession { throw PTPError.notConnected }
            if rejectMode { throw PTPError.responseCode(0x200A) }
            payload = ProtocolProbeFixtures.modeDescriptor
        case (0x1015, [0xD16E]): payload = Data([6,0])
        case (0x1014, [0xD18C]): payload = ProtocolProbeFixtures.selectorDescriptor
        case (0x1014, [0xD18D]):
            payload = Data([0x8d,0xd1,0xff,0xff,1]) + ProtocolProbeFixtures.string("PRIVATE-BANK") + ProtocolProbeFixtures.string("PRIVATE-BANK") + Data([0])
        case (0x1014, [0xD185]):
            payload = Data([0x85,0xd1,0xff,0xff,1]) + ProtocolProbeFixtures.string("PRIVATE-PROFILE") + ProtocolProbeFixtures.string("PRIVATE-PROFILE") + Data([0])
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID,
                        wireTransactionID: command.transactionID + 8, correlation: .imageCaptureCoreCallback(echoedCommand: command),
                        responseCode: 0x2001, rawResponse: Data([12,0,0,0,3,0,1,32,9,0,0,0]), data: payload)
    }
}

@MainActor struct XT5ProbeLaunchTests {
    @Test func ordinaryLaunchDoesNotRequestCameraOrCreateEvidence() async throws {
        let driver = ControlledCameraDriver()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = XT5ProbeLaunchRunner(transport: ImageCaptureTransport(driver: driver), directory: directory)
        await runner.runIfRequested(arguments: ["FujiStudio"])
        #expect(driver.startCount == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func explicitLaunchHonorsAuthorizationFailureAndWritesSanitizedOutcomeOnce() async throws {
        let driver = ControlledCameraDriver()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = XT5ProbeLaunchRunner(transport: ImageCaptureTransport(driver: driver), directory: directory)
        let task = Task { await runner.runIfRequested(arguments: ["FujiStudio", "--xt5-read-only-probe"]) }
        await driver.waitForStartCount(1)
        driver.emit(.failed(.authorizationDenied))
        await task.value
        let text = try String(contentsOf: directory.appendingPathComponent("xt5-protocol-status.txt"), encoding: .utf8)
        #expect(text.contains("authorization denied or restricted"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("camera-diagnostics.txt").path))
        await runner.runIfRequested(arguments: ["FujiStudio", "--xt5-read-only-probe"])
        #expect(driver.startCount == 1)
    }
}

/// Direct-value observations remain candidates; all payloads here are synthetic grammar examples.
struct XT5DirectValueProbeTests {
    @Test func directReadsDoNotRequireDescriptorsOrIssueAnyWrites() async throws {
        let wire = DirectValueWire()
        let evidence = try await XT5ProtocolProbe(transport: wire).readDirectValues()
        #expect(evidence.probeMethod == "direct values; descriptor types unavailable")
        #expect(evidence.candidateUSBMode == 6)
        #expect(evidence.usbMode == nil)
        #expect(evidence.selectorBefore == 3)
        #expect(evidence.selectorAfter == 3)
        #expect(evidence.selectorUnchanged == true)
        #expect(evidence.conversionValidated == false)
        let commands = await wire.commands
        #expect(commands.map(\.opcode) == [0x1001] + Array(repeating: UInt16(0x1015), count: 9))
        #expect(commands.dropFirst().map(\.parameters) == [[0xD16E],[0xD186],[0xD187],[0xD18C],[0xD18D],[0xD18E],[0xD190],[0xD19D],[0xD18C]])
        #expect(await wire.outboundPayloadCount == 0)
    }
    @Test func reportsExactBytesAndDocumentedInterpretationWithoutInventingDescriptorTypes() async throws {
        let evidence = try await XT5ProtocolProbe(transport: DirectValueWire()).readDirectValues()
        let mode = try #require(evidence.properties.first { $0.code == "0xD16E" })
        #expect(mode.valueBytes == 4)
        #expect(mode.rawValueHex == "06000000")
        #expect(mode.dataType == nil)
        let highlight = try #require(evidence.properties.first { $0.code == "0xD19D" })
        #expect(highlight.rawValueHex == "F6FF")
        #expect(highlight.candidateSigned == -10)
        #expect(highlight.documentedEncoding == "INT16LE (candidate; pinned recipe documentation)")
        let unknown = try #require(evidence.properties.first { $0.code == "0xD18E" })
        #expect(unknown.rawValueHex == "FFFF")
        #expect(unknown.candidateSigned == nil)
        #expect(unknown.candidateUnsigned == nil)
    }
    @Test func exportsNoPrivateStringsButRecordsStrictStringShape() async throws {
        let evidence = try await XT5ProtocolProbe(transport: DirectValueWire()).readDirectValues()
        let text = String(decoding: try evidence.json(), as: UTF8.self)
        #expect(!text.contains("PRIVATE-BANK"))
        #expect(!text.contains("PRIVATE-SERIAL"))
        #expect(!text.contains("PRIVATE-CAPABILITY"))
        #expect(evidence.properties.first { $0.code == "0xD18D" }?.stringUTF16Units == 12)
        #expect(evidence.properties.first { $0.code == "0xD186" }?.value == "X-T5_0200")
        #expect(evidence.properties.first { $0.code == "0xD187" }?.value == nil)
    }
    @Test func malformedAndOversizedValuesAreReportedWithoutTruncationOrTypeGuess() async throws {
        let wire = DirectValueWire(overrides: [0xD16E: Data([6,0,0]), 0xD18D: Data([2,0,216,0,0]), 0xD190: Data(repeating: 65, count: 513)])
        let evidence = try await XT5ProtocolProbe(transport: wire).readDirectValues()
        #expect(evidence.candidateUSBMode == nil)
        #expect(evidence.properties.first { $0.code == "0xD16E" }?.rawValueHex == nil)
        #expect(evidence.properties.first { $0.code == "0xD18D" }?.outcome == "invalidString")
        #expect(evidence.properties.first { $0.code == "0xD190" }?.outcome == "oversized")
        #expect(evidence.properties.first { $0.code == "0xD190" }?.valueBytes == 513)
        #expect(!String(decoding: try evidence.json(), as: UTF8.self).contains(String(repeating: "41", count: 20)))
    }
    @Test func detectsSelectorChangeAndDoesNotAttemptRestoration() async throws {
        let wire = DirectValueWire(finalSelector: Data([4,0]))
        let evidence = try await XT5ProtocolProbe(transport: wire).readDirectValues()
        #expect(evidence.selectorUnchanged == false)
        #expect(evidence.selectorAfter == 4)
        #expect(await wire.commands.allSatisfy { [0x1001,0x1015].contains($0.opcode) })
    }
    @Test func unsupportedSelectorValueCannotEstablishUsableSelection() async throws {
        let evidence = try await XT5ProtocolProbe(transport: DirectValueWire(overrides: [0xD18C: Data([0,0])])).readDirectValues()
        #expect(evidence.selectorBefore == nil)
        #expect(evidence.selectorAfter == nil)
        #expect(evidence.selectorUnchanged == nil)
        #expect(evidence.properties.first { $0.code == "0xD18C" }?.rawValueHex == "0000")
    }
    @Test func cameraRejectionIsLocalButTransportFailureStopsAndPreservesPartialEvidence() async throws {
        let rejected = try await XT5ProtocolProbe(transport: DirectValueWire(rejectProperty: 0xD16E)).readDirectValues()
        #expect(rejected.properties.first?.outcome == "PTP response 0x2002")
        #expect(rejected.selectorUnchanged == true)
        let wire = DirectValueWire(failProperty: 0xD18C)
        let recorder = DirectEvidenceRecorder()
        await #expect(throws: PTPError.notConnected) {
            try await XT5ProtocolProbe(transport: wire).readDirectValues { await recorder.append($0) }
        }
        #expect(await wire.commands.count == 5)
        let partial = try #require(await recorder.values.last)
        #expect(partial.model == "X-T5")
        #expect(partial.candidateUSBMode == 6)
        #expect(partial.properties.count == 3)
    }
    @Test func skipsUnadvertisedPropertiesAndRequiresOnlyTheValueReadOperation() async throws {
        let wire = DirectValueWire(properties: [0xD16E], operations: [0x1001,0x1015])
        let report = try await XT5ProtocolProbe(transport: wire).readDirectValues()
        #expect(report.properties.count == 1)
        #expect(report.candidateUSBMode == 6)
        #expect(await wire.commands.count == 2)
        let missing = DirectValueWire(operations: [0x1001,0x1014])
        await #expect(throws: XT5ProtocolError.missingReadOperations) { try await XT5ProtocolProbe(transport: missing).readDirectValues() }
        #expect(await missing.commands.count == 1)
    }
}

private actor DirectEvidenceRecorder {
    var values: [XT5ProtocolEvidence] = []
    func append(_ value: XT5ProtocolEvidence) { values.append(value) }
}

private actor DirectValueWire: PTPTransport {
    var commands: [PTPCommand] = []
    var outboundPayloadCount = 0
    private var selectorReads = 0
    let properties: [UInt16]
    let operations: [UInt16]
    let overrides: [UInt16: Data]
    let finalSelector: Data?
    let rejectProperty: UInt16?
    let failProperty: UInt16?
    init(properties: [UInt16] = [0xD16E,0xD185,0xD186,0xD187,0xD18C,0xD18D,0xD18E,0xD190,0xD19D,0xD1A5],
         operations: [UInt16] = [0x1001,0x1015], overrides: [UInt16: Data] = [:], finalSelector: Data? = nil,
         rejectProperty: UInt16? = nil, failProperty: UInt16? = nil) {
        self.properties = properties; self.operations = operations; self.overrides = overrides
        self.finalSelector = finalSelector; self.rejectProperty = rejectProperty; self.failProperty = failProperty
    }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        commands.append(command)
        if data != nil { outboundPayloadCount += 1 }
        let payload: Data
        if command.opcode == 0x1001, command.parameters.isEmpty {
            payload = ProtocolProbeFixtures.deviceInfo(properties: properties, operations: operations)
        } else if command.opcode == 0x1014 { throw PTPError.responseCode(0x2002) }
        else {
            guard command.opcode == 0x1015, command.parameters.count == 1,
                  let code = UInt16(exactly: command.parameters[0]) else { throw PTPError.invalidParameters }
            if code == failProperty { throw PTPError.notConnected }
            if code == rejectProperty { throw PTPError.responseCode(0x2002) }
            if code == 0xD18C { selectorReads += 1 }
            if code == 0xD18C, selectorReads > 1, let finalSelector { payload = finalSelector }
            else if let overridden = overrides[code] { payload = overridden }
            else {
                switch code {
                case 0xD16E: payload = Data([6,0,0,0])
                case 0xD186: payload = ProtocolProbeFixtures.string("X-T5_0200")
                case 0xD187: payload = ProtocolProbeFixtures.string("PRIVATE-CAPABILITY")
                case 0xD18C: payload = Data([3,0])
                case 0xD18D: payload = ProtocolProbeFixtures.string("PRIVATE-BANK")
                case 0xD18E: payload = Data([255,255])
                case 0xD190: payload = Data([100,0])
                case 0xD19D: payload = Data([246,255])
                default: throw PTPError.invalidParameters
                }
            }
        }
        let rawResponse = Data([12,0,0,0,3,0,1,32]) + Data([UInt8(truncatingIfNeeded: command.transactionID + 8),0,0,0])
        return PTPReply(opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID,
                        wireTransactionID: command.transactionID + 8, correlation: .imageCaptureCoreCallback(echoedCommand: command),
                        responseCode: 0x2001, rawResponse: rawResponse, data: payload)
    }
}

@MainActor struct XT5DirectValueLaunchTests {
    @Test func explicitDirectFlagUsesNormalAuthorizationAndResetsItsOwnEvidenceFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale direct success".utf8).write(to: directory.appendingPathComponent("xt5-direct-values.json"))
        try Data("retained phase A evidence".utf8).write(to: directory.appendingPathComponent("xt5-protocol-evidence.json"))
        let driver = DeniedProbeLaunchDriver()
        let runner = XT5ProbeLaunchRunner(transport: ImageCaptureTransport(driver: driver), directory: directory)
        await runner.runIfRequested(arguments: ["--xt5-direct-values-probe"])
        #expect(driver.startCount == 1)
        let evidence = try String(contentsOf: directory.appendingPathComponent("xt5-direct-values.json"), encoding: .utf8)
        #expect(evidence == "{\"state\":\"awaiting device info\"}")
        let statusPath = directory.appendingPathComponent("xt5-direct-values-status.txt")
        try #require(FileManager.default.fileExists(atPath: statusPath.path))
        #expect(try String(contentsOf: statusPath, encoding: .utf8).contains("authorization denied or restricted"))
        #expect(try String(contentsOf: directory.appendingPathComponent("xt5-protocol-evidence.json"), encoding: .utf8) == "retained phase A evidence")
    }
    @Test func conflictingEngineeringFlagsNeverStartEitherWorkflow() async {
        for arguments in [["--xt5-direct-values-probe", "--xt5-read-only-probe"],
                          ["--xt5-direct-values-probe", "--camera-reconnect-probe"],
                          ["--xt5-direct-values-probe", "--xt5-read-only-probe", "--camera-reconnect-probe"]] {
            let driver = DeniedProbeLaunchDriver()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let transport = ImageCaptureTransport(driver: driver)
            await XT5ProbeLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: arguments)
            await CameraReconnectLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: arguments)
            #expect(driver.startCount == 0)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}

@MainActor private final class DeniedProbeLaunchDriver: CameraSessionDriver {
    var startCount = 0
    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void) {
        startCount += 1; events(.failed(.authorizationDenied))
    }
    func close(completion: @escaping @MainActor @Sendable () -> Void) { completion() }
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void) {
        completion(.failure(.notConnected))
    }
}
