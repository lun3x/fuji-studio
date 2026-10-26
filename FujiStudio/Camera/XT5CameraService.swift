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

// MARK: - Controlled seven-bank import; conversion remains unsupported

enum XT5BankImportIssue: Error, Sendable, Equatable {
    case sessionChanged, unsupportedContext, missingProperties, invalidSelector
    case selectorMismatch, bankChanged(Int), originalBankChanged, restorationTimeout
}

enum XT5SelectorRestoration: String, Sendable, Codable { case notNeeded, pending, verified, unconfirmed }

struct XT5BankImportEvidence: Sendable, Encodable {
    struct Comparison: Sendable, Encodable {
        let slot: Int
        let namesMatch: Bool
        let settingsMatch: Bool
    }
    let schemaVersion = 1
    let observedAt = Date()
    var model: String?
    var firmware: String?
    var capability: String?
    var originalSelector: Int?
    var restoredSelector: Int?
    var beforeSlots: [Int] = []
    var afterSlots: [Int] = []
    var comparisons: [Comparison] = []
    var restoration: XT5SelectorRestoration = .notNeeded
    var failure: String?
    var restorationFailure: String?
    var complete = false
    let conversionValidated = false
    let settingsPerBank = 23
    // No names, identifiers, hashes, or raw property values in public evidence.
}

struct XT5BankImportUpdate: Sendable {
    let evidence: XT5BankImportEvidence
    let snapshots: [RecipeSnapshot]
    let verificationSnapshots: [RecipeSnapshot]
}

struct XT5BankImportResult: Sendable {
    let evidence: XT5BankImportEvidence
    let recipes: [RecipeSnapshot]
}

struct XT5BankImportFailure: Error, Sendable {
    let evidence: XT5BankImportEvidence
}

/// Restricted to the actually observed X-T5 4.31 / _0200 protocol context. This importer owns no
/// connection/retry policy. The required validator binds every command to the original live session.
actor XT5BankImporter {
    private let transport: any PTPTransport
    private let sessionGeneration: UInt64
    private let sessionIdentity = UUID()
    private let validateSession: @Sendable () async throws -> Void
    private let settle: @Sendable (Duration) async throws -> Void
    private let cleanupTimeout: Duration
    private let gate: SerialCameraGate
    private var transaction: UInt32 = 1

    init(transport: any PTPTransport, sessionGeneration: UInt64,
         validateSession: @escaping @Sendable () async throws -> Void,
         settle: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         cleanupTimeout: Duration = .seconds(10),
         gate: SerialCameraGate = SerialCameraGate()) {
        self.transport = transport; self.sessionGeneration = sessionGeneration
        self.validateSession = validateSession; self.settle = settle; self.gate = gate
        self.cleanupTimeout = cleanupTimeout
    }

    func importRecipesVerified(onUpdate: @escaping @Sendable (XT5BankImportUpdate) async -> Void = { _ in }) async throws -> XT5BankImportResult {
        try await gate.withExclusiveAccess { try await self.importExclusively(onUpdate: onUpdate) }
    }

    private func importExclusively(onUpdate: @Sendable (XT5BankImportUpdate) async -> Void) async throws -> XT5BankImportResult {
        var evidence = XT5BankImportEvidence()
        var snapshots: [RecipeSnapshot] = []
        var verificationSnapshots: [RecipeSnapshot] = []
        var initial: RecipeSnapshot?
        var context: RecipeCameraContext?
        var selectorAttempted = false
        await onUpdate(XT5BankImportUpdate(evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots))
        do {
            let info = try XT5RecipeCodec.deviceInfo(await send(0x1001))
            guard info.manufacturer == "FUJIFILM", info.model == "X-T5", info.firmware == "4.31" else { throw XT5BankImportIssue.unsupportedContext }
            let properties: [UInt16] = [0xD16E,0xD186,0xD187,0xD18C,0xD18D] + Array(0xD18E...0xD1A4)
            guard [UInt16(0x1015),0x1016].allSatisfy(info.operations.contains), properties.allSatisfy(info.properties.contains) else { throw XT5BankImportIssue.missingProperties }
            guard try await send(0x1015, property: 0xD16E) == Data([6,0]) else { throw XT5BankImportIssue.unsupportedContext }
            for code: UInt16 in [0xD186,0xD187] {
                let key = try XT5RecipeCodec.value(await send(0x1015, property: code), type: 0xffff).string
                guard key == "X-T5_0200" else { throw XT5BankImportIssue.unsupportedContext }
            }
            let current = try await selectedSlot()
            let camera = RecipeCameraContext(model: "X-T5", firmware: "4.31", capability: "X-T5_0200", sessionIdentity: sessionIdentity, sessionGeneration: sessionGeneration)
            context = camera
            evidence.model = camera.model; evidence.firmware = camera.firmware; evidence.capability = camera.capability
            evidence.originalSelector = current
            initial = try await readBank(current, context: camera)
            for pass in 1...2 {
                for slot in 1...7 {
                    try Task.checkCancellation()
                    selectorAttempted = true // A failed reply cannot prove that a write had no effect.
                    evidence.restoration = .pending
                    try await select(slot)
                    let bank = try await readBank(slot, context: camera)
                    if pass == 1 {
                        snapshots.append(bank); evidence.beforeSlots.append(slot)
                        if slot == current, let initial, !sameContents(initial, bank) { throw XT5BankImportIssue.bankChanged(slot) }
                    } else {
                        verificationSnapshots.append(bank)
                        let before = snapshots[slot - 1]
                        let comparison = XT5BankImportEvidence.Comparison(slot: slot, namesMatch: before.importedName == bank.importedName,
                                                                          settingsMatch: before.importedSettings == bank.importedSettings)
                        evidence.afterSlots.append(slot); evidence.comparisons.append(comparison)
                        guard comparison.namesMatch && comparison.settingsMatch else { throw XT5BankImportIssue.bankChanged(slot) }
                    }
                    await onUpdate(XT5BankImportUpdate(evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots))
                }
            }
            try Task.checkCancellation()
        } catch { evidence.failure = Self.safeFailure(error) }

        if selectorAttempted, let initial, let context {
            // A cancelled parent cannot cancel this one bounded cleanup attempt. The operation gate
            // is held until cleanup returns. No reconnect; validator rejects a different/closed run.
            let cleanup = Task.detached { try await self.restoreBounded(initial, context: context) }
            do {
                try await cleanup.value
                evidence.restoration = .verified; evidence.restoredSelector = initial.slot
            } catch {
                evidence.restoration = .unconfirmed; evidence.restorationFailure = Self.safeFailure(error)
            }
        }
        if evidence.failure == nil && Task.isCancelled { evidence.failure = "cancelled" }
        evidence.complete = evidence.failure == nil && evidence.restoration == .verified && evidence.comparisons.count == 7
        await onUpdate(XT5BankImportUpdate(evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots))
        guard evidence.complete else { throw XT5BankImportFailure(evidence: evidence) }
        return XT5BankImportResult(evidence: evidence, recipes: snapshots)
    }

    private func restoreBounded(_ initial: RecipeSnapshot, context: RecipeCameraContext) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.select(initial.slot)
                let restored = try await self.readBank(initial.slot, context: context)
                guard self.sameContents(initial, restored) else { throw XT5BankImportIssue.originalBankChanged }
            }
            group.addTask {
                try await Task.sleep(for: self.cleanupTimeout)
                throw XT5BankImportIssue.restorationTimeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
    private func select(_ slot: Int) async throws {
        guard (1...7).contains(slot) else { throw XT5BankImportIssue.invalidSelector }
        _ = try await send(0x1016, property: 0xD18C, data: Data([UInt8(slot),0]))
        try await settle(.milliseconds(100))
        guard try await selectedSlot() == slot else { throw XT5BankImportIssue.selectorMismatch }
    }
    private func selectedSlot() async throws -> Int {
        let bytes = try await send(0x1015, property: 0xD18C)
        guard bytes.count == 2, bytes[bytes.startIndex + 1] == 0, (1...7).contains(bytes[bytes.startIndex]) else { throw XT5BankImportIssue.invalidSelector }
        return Int(bytes[bytes.startIndex])
    }
    private func readBank(_ slot: Int, context: RecipeCameraContext) async throws -> RecipeSnapshot {
        let name = try await send(0x1015, property: 0xD18D)
        guard name.count <= 511 else { throw XT5ProtocolError.oversized }
        var properties: [UInt16:Data] = [:]
        for code in UInt16(0xD18E)...0xD1A4 {
            let bytes = try await send(0x1015, property: code)
            guard bytes.count == 2 else { throw RecipeImportError.malformedProperty(code) }
            properties[code] = bytes
        }
        guard try await selectedSlot() == slot else { throw XT5BankImportIssue.selectorMismatch }
        return try XT5RecipeCodec.recipe(slot: slot, nameData: name, properties: properties, context: context, importedAt: Date())
    }
    private nonisolated func sameContents(_ a: RecipeSnapshot, _ b: RecipeSnapshot) -> Bool {
        a.importedName == b.importedName && a.importedSettings == b.importedSettings
    }
    private func send(_ opcode: UInt16, property: UInt16? = nil, data: Data? = nil) async throws -> Data {
        try Task.checkCancellation(); try await validateSession(); try Task.checkCancellation()
        guard transaction < UInt32.max else { throw PTPError.invalidParameters }
        let id = transaction; transaction += 1
        let reply = try await transport.execute(PTPCommand(opcode: opcode, parameters: property.map { [UInt32($0)] } ?? [], transactionID: id), data: data)
        try await validateSession()
        return reply.data
    }
    static func safeFailure(_ error: any Error) -> String {
        if let issue = error as? XT5BankImportIssue { return String(describing: issue) }
        if let issue = error as? RecipeImportError {
            switch issue {
            case .invalidSlot: return "invalid slot"
            case .incompletePropertyBlock: return "incomplete property block"
            case .malformedProperty(let code): return String(format: "malformed property 0x%04X", code)
            case .unsupportedRendering: return "unsupported rendering"
            }
        }
        return XT5ProtocolProbe.safeError(error)
    }
}
