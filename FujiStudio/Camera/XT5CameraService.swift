import Foundation
import CryptoKit

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

// MARK: - Authorized transient RAW upload / opaque baseline observation only

enum XT5RawBaselineIssue: Error, Sendable { case unsupportedContext, nonemptyObjectView, missingCapability, invalidBaselineLength, artifactWriteFailed }

struct XT5RawBaselineEvidence: Sendable, Encodable {
    let schemaVersion = 1
    let observedAt = Date()
    var model: String?
    var firmware: String?
    var capability: String?
    var rawBytes: Int?
    var width: Int?
    var height: Int?
    var orientation: Int?
    var preexistingObjectCount: Int?
    var newObjectCount: Int?
    var uploadInfoSucceeded = false
    var rawUploadSucceeded = false
    var baselineBytes: Int?
    var objectMetadataCount = 0
    var failure: String?
    var observationFailure: String?
    var sessionClosure = "not attempted"
    var sessionClosureFailure: String?
    let bufferCleanup = "unconfirmed"
    let conversionValidated = false
    var probeFinished = false
    var batchTrialCaptured = false
    var batchProfileWriteAttempted = false
    var batchProfileWriteAccepted = false
    var batchProfileReadbackMatches = false
    var unchangedConversion: XT5UnchangedConversionObservation?
    var readOnlyRecovery = false
    var quarantineRequested = false
    var exactCleanup: XT5ExactCleanupObservation?
    var filmProbe: XT5FilmProbeObservation?
}

struct XT5RawBaselineFailure: Error, Sendable { let evidence: XT5RawBaselineEvidence }

/// One original payload. Follows the pinned transient upload path only after a truly empty
/// object view. Generic new handles never prove ownership; only the explicit preserved-proof path may delete.
actor XT5RawBaselineProbe {
    private struct Manifest: Encodable {
        struct ObjectCapture: Encodable {
            let handle: UInt32
            let phase: String
            let byteCount: Int?
            let file: String?
            let failure: String?
        }
        let sourceSHA256: String
        var beforeHandles: [UInt32]?
        var afterHandles: [UInt32]?
        var uploadInfoResponseParameters: [UInt32]?
        var uploadResponseParameters: [UInt32]?
        var objects: [ObjectCapture] = []
    }
    private let transport: any PTPTransport
    private let validateSession: @Sendable () async throws -> Void
    private let closeSession: @Sendable () async throws -> Void
    private let gate: SerialCameraGate
    private let experiment: XT5BaselineExperiment
    private let pollWait: @Sendable () async throws -> Void
    private var transaction: UInt32 = 1
    init(transport: any PTPTransport, validateSession: @escaping @Sendable () async throws -> Void,
         closeSession: @escaping @Sendable () async throws -> Void, gate: SerialCameraGate = SerialCameraGate(),
         experiment: XT5BaselineExperiment = .baselineOnly,
         pollWait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.transport = transport; self.validateSession = validateSession; self.closeSession = closeSession; self.gate = gate
        self.experiment = experiment; self.pollWait = pollWait
    }
    func capture(raw: PreparedRAW, directory: URL,
                 onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void = { _ in }) async throws -> XT5RawBaselineEvidence {
        try await gate.withExclusiveAccess { try await self.captureExclusively(raw: raw, directory: directory, conversionTrigger: self.experiment == .unchangedTrigger0 ? 0 : nil, onUpdate: onUpdate) }
    }
    func captureFilmOnly(raw: PreparedRAW, reference: XT5FilmProbeReference, directory: URL,
                         onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void = { _ in }) async throws -> XT5RawBaselineEvidence {
        var initial = XT5RawBaselineEvidence(); initial.quarantineRequested = true; initial.filmProbe = XT5FilmProbeObservation()
        let evidence = initial
        return try await gate.withExclusiveAccess {
            try await self.captureExclusively(raw: raw, directory: directory, initialEvidence: evidence,
                conversionTrigger: 1, quarantineOutput: true, filmReference: reference, onUpdate: onUpdate)
        }
    }
    /// Internal trial entry used only by the private batch owner holding its outer gate. It
    /// explicitly leaves the session open; it must never fabricate a native close per trial.
    func captureBatchTrial(raw: PreparedRAW, patch: XT5FiniteRecipePatch, directory: URL,
                           onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void) async throws -> XT5RawBaselineEvidence {
        var initial = XT5RawBaselineEvidence(); initial.quarantineRequested = true
        return try await captureExclusively(raw: raw, directory: directory, initialEvidence: initial,
            conversionTrigger: 1, quarantineOutput: true, batchPatch: patch, closeAfterCapture: false, onUpdate: onUpdate)
    }
    /// Only the controller-authorized preserved phase-G output can pass this cleanup path.
    /// The permit remains held through exact cleanup, upload, trigger, observation and native close.
    func captureTriggerOne(after target: XT5ExactCleanupTarget, raw: PreparedRAW, directory: URL,
                           onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void = { _ in }) async throws -> XT5RawBaselineEvidence {
        try await gate.withExclusiveAccess { try await self.cleanupThenCapture(target: target, raw: raw, directory: directory, onUpdate: onUpdate) }
    }
    private func cleanupThenCapture(target: XT5ExactCleanupTarget, raw: PreparedRAW, directory: URL,
                                    onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void) async throws -> XT5RawBaselineEvidence {
        var evidence = XT5RawBaselineEvidence(); evidence.exactCleanup = XT5ExactCleanupObservation(); evidence.quarantineRequested = true
        do {
            _ = try target.validateLocal(raw: raw)
            guard raw.metadata.cameraModel == "X-T5" else { throw XT5RawBaselineIssue.unsupportedContext }
            let info = try XT5RecipeCodec.deviceInfo(await send(0x1001).data)
            guard info.manufacturer == "FUJIFILM", info.model == "X-T5", info.firmware == "4.31" else { throw XT5RawBaselineIssue.unsupportedContext }
            guard [UInt16(0x1005),0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D].allSatisfy(info.operations.contains),
                  [UInt16(0xD16E),0xD183,0xD185,0xD186,0xD187].allSatisfy(info.properties.contains) else { throw XT5RawBaselineIssue.missingCapability }
            guard try await send(0x1015, parameters: [0xD16E]).data == Data([6,0]) else { throw XT5RawBaselineIssue.unsupportedContext }
            for code: UInt32 in [0xD186,0xD187] {
                guard try XT5RecipeCodec.value(await send(0x1015, parameters: [code]).data, type: 0xffff).string == "X-T5_0200" else { throw XT5RawBaselineIssue.unsupportedContext }
            }
            evidence.model = "X-T5"; evidence.firmware = "4.31"; evidence.capability = "X-T5_0200"
            let beforeCleanup = evidence
            let cleanup = XT5ExactOutputCleanup(send: { opcode, parameters, data in
                guard data == nil, [UInt16(0x1005),0x1007,0x1008,0x1009,0x100B].contains(opcode),
                      opcode != 0x100B || parameters == [target.handle,0] else { throw PTPError.invalidParameters }
                return try await self.send(opcode, parameters: parameters)
            })
            let result = await cleanup.run(target: target, raw: raw, directory: directory) { partial in
                var report = beforeCleanup; report.exactCleanup = partial; await onUpdate(report)
            }
            evidence.exactCleanup = result
            guard result.emptyViewVerified && result.failure == nil else { throw XT5ExactCleanupIssue.viewNotEmpty }
        } catch {
            evidence.failure = evidence.exactCleanup?.failure ?? Self.safeFailure(error)
            let close = Task.detached { try await self.closeSession() }
            do { try await close.value; evidence.sessionClosure = "confirmed" }
            catch { evidence.sessionClosure = "unconfirmed"; evidence.sessionClosureFailure = Self.safeFailure(error) }
            await onUpdate(evidence)
            throw XT5RawBaselineFailure(evidence: evidence)
        }
        // No nested gate and no early close: only successful exact deletion + empty enumeration
        // reaches the existing upload path. Its ordinary empty-view check is repeated before upload.
        return try await captureExclusively(raw: raw, directory: directory, initialEvidence: evidence,
                                            conversionTrigger: 1, quarantineOutput: true, onUpdate: onUpdate)
    }
    func recoverExistingOutput(raw: PreparedRAW, directory: URL, quarantine: Bool = false,
                               onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void = { _ in }) async throws -> XT5RawBaselineEvidence {
        try await gate.withExclusiveAccess { try await self.recoverExclusively(raw: raw, directory: directory, quarantine: quarantine, onUpdate: onUpdate) }
    }
    private func recoverExclusively(raw: PreparedRAW, directory: URL, quarantine: Bool,
                                    onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void) async throws -> XT5RawBaselineEvidence {
        var evidence = XT5RawBaselineEvidence(); evidence.readOnlyRecovery = true; evidence.quarantineRequested = quarantine
        do {
            guard raw.metadata.cameraModel == "X-T5" else { throw XT5RawBaselineIssue.unsupportedContext }
            guard try ResourceChecksum.sha256(raw.fileURL) == raw.sha256 else { throw ResourceError.checksumMismatch }
            let info = try XT5RecipeCodec.deviceInfo(await send(0x1001).data)
            guard info.manufacturer == "FUJIFILM", info.model == "X-T5", info.firmware == "4.31" else { throw XT5RawBaselineIssue.unsupportedContext }
            guard [UInt16(0x1007),0x1008,0x1009,0x1015].allSatisfy(info.operations.contains),
                  [UInt16(0xD16E),0xD186,0xD187].allSatisfy(info.properties.contains) else { throw XT5RawBaselineIssue.missingCapability }
            guard try await send(0x1015, parameters: [0xD16E]).data == Data([6,0]) else { throw XT5RawBaselineIssue.unsupportedContext }
            for code: UInt32 in [0xD186,0xD187] {
                guard try XT5RecipeCodec.value(await send(0x1015, parameters: [code]).data, type: 0xffff).string == "X-T5_0200" else { throw XT5RawBaselineIssue.unsupportedContext }
            }
            evidence.model = "X-T5"; evidence.firmware = "4.31"; evidence.capability = "X-T5_0200"
            evidence.width = raw.metadata.recordedGeometry.width; evidence.height = raw.metadata.recordedGeometry.height; evidence.orientation = raw.metadata.orientation
            let beforeRecovery = evidence
            let observer = XT5UnchangedConversionProbe(send: { opcode, parameters, data in
                // Defense in depth: recovery cannot submit a mutation even if validation changes.
                guard [UInt16(0x1005),0x1007,0x1008,0x1009].contains(opcode), data == nil else { throw PTPError.invalidParameters }
                return try await self.send(opcode, parameters: parameters)
            }, pollWait: pollWait)
            let result = await observer.run(raw: raw, directory: directory, canReadStorage: info.operations.contains(0x1005), recovery: true, quarantine: quarantine) { partial in
                var report = beforeRecovery; report.unchangedConversion = partial; report.preexistingObjectCount = partial.existingHandleCount
                await onUpdate(report)
            }
            evidence.unchangedConversion = result; evidence.preexistingObjectCount = result.existingHandleCount
            guard (result.jpegRetained || (quarantine && result.quarantineCaptured)) && result.failure == nil else { throw XT5UnchangedConversionFailure(observation: result) }
        } catch { evidence.failure = Self.safeFailure(error) }
        await onUpdate(evidence)
        let close = Task.detached { try await self.closeSession() }
        do { try await close.value; evidence.sessionClosure = "confirmed" }
        catch { evidence.sessionClosure = "unconfirmed"; evidence.sessionClosureFailure = Self.safeFailure(error) }
        let captured = evidence.unchangedConversion?.jpegRetained == true || (quarantine && evidence.unchangedConversion?.quarantineCaptured == true)
        evidence.probeFinished = evidence.failure == nil && captured && evidence.sessionClosure == "confirmed"
        await onUpdate(evidence)
        guard evidence.probeFinished else { throw XT5RawBaselineFailure(evidence: evidence) }
        return evidence
    }
    private func captureExclusively(raw: PreparedRAW, directory: URL, initialEvidence: XT5RawBaselineEvidence = XT5RawBaselineEvidence(),
                                    conversionTrigger: UInt16?, quarantineOutput: Bool = false, filmReference: XT5FilmProbeReference? = nil, batchPatch: XT5FiniteRecipePatch? = nil, closeAfterCapture: Bool = true,
                                    onUpdate: @escaping @Sendable (XT5RawBaselineEvidence) async -> Void) async throws -> XT5RawBaselineEvidence {
        var evidence = initialEvidence
        var manifest = Manifest(sourceSHA256: raw.sha256)
        var uploadAttempted = false
        var afterObserved = false
        var canReadObjectInfo = false
        var expectedOutputHandle: UInt32?
        do {
            try filmReference?.validate(raw: raw)
            if let batchPatch, batchPatch.sourceSHA256 != raw.sha256 { throw XT5RecipeBatchIssue.invalidReference }
            guard raw.metadata.cameraModel == "X-T5" else { throw XT5RawBaselineIssue.unsupportedContext }
            let info = try XT5RecipeCodec.deviceInfo(await send(0x1001).data)
            guard info.manufacturer == "FUJIFILM", info.model == "X-T5", info.firmware == "4.31" else { throw XT5RawBaselineIssue.unsupportedContext }
            guard [UInt16(0x1015),0x1007,0x900C,0x900D].allSatisfy(info.operations.contains),
                  [UInt16(0xD16E),0xD185,0xD186,0xD187].allSatisfy(info.properties.contains) else { throw XT5RawBaselineIssue.missingCapability }
            canReadObjectInfo = info.operations.contains(0x1008)
            if conversionTrigger != nil {
                guard [UInt16(0x1008),0x1009,0x1016].allSatisfy(info.operations.contains), info.properties.contains(0xD183) else { throw XT5RawBaselineIssue.missingCapability }
            }
            guard try await send(0x1015, parameters: [0xD16E]).data == Data([6,0]) else { throw XT5RawBaselineIssue.unsupportedContext }
            for code: UInt32 in [0xD186,0xD187] {
                guard try XT5RecipeCodec.value(await send(0x1015, parameters: [code]).data, type: 0xffff).string == "X-T5_0200" else { throw XT5RawBaselineIssue.unsupportedContext }
            }
            evidence.model = "X-T5"; evidence.firmware = "4.31"; evidence.capability = "X-T5_0200"
            evidence.width = raw.metadata.recordedGeometry.width; evidence.height = raw.metadata.recordedGeometry.height; evidence.orientation = raw.metadata.orientation
            let before = try await enumerate(directory: directory, phase: "before")
            manifest.beforeHandles = before; evidence.preexistingObjectCount = before.count
            try persist(manifest, directory: directory)
            if !before.isEmpty {
                try await observeObjects(before, phase: "before", allowed: canReadObjectInfo, directory: directory, manifest: &manifest, evidence: &evidence)
                throw XT5RawBaselineIssue.nonemptyObjectView
            }
            await onUpdate(evidence)
            // Keep the only full original payload scoped to upload. No original/converted image
            // download and no second upload payload can coexist with this data phase.
            do {
                let size = try raw.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                _ = try XT5ConversionCodec.uploadInfo(byteCount: size)
                let payload = try Data(contentsOf: raw.fileURL, options: .mappedIfSafe)
                guard payload.count == size else { throw ResourceError.checksumMismatch }
                let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard hash == raw.sha256 else { throw ResourceError.checksumMismatch }
                evidence.rawBytes = payload.count
                let objectInfo = try XT5ConversionCodec.uploadInfo(byteCount: payload.count)
                uploadAttempted = true
                let infoReply = try await send(0x900C, parameters: [0,0,0], data: objectInfo)
                manifest.uploadInfoResponseParameters = infoReply.parameters; evidence.uploadInfoSucceeded = true
                try persist(manifest, directory: directory)
                let uploadReply = try await send(0x900D, data: payload)
                manifest.uploadResponseParameters = uploadReply.parameters; evidence.rawUploadSucceeded = true
                try persist(manifest, directory: directory)
            }
            // Only a successful actual 900D permits the per-RAF working profile read.
            let baseline = try await send(0x1015, parameters: [0xD185]).data
            guard !baseline.isEmpty, baseline.count <= 65_536 else { throw XT5RawBaselineIssue.invalidBaselineLength }
            try privateWrite(baseline, to: directory.appendingPathComponent("baseline.bin"))
            evidence.baselineBytes = baseline.count
            await onUpdate(evidence)
            if let batchPatch {
                guard baseline == batchPatch.baseline else { throw XT5RecipeBatchIssue.baselineMismatch }
                try privateWrite(batchPatch.bytes, to: directory.appendingPathComponent("recipe-candidate.bin"))
                evidence.batchProfileWriteAttempted = true; await onUpdate(evidence)
                _ = try await send(0x1016, parameters: [0xD185], data: batchPatch.bytes)
                evidence.batchProfileWriteAccepted = true; await onUpdate(evidence)
                let readback = try await send(0x1015, parameters: [0xD185]).data
                guard readback.count <= 65_536 else { throw XT5ProtocolError.oversized }
                try privateWrite(readback, to: directory.appendingPathComponent("recipe-readback.bin"))
                guard readback == batchPatch.bytes else { throw XT5RecipeBatchIssue.readbackMismatch }
                evidence.batchProfileReadbackMatches = true; await onUpdate(evidence)
            }
            if let filmReference {
                let beforeFilm = evidence
                let profile = XT5FilmWorkingProfileProbe(send: { opcode, parameters, data in
                    guard parameters == [0xD185],
                          (opcode == 0x1015 && data == nil) || (opcode == 0x1016 && data?.count == 625) else { throw PTPError.invalidParameters }
                    return try await self.send(opcode, parameters: parameters, data: data)
                })
                let result = await profile.run(baseline: baseline, reference: filmReference, directory: directory) { partial in
                    var report = beforeFilm; report.filmProbe = partial; await onUpdate(report)
                }
                evidence.filmProbe = result
                guard result.patchReadbackMatches && result.failure == nil else {
                    evidence.failure = result.failure
                    throw XT5FilmProbeIssue.patchMismatch
                }
            }
            if conversionTrigger != nil {
                let conversion = XT5UnchangedConversionProbe(send: { opcode, parameters, data in
                    try await self.send(opcode, parameters: parameters, data: data)
                }, pollWait: pollWait)
                let beforeConversion = evidence
                let result = await conversion.run(raw: raw, directory: directory, canReadStorage: info.operations.contains(0x1005), quarantine: quarantineOutput, triggerValue: conversionTrigger ?? 0, diagnosticLabel: batchPatch != nil ? "experimental imported-bank candidate; dormant grain size not applied; fidelity unvalidated" : (filmReference == nil ? nil : "experimental film-only working profile; no imported bank applied")) { partial in
                    var report = beforeConversion; report.unchangedConversion = partial
                    await onUpdate(report)
                }
                evidence.unchangedConversion = result
                expectedOutputHandle = await conversion.selectedHandle
                await onUpdate(evidence)
                guard (result.jpegRetained || (quarantineOutput && result.quarantineCaptured)) && result.failure == nil else { throw XT5UnchangedConversionFailure(observation: result) }
            }
            afterObserved = true
            let after = try await enumerate(directory: directory, phase: "after")
            manifest.afterHandles = after; evidence.newObjectCount = after.count // Before was proven empty.
            if conversionTrigger != nil {
                // A later view cannot contradict the captured candidate and still report success.
                // Keep the diagnostic file, but fail before observing unrelated/replacement objects.
                guard let expectedOutputHandle, after == [expectedOutputHandle] else { throw XT5ConversionProbeIssue.ambiguousOutput }
            }
            try await observeObjects(after, phase: "after", allowed: canReadObjectInfo, directory: directory, manifest: &manifest, evidence: &evidence)
        } catch { evidence.failure = evidence.failure ?? Self.safeFailure(error) }

        if uploadAttempted && !afterObserved {
            // Read-only observation after a complete camera rejection; never retry upload or guess
            // that a rejected/partially completed data phase created nothing.
            do {
                let after = try await enumerate(directory: directory, phase: "after")
                manifest.afterHandles = after; evidence.newObjectCount = after.count
                try await observeObjects(after, phase: "after", allowed: canReadObjectInfo, directory: directory, manifest: &manifest, evidence: &evidence)
            } catch { evidence.observationFailure = Self.safeFailure(error) }
        }
        do { try persist(manifest, directory: directory) }
        catch { evidence.failure = evidence.failure ?? Self.safeFailure(error) }
        await onUpdate(evidence)
        if !closeAfterCapture {
            evidence.sessionClosure = "heldByBatchOwner"
            evidence.batchTrialCaptured = evidence.failure == nil && evidence.baselineBytes != nil
            await onUpdate(evidence)
            guard evidence.batchTrialCaptured else { throw XT5RawBaselineFailure(evidence: evidence) }
            return evidence
        }
        // Owner's closure checks against a replacement generation and awaits the native close or
        // terminal removal, retaining quarantine on uncertainty. Parent cancellation cannot skip it.
        let close = Task.detached { try await self.closeSession() }
        do { try await close.value; evidence.sessionClosure = "confirmed" }
        catch { evidence.sessionClosure = "unconfirmed"; evidence.sessionClosureFailure = Self.safeFailure(error) }
        evidence.probeFinished = evidence.failure == nil && evidence.baselineBytes != nil && evidence.sessionClosure == "confirmed"
        await onUpdate(evidence)
        guard evidence.probeFinished else { throw XT5RawBaselineFailure(evidence: evidence) }
        return evidence
    }
    private func enumerate(directory: URL, phase: String) async throws -> [UInt32] {
        let bytes = try await send(0x1007, parameters: [UInt32.max,0,0]).data
        if bytes.count <= 65_536 { try privateWrite(bytes, to: directory.appendingPathComponent("handles-\(phase).bin")) }
        return try XT5ConversionCodec.objectHandles(bytes)
    }
    private func observeObjects(_ handles: [UInt32], phase: String, allowed: Bool, directory: URL,
                                manifest: inout Manifest, evidence: inout XT5RawBaselineEvidence) async throws {
        guard allowed else { return }
        for (index, handle) in handles.prefix(8).enumerated() {
            do {
                let bytes = try await send(0x1008, parameters: [handle]).data
                guard bytes.count <= 4096 else { throw XT5ProtocolError.oversized }
                let file = "object-\(phase)-\(index).bin"
                try privateWrite(bytes, to: directory.appendingPathComponent(file))
                manifest.objects.append(.init(handle: handle, phase: phase, byteCount: bytes.count, file: file, failure: nil))
                evidence.objectMetadataCount += 1
            } catch PTPError.responseCode(let code) {
                manifest.objects.append(.init(handle: handle, phase: phase, byteCount: nil, file: nil, failure: String(format: "PTP response 0x%04X", code)))
            }
        }
        try persist(manifest, directory: directory)
    }
    private func send(_ opcode: UInt16, parameters: [UInt32] = [], data: Data? = nil) async throws -> PTPReply {
        try Task.checkCancellation(); try await validateSession(); try Task.checkCancellation()
        guard transaction < UInt32.max else { throw PTPError.invalidParameters }
        let id = transaction; transaction += 1
        let reply = try await transport.execute(PTPCommand(opcode: opcode, parameters: parameters, transactionID: id), data: data)
        try await validateSession()
        return reply
    }
    private func persist(_ manifest: Manifest, directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try privateWrite(encoder.encode(manifest), to: directory.appendingPathComponent("protocol-manifest.json"))
    }
    private func privateWrite(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: [.atomic,.completeFileProtection]) }
        catch { throw XT5RawBaselineIssue.artifactWriteFailed }
    }
    static func safeFailure(_ error: any Error) -> String {
        if let error = error as? XT5RecipeBatchIssue { return String(describing: error) }
        if let error = error as? XT5FilmProbeIssue { return String(describing: error) }
        if let error = error as? XT5ExactCleanupIssue { return String(describing: error) }
        if let error = error as? XT5UnchangedConversionFailure { return error.observation.failure ?? "unchanged conversion incomplete" }
        if let error = error as? XT5ConversionProbeIssue { return String(describing: error) }
        if let error = error as? XT5RawBaselineIssue { return String(describing: error) }
        if let error = error as? ResourceError {
            if error == .checksumMismatch { return "source checksum mismatch" }
            return "source preparation failed"
        }
        return XT5BankImporter.safeFailure(error)
    }
}

enum XT5BaselineExperiment: Sendable { case baselineOnly, unchangedTrigger0 }
struct XT5UnchangedConversionObservation: Sendable, Encodable {
    var label = "unchanged camera baseline; no imported recipe applied"
    var triggerValue: Int? = 0
    var readOnlyRecovery = false
    var triggerAttempted = false
    var triggerAccepted = false
    var polls = 0
    var newHandleCount: Int?
    var existingHandleCount: Int?
    var objectBytes: UInt32?
    var objectWidth: UInt32?
    var objectHeight: UInt32?
    var objectAssociationType: UInt16?
    var objectMetadataValidated = false
    var downloadedBytes: Int?
    var storageType: UInt16?
    var storageObservation = "not attempted"
    var jpeg: XT5JPEGObservation?
    var jpegRetained = false
    var quarantineRequested = false
    var quarantineCaptured = false
    var captureOutcome = "notCaptured"
    var failure: String?
    let outputCleanup = "unconfirmed"
    let fineQualityValidated = false
}
struct XT5UnchangedConversionFailure: Error, Sendable { let observation: XT5UnchangedConversionObservation }

/// Diagnostic only. Called while the RAW upload owner's gate and native generation are held.
/// A new handle is a candidate output, never permission to delete any object.
private actor XT5UnchangedConversionProbe {
    typealias Send = @Sendable (UInt16, [UInt32], Data?) async throws -> PTPReply
    private let send: Send
    private let pollWait: @Sendable () async throws -> Void
    private var observation = XT5UnchangedConversionObservation()
    private(set) var selectedHandle: UInt32? // Internal identity only; never encoded in public evidence.
    private var onUpdate: @Sendable (XT5UnchangedConversionObservation) async -> Void = { _ in }
    private struct Manifest: Encodable {
        let sourceSHA256: String
        var readOnlyRecovery = false
        var privateQuarantine = false
        var handleViews: [[UInt32]] = []
        var candidateHandle: UInt32?
        var object: XT5ObjectInfo?
        var storage: XT5StorageInfo?
        var outputSHA256: String?
    }
    init(send: @escaping Send, pollWait: @escaping @Sendable () async throws -> Void) { self.send = send; self.pollWait = pollWait }
    func run(raw: PreparedRAW, directory: URL, canReadStorage: Bool, recovery: Bool = false, quarantine: Bool = false, triggerValue: UInt16 = 0, diagnosticLabel: String? = nil,
             onUpdate: @escaping @Sendable (XT5UnchangedConversionObservation) async -> Void) async -> XT5UnchangedConversionObservation {
        self.onUpdate = onUpdate
        observation.triggerValue = Int(triggerValue)
        if recovery {
            observation.readOnlyRecovery = true; observation.triggerValue = nil
            observation.label = "existing candidate recovery; interrupted-operation provenance unconfirmed"
        }
        if quarantine {
            observation.quarantineRequested = true
            observation.label = recovery ? "unvalidated private quarantine; interrupted-operation provenance unconfirmed" : "unchanged camera baseline trigger 1; unvalidated private diagnostic"
        }
        if let diagnosticLabel { observation.label = diagnosticLabel }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.capture(raw: raw, directory: directory, canReadStorage: canReadStorage, recovery: recovery, quarantine: quarantine, triggerValue: triggerValue) }
                group.addTask { try await Task.sleep(for: .seconds(45)); throw XT5ConversionProbeIssue.outputTimeout }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch { observation.failure = XT5RawBaselineProbe.safeFailure(error) }
        return observation
    }
    private func capture(raw: PreparedRAW, directory: URL, canReadStorage: Bool, recovery: Bool, quarantine: Bool, triggerValue: UInt16) async throws {
        guard triggerValue <= 1, !quarantine || recovery || triggerValue == 1 else { throw PTPError.invalidParameters }
        var manifest = Manifest(sourceSHA256: raw.sha256, readOnlyRecovery: recovery, privateQuarantine: quarantine)
        defer { try? persist(manifest, directory: directory) }
        let before = try await handles()
        manifest.handleViews.append(before); try persist(manifest, directory: directory)
        let selected: UInt32
        if recovery {
            observation.existingHandleCount = before.count
            await onUpdate(observation)
            guard before.count == 1, let only = before.first else { throw XT5ConversionProbeIssue.ambiguousOutput }
            selected = only
        } else {
            guard before.isEmpty else { throw XT5RawBaselineIssue.nonemptyObjectView }
            try Task.checkCancellation()
            observation.triggerAttempted = true
            await onUpdate(observation)
            _ = try await send(0x1016, [0xD183], Data([UInt8(triggerValue),0]))
            observation.triggerAccepted = true
            await onUpdate(observation)
            var candidate: UInt32?
            for _ in 0..<20 {
                try Task.checkCancellation()
                let found = try await handles(); observation.polls += 1
                observation.newHandleCount = found.count; manifest.handleViews.append(found)
                try persist(manifest, directory: directory)
                await onUpdate(observation)
                guard found.count <= 1 else { throw XT5ConversionProbeIssue.ambiguousOutput }
                if let only = found.first { candidate = only; break }
                try await pollWait()
            }
            guard let candidate else { throw XT5ConversionProbeIssue.outputTimeout }
            selected = candidate
        }
        selectedHandle = selected
        manifest.candidateHandle = selected
        let bytes = try await send(0x1008, [selected], nil).data
        try write(bytes, name: "output-object-info.bin", directory: directory, maximum: 4096)
        let info = try XT5ConversionCodec.objectInfo(bytes)
        manifest.object = info
        observation.objectBytes = info.byteCount; observation.objectWidth = info.width; observation.objectHeight = info.height
        observation.objectAssociationType = info.associationType
        try persist(manifest, directory: directory)
        if canReadStorage {
            do {
                let storage = try await send(0x1005, [info.storageID], nil).data
                try write(storage, name: "output-storage-info.bin", directory: directory, maximum: 4096)
                let decoded = try XT5ConversionCodec.storageInfo(storage)
                manifest.storage = decoded; observation.storageType = decoded.storageType; observation.storageObservation = "decoded; ownership unconfirmed"
            } catch PTPError.responseCode(let code) { observation.storageObservation = String(format: "PTP response 0x%04X; ownership unconfirmed", code) }
        } else { observation.storageObservation = "not advertised; ownership unconfirmed" }
        try persist(manifest, directory: directory)
        await onUpdate(observation)
        let exactGeometry = info.width == raw.metadata.recordedGeometry.width && info.height == raw.metadata.recordedGeometry.height
        observation.objectMetadataValidated = info.format == 0x3801 && info.associationType == 0 && exactGeometry && info.byteCount > 0 && info.byteCount <= PTPCodec.maximumDataBytes
        let noKnownGeometryMismatch = (info.width == 0 || info.width == raw.metadata.recordedGeometry.width) && (info.height == 0 || info.height == raw.metadata.recordedGeometry.height)
        guard info.format == 0x3801, info.byteCount > 0, info.byteCount <= PTPCodec.maximumDataBytes,
              quarantine ? noKnownGeometryMismatch : observation.objectMetadataValidated else {
            throw XT5ConversionProbeIssue.unexpectedObjectMetadata
        }
        // Revalidate the unique candidate immediately before and after download. Metadata identity
        // and size must stay stable; only then can this local diagnostic file be retained.
        guard try await handles() == [selected] else { throw XT5ConversionProbeIssue.ambiguousOutput }
        let jpeg = try await send(0x1009, [selected], nil).data
        observation.downloadedBytes = jpeg.count
        guard jpeg.count == info.byteCount else { throw XT5ConversionProbeIssue.unexpectedObjectMetadata }
        guard try await handles() == [selected] else { throw XT5ConversionProbeIssue.ambiguousOutput }
        let afterInfo = try await send(0x1008, [selected], nil).data
        try write(afterInfo, name: "output-object-info-after.bin", directory: directory, maximum: 4096)
        // Preserve and compare the entire opaque ObjectInfo, not only interpreted fields.
        guard afterInfo == bytes else { throw XT5ConversionProbeIssue.ambiguousOutput }
        try Task.checkCancellation()
        manifest.outputSHA256 = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        try persist(manifest, directory: directory)
        if quarantine {
            try write(jpeg, name: "quarantined-candidate.bin", directory: directory, maximum: PTPCodec.maximumDataBytes)
            observation.quarantineCaptured = true; observation.captureOutcome = "privateQuarantine"
            await onUpdate(observation)
        }
        let decoded = try XT5ConversionCodec.jpegObservation(jpeg, expected: raw.metadata)
        observation.jpeg = decoded
        guard decoded.modelMatches, decoded.recordedGeometryMatches, decoded.orientationMatches else { throw XT5ConversionProbeIssue.unexpectedJPEGContext }
        try Task.checkCancellation()
        if quarantine { return } // Never promote quarantined bytes, even when header checks match.
        try write(jpeg, name: recovery ? "recovered-candidate.JPG" : "unchanged-baseline.JPG", directory: directory, maximum: PTPCodec.maximumDataBytes)
        observation.jpegRetained = true
        observation.captureOutcome = "validatedDiagnosticCandidate"
    }
    private func handles() async throws -> [UInt32] { try XT5ConversionCodec.objectHandles(await send(0x1007, [UInt32.max,0,0], nil).data) }
    private func persist(_ manifest: Manifest, directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try write(encoder.encode(manifest), name: "conversion-manifest.json", directory: directory, maximum: 1_048_576)
    }
    private func write(_ data: Data, name: String, directory: URL, maximum: Int) throws {
        guard data.count <= maximum else { throw XT5ProtocolError.oversized }
        do { try data.write(to: directory.appendingPathComponent(name), options: [.atomic,.completeFileProtection]) }
        catch { throw XT5RawBaselineIssue.artifactWriteFailed }
    }
}
