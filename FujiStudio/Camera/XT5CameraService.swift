import Foundation

/// Diagnostic value, not a conversion-ready CameraServing implementation.
/// No private serial, bank names, opaque profile bytes or arbitrary error text are serialized.
struct XT5ProtocolEvidence: Sendable, Encodable {
    let schemaVersion = 2
    let observedAt: Date
    let model: String
    let firmware: String
    let standardVersion: UInt16
    let vendorExtensionID: UInt32
    let vendorExtensionVersion: UInt16
    let functionalMode: UInt16
    let operations: [String]
    let advertisedProperties: [String]
    var properties: [Property] = []
    var usbMode: UInt64?
    var probeMethod = "property descriptors"
    var candidateUSBMode: UInt64?
    var selectorBefore: UInt64?
    var selectorAfter: UInt64?
    var selectorUnchanged: Bool?
    let conversionValidated = false
    let evidenceScope = "Read-only standard datasets; vendor mappings and conversion remain unvalidated"

    struct Property: Sendable, Encodable {
        let code: String
        var outcome: String
        var descriptorBytes: Int?
        var dataType: String?
        var writable: Bool?
        var form: String?
        var allowedValues: [String]?
        var current: String?
        var value: String?
        var stage: String?
        var valueBytes: Int?
        var rawValueHex: String?
        var documentedEncoding: String?
        var candidateUnsigned: UInt64?
        var candidateSigned: Int64?
        var stringUTF16Units: Int?
    }
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// The gate spans the entire evidence read. Native transport remains responsible for generation,
/// timeout, cancellation, callback correlation and quarantine. This probe never reconnects/retries.
actor XT5ProtocolProbe {
    private let transport: any PTPTransport
    private let gate: SerialCameraGate
    private var nextTransaction: UInt32 = 1
    init(transport: any PTPTransport, gate: SerialCameraGate = SerialCameraGate()) {
        self.transport = transport; self.gate = gate
    }
    func readEvidence(onUpdate: @escaping @Sendable (XT5ProtocolEvidence) async -> Void = { _ in }) async throws -> XT5ProtocolEvidence {
        try await gate.withExclusiveAccess { try await self.readExclusively(onUpdate: onUpdate) }
    }
    private func deviceEvidence(requiring operations: [UInt16]) async throws -> XT5ProtocolEvidence {
        let info = try XT5RecipeCodec.deviceInfo(await read(0x1001))
        guard info.manufacturer == "FUJIFILM", info.model == "X-T5" else { throw XT5ProtocolError.unsupportedCamera }
        guard operations.allSatisfy(info.operations.contains) else { throw XT5ProtocolError.missingReadOperations }
        let firmware = info.firmware.range(of: "^[0-9]{1,4}(\\.[0-9]{1,4}){1,3}$", options: .regularExpression) != nil ? info.firmware : "unrecognized (redacted)"
        return XT5ProtocolEvidence(observedAt: Date(), model: "X-T5", firmware: firmware,
                                         standardVersion: info.standardVersion, vendorExtensionID: info.vendorExtensionID,
                                         vendorExtensionVersion: info.vendorExtensionVersion, functionalMode: info.functionalMode,
                                         operations: info.operations.map(Self.hex), advertisedProperties: info.properties.map(Self.hex))
    }
    private func readExclusively(onUpdate: @Sendable (XT5ProtocolEvidence) async -> Void) async throws -> XT5ProtocolEvidence {
        var report = try await deviceEvidence(requiring: [0x1014, 0x1015])
        await onUpdate(report)
        // Candidate property addresses from pinned research. No profile VALUE read before RAF upload.
        // At most 29 descriptors + 3 scalar/capability reads + DeviceInfo = 33 commands.
        let candidates: [UInt16] = [0xD16E, 0xD185, 0xD186, 0xD187, 0xD18C, 0xD18D] + Array(0xD18E...0xD1A4)
        for code in candidates where report.advertisedProperties.contains(Self.hex(code)) {
            try Task.checkCancellation()
            var observation = XT5ProtocolEvidence.Property(code: Self.hex(code), outcome: "descriptor decoded")
            do {
                let bytes = try await read(0x1014, property: code)
                observation.descriptorBytes = bytes.count
                let descriptor = try XT5RecipeCodec.propertyDescriptor(bytes, expectedCode: code)
                observation.dataType = Self.hex(descriptor.dataType)
                observation.writable = descriptor.writable
                // Opaque D185 and all string/name values are omitted, even if malformed camera
                // metadata labels their contents as scalar values.
                let numeric = code != 0xD185 && code != 0xD18D && (1...10).contains(descriptor.dataType)
                if numeric { observation.current = Self.hexBytes(descriptor.current.raw) }
                switch descriptor.form {
                case .none: observation.form = "none"
                case .range(let min, let max, let step):
                    observation.form = "range"
                    if numeric { observation.allowedValues = [min,max,step].map { Self.hexBytes($0.raw) } }
                case .enumeration(let values):
                    observation.form = "enumeration (\(values.count))"
                    if numeric { observation.allowedValues = values.map { Self.hexBytes($0.raw) } }
                }
                if code == 0xD16E || code == 0xD186 || code == 0xD187 {
                    let value = try XT5RecipeCodec.value(await read(0x1015, property: code), type: descriptor.dataType)
                    if code == 0xD16E, [2,4,6,8].contains(descriptor.dataType) {
                        report.usbMode = value.unsignedInteger
                        observation.value = Self.hexBytes(value.raw)
                    } else if code != 0xD16E, let text = value.string,
                              text.range(of: "^X-T5_[0-9]{4}$", options: .regularExpression) != nil {
                        observation.value = text
                    } else { observation.value = "unsupported representation (redacted)" }
                }
            } catch let error as XT5ProtocolError {
                observation.outcome = Self.safeError(error)
            } catch PTPError.responseCode(let response) {
                observation.outcome = "PTP response \(Self.hex(response))"
            }
            // Transport failures propagate and stop all further requests. No fallback type inference.
            report.properties.append(observation)
            await onUpdate(report)
        }
        return report
    }

    /// Firmware 4.31 rejected every vendor descriptor in phase A. Direct reads are a separate
    /// explicit experiment using pinned property encodings, never an inferred descriptor type.
    func readDirectValues(onUpdate: @escaping @Sendable (XT5ProtocolEvidence) async -> Void = { _ in }) async throws -> XT5ProtocolEvidence {
        try await gate.withExclusiveAccess { try await self.readDirectExclusively(onUpdate: onUpdate) }
    }
    private func readDirectExclusively(onUpdate: @Sendable (XT5ProtocolEvidence) async -> Void) async throws -> XT5ProtocolEvidence {
        var report = try await deviceEvidence(requiring: [0x1015])
        report.probeMethod = "direct values; descriptor types unavailable"
        await onUpdate(report)
        // 28 documented read addresses, then repeat the selector to observe stability.
        // No D185 value, D1A5 live-state read, object operation or setting write. Max 30 commands.
        let candidates: [UInt16] = [0xD16E, 0xD186, 0xD187, 0xD18C, 0xD18D] + Array(0xD18E...0xD1A4) + [0xD18C]
        var selectorReads = 0
        for code in candidates where report.advertisedProperties.contains(Self.hex(code)) {
            try Task.checkCancellation()
            if code == 0xD18C { selectorReads += 1 }
            var observation = XT5ProtocolEvidence.Property(code: Self.hex(code), outcome: "direct value observed; interpretation unvalidated")
            if code == 0xD18C { observation.stage = selectorReads == 1 ? "selector before" : "selector after" }
            do {
                let bytes = try await read(0x1015, property: code)
                observation.valueBytes = bytes.count
                guard bytes.count <= 512 else { throw XT5ProtocolError.oversized }
                try Self.observeDirectValue(bytes, code: code, observation: &observation)
                if code == 0xD16E { report.candidateUSBMode = observation.candidateUnsigned }
                if code == 0xD18C, let selector = observation.candidateUnsigned, (1...7).contains(selector) {
                    if selectorReads == 1 { report.selectorBefore = selector }
                    else { report.selectorAfter = selector }
                }
            } catch let error as XT5ProtocolError {
                observation.outcome = Self.safeError(error)
            } catch PTPError.responseCode(let response) {
                observation.outcome = "PTP response \(Self.hex(response))"
            }
            if let before = report.selectorBefore, let after = report.selectorAfter {
                report.selectorUnchanged = before == after
            }
            report.properties.append(observation)
            await onUpdate(report)
        }
        return report
    }

    private static func observeDirectValue(_ bytes: Data, code: UInt16, observation: inout XT5ProtocolEvidence.Property) throws {
        if [0xD186, 0xD187, 0xD18D].contains(code) {
            observation.documentedEncoding = "PTP UTF16LE string (candidate; pinned protocol references)"
            let text = try XT5RecipeCodec.value(bytes, type: 0xffff).string!
            observation.stringUTF16Units = text.utf16.count
            // Never serialize a bank name or arbitrary capability string, including malformed bytes.
            if code != 0xD18D, text.range(of: "^X-T5_[0-9]{4}$", options: .regularExpression) != nil {
                observation.value = text
            }
            return
        }
        if code == 0xD16E {
            observation.documentedEncoding = "unsigned LE, 1/2/4 bytes (candidate; pinned libfuji width dispatch)"
            guard [1,2,4].contains(bytes.count) else {
                observation.outcome = "unexpected mode width; payload omitted"
                return
            }
            observation.rawValueHex = hexBytes(bytes)
            observation.candidateUnsigned = XT5PropertyValue(raw: bytes, string: nil).unsignedInteger
            return
        }
        let signed: Set<UInt16> = [0xD193,0xD194,0xD19A,0xD19B,0xD19D,0xD19E,0xD19F,0xD1A0,0xD1A2]
        let unmapped: Set<UInt16> = [0xD18E,0xD18F,0xD1A3,0xD1A4]
        observation.documentedEncoding = unmapped.contains(code) ? "unmapped; raw two-byte observation only"
            : signed.contains(code) ? "INT16LE (candidate; pinned recipe documentation)"
            : "UINT16LE (candidate; pinned recipe documentation)"
        guard bytes.count == 2 else {
            observation.outcome = "unexpected property width; payload omitted"
            return
        }
        observation.rawValueHex = hexBytes(bytes)
        if unmapped.contains(code) { return }
        let word = UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
        if signed.contains(code) { observation.candidateSigned = Int64(Int16(bitPattern: word)) }
        else { observation.candidateUnsigned = UInt64(word) }
    }
    private func read(_ opcode: UInt16, property: UInt16? = nil) async throws -> Data {
        try Task.checkCancellation()
        let transaction = nextTransaction
        guard nextTransaction < UInt32.max else { throw PTPError.invalidParameters }
        nextTransaction += 1
        return try await transport.execute(PTPCommand(opcode: opcode, parameters: property.map { [UInt32($0)] } ?? [], transactionID: transaction), data: nil).data
    }
    private static func hex(_ value: UInt16) -> String { String(format: "0x%04X", value) }
    private static func hexBytes(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
    static func safeError(_ error: any Error) -> String {
        if let error = error as? XT5ProtocolError { return String(describing: error) }
        if let error = error as? PTPError {
            switch error {
            case .responseCode(let code): return "PTP response \(hex(code))"
            case .authorizationDenied: return "authorization denied or restricted"
            case .timeout: return "transport timeout"
            case .notConnected: return "session unavailable"
            case .sessionClosing: return "session closing or quarantined"
            default: return "transport failure (details redacted)"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "failure (details redacted)"
    }
}
