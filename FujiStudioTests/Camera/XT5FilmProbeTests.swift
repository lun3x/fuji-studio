@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct XT5FilmProbeTests {
    @Test func exactEchoThenOnlyFilmWordPatchMustRoundtripBeforeTriggerOne() async throws {
        let f = try FilmFixture(); defer { f.remove() }
        let wire = FilmWire(jpeg: f.jpeg, baseline: f.baseline)
        let report = try await probe(wire).captureFilmOnly(raw: f.raw, reference: f.reference, directory: f.directory)
        let stage = try #require(report.filmProbe)
        #expect(stage.baselineMatchesReference && stage.echoAccepted && stage.echoReadbackMatches)
        #expect(stage.patchAccepted && stage.patchReadbackMatches)
        #expect(report.unchangedConversion?.triggerValue == 1)
        #expect(report.unchangedConversion?.label == "experimental film-only working profile; no imported bank applied")
        #expect(report.unchangedConversion?.quarantineCaptured == true)
        #expect(report.unchangedConversion?.jpegRetained == false)
        #expect(report.sessionClosure == "confirmed")
        let writes = await wire.profileWrites
        #expect(writes.count == 2 && writes[0] == f.baseline)
        let patched = try #require(writes.last)
        #expect(patched.count == 625)
        #expect(patched.subdata(in: 541..<545) == Data([11,0,0,0]))
        #expect(patched.prefix(541) == f.baseline.prefix(541))
        #expect(patched.suffix(from: 545) == f.baseline.suffix(from: 545))
        let commands = await wire.commands
        let relevant = commands.filter { [0x900C,0x900D,0x1016].contains($0.opcode) || $0.parameters == [0xD185] }
        #expect(relevant.map(\.opcode) == [0x900C,0x900D,0x1015,0x1016,0x1015,0x1016,0x1015,0x1016])
        #expect(await wire.triggers == [Data([1,0])])
        #expect(commands.allSatisfy { $0.opcode != 0x100B })
        for name in ["profile-echo.bin","profile-echo-readback.bin","profile-film-patch.bin","profile-film-readback.bin"] {
            #expect(try Data(contentsOf: f.directory.appendingPathComponent(name)).count == 625)
        }
    }
    @Test func nonemptyViewAndDifferentBaselineNeverWriteWorkingProfile() async throws {
        for mode in [FilmWire.Mode.nonempty, .wrongBaseline] {
            let f = try FilmFixture(); defer { f.remove() }
            let wire = FilmWire(jpeg: f.jpeg, baseline: f.baseline, mode: mode)
            do { _ = try await probe(wire).captureFilmOnly(raw: f.raw, reference: f.reference, directory: f.directory); Issue.record("Expected refusal") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed" && !failure.evidence.probeFinished) }
            #expect(await wire.profileWrites.isEmpty)
            #expect(await wire.triggers.isEmpty)
            if mode == .nonempty { #expect(await wire.commands.allSatisfy { ![0x900C,0x900D].contains($0.opcode) }) }
            #expect(await wire.commands.allSatisfy { $0.opcode != 0x100B })
        }
    }
    @Test func rejectedOrDifferentRoundtripsStopWithoutRepairRetryOrTrigger() async throws {
        for mode in [FilmWire.Mode.rejectEcho,.echoMismatch,.rejectPatch,.patchMismatch,.lostSessionAfterEcho] {
            let f = try FilmFixture(); defer { f.remove() }
            let wire = FilmWire(jpeg: f.jpeg, baseline: f.baseline, mode: mode)
            do { _ = try await probe(wire).captureFilmOnly(raw: f.raw, reference: f.reference, directory: f.directory); Issue.record("Expected roundtrip refusal") }
            catch let failure as XT5RawBaselineFailure {
                #expect(failure.evidence.sessionClosure == "confirmed" && !failure.evidence.probeFinished)
                #expect(failure.evidence.filmProbe?.patchReadbackMatches == false)
            }
            #expect(await wire.profileWrites.count == (mode == .rejectPatch || mode == .patchMismatch ? 2 : 1))
            #expect(await wire.triggers.isEmpty)
            #expect(await wire.commands.allSatisfy { $0.opcode != 0x100B })
        }
    }
    @Test func unexpectedReferenceWordOrSourceRejectsBeforeCameraCommands() async throws {
        let f = try FilmFixture(); defer { f.remove() }
        var wrongWord = f.baseline; wrongWord[541] = 14
        for reference in [XT5FilmProbeReference(sourceSHA256: f.raw.sha256, baseline: wrongWord),
                          XT5FilmProbeReference(sourceSHA256: "wrong", baseline: f.baseline)] {
            let wire = FilmWire(jpeg: f.jpeg, baseline: f.baseline)
            do { _ = try await probe(wire).captureFilmOnly(raw: f.raw, reference: reference, directory: f.directory); Issue.record("Expected reference refusal") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
            #expect(await wire.commands.isEmpty)
        }
    }
#if DEBUG
    @Test func retainedBaselineMustHaveExactLengthAndMatchingProtocolSource() async throws {
        let f = try FilmFixture(); defer { f.remove() }
        let baselineURL = f.directory.appendingPathComponent("baseline.bin")
        let manifestURL = f.directory.appendingPathComponent("protocol-manifest.json")
        try f.baseline.write(to: baselineURL)
        try JSONEncoder().encode(["sourceSHA256":f.raw.sha256]).write(to: manifestURL)
        let loaded = try await RetainedFilmProbeReference.prepare(raw: f.raw, destination: f.directory)
        #expect(loaded.baseline == f.baseline && loaded.sourceSHA256 == f.raw.sha256)
        try JSONEncoder().encode(["sourceSHA256":"different"]).write(to: manifestURL)
        await #expect(throws: XT5FilmProbeIssue.self) { try await RetainedFilmProbeReference.prepare(raw: f.raw, destination: f.directory) }
        try JSONEncoder().encode(["sourceSHA256":f.raw.sha256]).write(to: manifestURL)
        try Data(f.baseline.dropLast()).write(to: baselineURL)
        await #expect(throws: XT5FilmProbeIssue.self) { try await RetainedFilmProbeReference.prepare(raw: f.raw, destination: f.directory) }
    }
#endif
    private func probe(_ wire: FilmWire) -> XT5RawBaselineProbe {
        XT5RawBaselineProbe(transport: wire, validateSession: { try await wire.validate() }, closeSession: { await wire.close() }, pollWait: {})
    }
}
private struct FilmFixture {
    let directory: URL, raw: PreparedRAW, jpeg: Data, baseline: Data
    var reference: XT5FilmProbeReference { XT5FilmProbeReference(sourceSHA256: raw.sha256, baseline: baseline) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("source.RAF"); try Data(repeating: 0x52, count: 256).write(to: file)
        raw = PreparedRAW(fileURL: file, sha256: try ResourceChecksum.sha256(file), sourceID: "PRIVATE", sourceRevision: "PRIVATE", metadata: ObjectObservationFixture.metadata)
        jpeg = try ObjectObservationFixture.jpeg()
        // Synthetic shape only; never represented as an observed firmware fixture.
        var bytes = Data(repeating: 0xA5, count: 625); bytes[0] = 29; bytes[1] = 0; bytes[2] = 8
        bytes.replaceSubrange(541..<545, with: Data([15,0,0,0])); baseline = bytes
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private actor FilmWire: PTPTransport {
    enum Mode { case normal, nonempty, wrongBaseline, rejectEcho, echoMismatch, rejectPatch, patchMismatch, lostSessionAfterEcho }
    let jpeg: Data, baseline: Data, mode: Mode
    var commands: [PTPCommand] = [], profileWrites: [Data] = [], triggers: [Data] = []
    private var current = true, triggered = false
    init(jpeg: Data, baseline: Data, mode: Mode = .normal) { self.jpeg = jpeg; self.baseline = baseline; self.mode = mode }
    func validate() throws { guard current else { throw XT5BankImportIssue.sessionChanged } }
    func close() { current = false }
    func execute(_ c: PTPCommand, data: Data?) throws -> PTPReply {
        commands.append(c); let bytes: Data
        switch (c.opcode,c.parameters) {
        case (0x1001,[]): bytes = ProtocolProbeFixtures.deviceInfo(properties: [0xD16E,0xD183,0xD185,0xD186,0xD187], operations: [0x1001,0x1005,0x1007,0x1008,0x1009,0x1015,0x1016,0x900C,0x900D], firmware: "4.31")
        case (0x1015,[0xD16E]): bytes = Data([6,0])
        case (0x1015,[0xD186]),(0x1015,[0xD187]): bytes = ProtocolProbeFixtures.string("X-T5_0200")
        case (0x1007,[UInt32.max,0,0]): bytes = triggered || mode == .nonempty ? Data([1,0,0,0,88,0,0,0]) : Data([0,0,0,0])
        case (0x900C,[0,0,0]),(0x900D,[]): bytes = Data()
        case (0x1015,[0xD185]):
            var value = profileWrites.last ?? baseline
            if mode == .wrongBaseline || (mode == .echoMismatch && profileWrites.count == 1) || (mode == .patchMismatch && profileWrites.count == 2) { value[600] ^= 1 }; bytes = value
        case (0x1016,[0xD185]):
            profileWrites.append(data ?? Data())
            if mode == .rejectEcho || (mode == .rejectPatch && profileWrites.count == 2) { throw PTPError.responseCode(0x2002) }
            if mode == .lostSessionAfterEcho { current = false }; bytes = Data()
        case (0x1016,[0xD183]): triggers.append(data ?? Data()); triggered = true; bytes = Data()
        case (0x1008,[88]): var info = ObjectObservationFixture.info(byteCount: UInt32(jpeg.count)); info.replaceSubrange(26..<34,with: Data(repeating: 0,count: 8)); info.replaceSubrange(42..<44,with: ProtocolProbeFixtures.word(2055)); bytes = info
        case (0x1005,[0x10001]): bytes = ObjectObservationFixture.storage()
        case (0x1009,[88]): bytes = jpeg
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode: c.opcode, parameters: [], logicalTransactionID: c.transactionID, wireTransactionID: c.transactionID+9, correlation: .imageCaptureCoreCallback(echoedCommand: c), responseCode: 0x2001, rawResponse: Data(), data: bytes)
    }
}
