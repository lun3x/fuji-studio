import Foundation
import Testing
@testable import FujiStudio

struct XT5UnchangedConversionTests {
    @Test func recoveryReadsSingleExistingCandidateWithoutUploadTriggerProfileOrDelete() async throws {
        let f = try ConversionFixture(); defer { f.remove() }
        let wire = try ConversionWire(mode: .recoverySingle)
        let report = try await probe(wire).recoverExistingOutput(raw: f.raw,directory: f.directory)
        let observation = try #require(report.unchangedConversion)
        #expect(observation.readOnlyRecovery && observation.triggerValue == nil)
        #expect(!observation.triggerAttempted && observation.jpegRetained)
        #expect(observation.label.contains("unconfirmed"))
        #expect(report.sessionClosure == "confirmed")
        #expect(report.baselineBytes == nil && !report.rawUploadSucceeded)
        #expect(await wire.commands.allSatisfy { [0x1001,0x1005,0x1007,0x1008,0x1009,0x1015].contains($0.opcode) && $0.parameters != [0xD185] })
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("recovered-candidate.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("baseline.bin").path))
    }
    @Test func recoveryRequiresExactlyOneCandidateAndDoesNotFallbackToTrigger() async throws {
        for mode in [ConversionWire.Mode.normal,.recoveryMultiple] {
            let f = try ConversionFixture(); defer { f.remove() }
            let wire = try ConversionWire(mode: mode)
            do { _ = try await probe(wire).recoverExistingOutput(raw: f.raw,directory: f.directory); Issue.record("Expected recovery refusal") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
            #expect(await wire.commands.allSatisfy { [0x1001,0x1007,0x1015].contains($0.opcode) })
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("recovered-candidate.JPG").path))
        }
    }
    @Test func uploadsThenTriggersUnmodifiedBaselineOnceAndRetainsValidatedJPEGWithoutDeletion() async throws {
        let f = try ConversionFixture(); defer { f.remove() }
        let wire = try ConversionWire()
        let report = try await probe(wire).capture(raw: f.raw,directory: f.directory)
        let conversion = try #require(report.unchangedConversion)
        #expect(conversion.triggerValue == 0 && conversion.triggerAccepted)
        #expect(conversion.jpegRetained && conversion.jpeg?.orientation == 8)
        #expect(conversion.outputCleanup == "unconfirmed")
        #expect(!report.conversionValidated)
        let commands = await wire.commands
        #expect(commands.filter { $0.opcode == 0x1016 }.map(\.parameters) == [[0xD183]])
        #expect(await wire.triggerPayload == Data([0,0]))
        let upload = try #require(commands.firstIndex { $0.opcode == 0x900D })
        let baseline = try #require(commands.firstIndex { $0.parameters == [0xD185] })
        let trigger = try #require(commands.firstIndex { $0.parameters == [0xD183] })
        #expect(upload < baseline && baseline < trigger)
        #expect(commands.allSatisfy { $0.opcode != 0x100B })
        #expect(try Data(contentsOf: f.directory.appendingPathComponent("unchanged-baseline.JPG")) == wire.jpeg)
        let publicText = String(decoding: try JSONEncoder().encode(report),as: UTF8.self)
        #expect(!publicText.contains("PRIVATE"))
        #expect(!publicText.contains(f.raw.sha256))
    }
    @Test func nonemptyPretriggerViewAndAmbiguousOutputNeverDownloadOrDelete() async throws {
        for mode in [ConversionWire.Mode.nonemptyBeforeTrigger,.multipleOutputs] {
            let f = try ConversionFixture(); defer { f.remove() }
            let wire = try ConversionWire(mode: mode)
            do { _ = try await probe(wire).capture(raw: f.raw,directory: f.directory); Issue.record("Expected ambiguous/preexisting output refusal") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
            #expect(await wire.commands.allSatisfy { ![0x1009,0x100B].contains($0.opcode) })
            if mode == .nonemptyBeforeTrigger { #expect(await wire.commands.allSatisfy { $0.opcode != 0x1016 }) }
        }
    }
    @Test func wrongMetadataAndWrongJPEGContextAreNotRetained() async throws {
        for mode in [ConversionWire.Mode.wrongMetadata,.wrongJPEG] {
            let f = try ConversionFixture(); defer { f.remove() }
            let wire = try ConversionWire(mode: mode)
            do { _ = try await probe(wire).capture(raw: f.raw,directory: f.directory); Issue.record("Expected metadata/context failure") }
            catch let failure as XT5RawBaselineFailure {
                #expect(failure.evidence.sessionClosure == "confirmed")
                #expect(failure.evidence.unchangedConversion?.jpegRetained == false)
            }
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("unchanged-baseline.JPG").path))
            #expect(await wire.commands.allSatisfy { $0.opcode != 0x100B })
        }
    }
    @Test func boundedPollingAndStaleSessionDoNotRetryTriggerOrTouchOtherGeneration() async throws {
        for mode in [ConversionWire.Mode.noOutput,.staleAfterTrigger] {
            let f = try ConversionFixture(); defer { f.remove() }
            let wire = try ConversionWire(mode: mode)
            do { _ = try await probe(wire).capture(raw: f.raw,directory: f.directory); Issue.record("Expected timeout/stale failure") }
            catch let failure as XT5RawBaselineFailure { #expect(!failure.evidence.probeFinished) }
            #expect(await wire.commands.filter { $0.opcode == 0x1016 }.count == 1)
            #expect(await wire.commands.count < 40)
            #expect(await wire.commands.allSatisfy { ![0x1009,0x100B].contains($0.opcode) })
        }
    }
    private func probe(_ wire: ConversionWire) -> XT5RawBaselineProbe {
        XT5RawBaselineProbe(transport: wire,validateSession: { try await wire.validate() },closeSession: { try await wire.close() },experiment: .unchangedTrigger0,pollWait: { })
    }
}

private struct ConversionFixture {
    let directory: URL
    let raw: PreparedRAW
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.RAF"); try Data(repeating: 0x52,count: 256).write(to: url)
        raw = PreparedRAW(fileURL: url,sha256: try ResourceChecksum.sha256(url),sourceID: "PRIVATE",sourceRevision: "PRIVATE",metadata: ObjectObservationFixture.metadata)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor ConversionWire: PTPTransport {
    enum Mode { case normal, nonemptyBeforeTrigger, multipleOutputs, wrongMetadata, wrongJPEG, noOutput, staleAfterTrigger, recoverySingle, recoveryMultiple }
    let mode: Mode
    nonisolated let jpeg: Data
    var commands: [PTPCommand] = []
    var triggerPayload: Data?
    var current = true
    private var uploaded = false
    private var triggered = false
    init(mode: Mode = .normal) throws { self.mode = mode; jpeg = try ObjectObservationFixture.jpeg() }
    func validate() throws { guard current else { throw XT5BankImportIssue.sessionChanged } }
    func close() throws { try validate() }
    func execute(_ command: PTPCommand,data: Data?) throws -> PTPReply {
        try Task.checkCancellation(); commands.append(command)
        let bytes: Data
        switch (command.opcode,command.parameters) {
        case (0x1001,[]): bytes = ProtocolProbeFixtures.deviceInfo(properties: [0xD16E,0xD183,0xD185,0xD186,0xD187],operations: [0x1001,0x1005,0x1007,0x1008,0x1009,0x1015,0x1016,0x900C,0x900D],firmware: "4.31")
        case (0x1015,[0xD16E]): bytes = Data([6,0])
        case (0x1015,[0xD186]),(0x1015,[0xD187]): bytes = ProtocolProbeFixtures.string("X-T5_0200")
        case (0x900C,[0,0,0]): bytes = Data()
        case (0x900D,[]): uploaded = true; bytes = Data()
        case (0x1015,[0xD185]): bytes = Data(repeating: 0,count: 625)
        case (0x1016,[0xD183]):
            triggered = true; triggerPayload = data; bytes = Data()
            if mode == .staleAfterTrigger { current = false }
        case (0x1007,[UInt32.max,0,0]):
            if mode == .recoveryMultiple { bytes = Data([2,0,0,0,77,0,0,0,78,0,0,0]) }
            else if mode == .recoverySingle { bytes = Data([1,0,0,0,77,0,0,0]) }
            else if triggered && mode != .noOutput { bytes = mode == .multipleOutputs ? Data([2,0,0,0,77,0,0,0,78,0,0,0]) : Data([1,0,0,0,77,0,0,0]) }
            else if uploaded && mode == .nonemptyBeforeTrigger { bytes = Data([1,0,0,0,77,0,0,0]) }
            else { bytes = Data([0,0,0,0]) }
        case (0x1008,[77]),(0x1008,[78]):
            var info = ObjectObservationFixture.info(format: mode == .wrongMetadata ? 0x3001 : 0x3801,byteCount: UInt32(jpeg.count))
            info.replaceSubrange(26..<30,with: ObjectObservationFixture.word(4)); info.replaceSubrange(30..<34,with: ObjectObservationFixture.word(6)); bytes = info
        case (0x1005,[0x10001]): bytes = ObjectObservationFixture.storage()
        case (0x1009,[77]): bytes = mode == .wrongJPEG ? Data(repeating: 0,count: jpeg.count) : jpeg
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode: command.opcode,parameters: [],logicalTransactionID: command.transactionID,wireTransactionID: command.transactionID+9,correlation: .imageCaptureCoreCallback(echoedCommand: command),responseCode: 0x2001,rawResponse: Data(),data: bytes)
    }
}
