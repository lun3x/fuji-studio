import Foundation
import Testing
@testable import FujiStudio

struct XT5ExactCleanupTests {
    @Test func exactPreservedOutputIsDeletedOnceBeforeFreshUploadAndTriggerOne() async throws {
        let f = try CleanupFixture(); defer { f.remove() }
        let wire = CleanupWire(jpeg: f.jpeg)
        let report = try await probe(wire).captureTriggerOne(after: f.target,raw: f.raw,directory: f.directory)
        #expect(report.exactCleanup?.identityVerified == true)
        #expect(report.exactCleanup?.deleteAcknowledged == true)
        #expect(report.exactCleanup?.emptyViewVerified == true)
        #expect(report.unchangedConversion?.triggerValue == 1)
        #expect(report.unchangedConversion?.quarantineCaptured == true)
        #expect(report.unchangedConversion?.jpegRetained == false)
        #expect(report.sessionClosure == "confirmed")
        let commands = await wire.commands
        #expect(commands.filter { $0.opcode == 0x100B }.map(\.parameters) == [[77,0]])
        let deletion = try #require(commands.firstIndex { $0.opcode == 0x100B })
        let uploadInfo = try #require(commands.firstIndex { $0.opcode == 0x900C })
        let upload = try #require(commands.firstIndex { $0.opcode == 0x900D })
        let baseline = try #require(commands.firstIndex { $0.parameters == [0xD185] })
        let trigger = try #require(commands.firstIndex { $0.parameters == [0xD183] })
        #expect(deletion < uploadInfo && uploadInfo < upload && upload < baseline && baseline < trigger)
        #expect(commands[deletion+1].opcode == 0x1007)
        #expect(await wire.triggerPayloads == [Data([1,0])])
        #expect(commands.filter { $0.opcode == 0x1016 }.map(\.parameters) == [[0xD183]])
        #expect(try ResourceChecksum.sha256(f.target.quarantineURL) == f.target.outputSHA256)
        #expect(try Data(contentsOf: f.directory.appendingPathComponent("quarantined-candidate.bin")) == f.jpeg)
    }
    @Test func contradictoryFinalViewFailsAfterQuarantineWithoutRetryOrNewOutputDeletion() async throws {
        for mode in [CleanupWire.Mode.finalZero, .finalMultiple, .finalReplacement] {
            let f = try CleanupFixture(); defer { f.remove() }
            let wire = CleanupWire(jpeg: f.jpeg, mode: mode)
            do {
                _ = try await probe(wire).captureTriggerOne(after: f.target, raw: f.raw, directory: f.directory)
                Issue.record("Final view \(mode) must not report success")
            } catch let failure as XT5RawBaselineFailure {
                #expect(failure.evidence.failure == "ambiguousOutput")
                #expect(!failure.evidence.probeFinished)
                #expect(failure.evidence.sessionClosure == "confirmed")
                #expect(failure.evidence.unchangedConversion?.quarantineCaptured == true)
                #expect(failure.evidence.unchangedConversion?.jpegRetained == false)
            }
            #expect(try Data(contentsOf: f.directory.appendingPathComponent("quarantined-candidate.bin")) == f.jpeg)
            #expect(await wire.closed)
            #expect(await wire.triggeredViews == 4) // First poll, before/after download, final service view only.
            let commands = await wire.commands
            #expect(commands.filter { $0.opcode == 0x100B }.map(\.parameters) == [[77,0]])
            #expect(commands.filter { $0.opcode == 0x900D }.count == 1)
            #expect(commands.filter { $0.opcode == 0x1009 && $0.parameters == [88] }.count == 1)
            #expect(await wire.triggerPayloads == [Data([1,0])])
        }
    }
    @Test func identityAmbiguityOrChangedProofNeverDeletesOrUploads() async throws {
        for mode in [CleanupWire.Mode.multiple,.wrongHandle,.changedObject,.changedStorage,.changedPayload,.lateObjectChange] {
            let f = try CleanupFixture(); defer { f.remove() }
            let wire = CleanupWire(jpeg: f.jpeg,mode: mode)
            do { _ = try await probe(wire).captureTriggerOne(after: f.target,raw: f.raw,directory: f.directory); Issue.record("Expected exact ownership refusal") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
            #expect(await wire.commands.allSatisfy { ![0x100B,0x900C,0x900D,0x1016].contains($0.opcode) })
        }
    }
    @Test func deletionFailureOrNonemptyPostdeleteViewCannotLeadToUploadOrRetry() async throws {
        for mode in [CleanupWire.Mode.deleteRejected,.notEmptyAfterDelete] {
            let f = try CleanupFixture(); defer { f.remove() }
            let wire = CleanupWire(jpeg: f.jpeg,mode: mode)
            do { _ = try await probe(wire).captureTriggerOne(after: f.target,raw: f.raw,directory: f.directory); Issue.record("Expected cleanup failure") }
            catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.exactCleanup?.emptyViewVerified == false) }
            #expect(await wire.commands.filter { $0.opcode == 0x100B }.count == 1)
            #expect(await wire.commands.allSatisfy { ![0x900C,0x900D,0x1016].contains($0.opcode) })
        }
    }
    @Test func changedLocalQuarantineStopsBeforeAnyCameraMutation() async throws {
        let f = try CleanupFixture(); defer { f.remove() }
        try Data([1,2,3]).write(to: f.target.quarantineURL)
        let wire = CleanupWire(jpeg: f.jpeg)
        do { _ = try await probe(wire).captureTriggerOne(after: f.target,raw: f.raw,directory: f.directory); Issue.record("Expected local proof rejection") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.exactCleanup?.deleteAttempted == false) }
        #expect(await wire.commands.allSatisfy { ![0x100B,0x900C,0x900D,0x1016].contains($0.opcode) })
    }
    @Test func recordedDeleteAttemptCannotBeReplayedOnFreshSession() async throws {
        let f = try CleanupFixture(); defer { f.remove() }
        let rejected = CleanupWire(jpeg: f.jpeg, mode: .deleteRejected)
        do { _ = try await probe(rejected).captureTriggerOne(after: f.target, raw: f.raw, directory: f.directory) }
        catch is XT5RawBaselineFailure { }
        #expect(FileManager.default.fileExists(atPath: f.target.attemptURL.path))
        let fresh = CleanupWire(jpeg: f.jpeg)
        do { _ = try await probe(fresh).captureTriggerOne(after: f.target, raw: f.raw, directory: f.directory); Issue.record("Expected one-shot refusal") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
        #expect(await fresh.commands.isEmpty)
    }
#if DEBUG
    @Test func retainedProofRequiresUniqueCompleteRunAndExactLocalMetadata() async throws {
        let f = try CleanupFixture(); defer { f.remove() }
        let root = f.directory.appendingPathComponent("xt5-output-quarantine-private")
        let run = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try f.jpeg.write(to: run.appendingPathComponent("quarantined-candidate.bin"))
        try f.target.objectInfo.write(to: run.appendingPathComponent("output-object-info.bin"))
        try f.target.objectInfo.write(to: run.appendingPathComponent("output-object-info-after.bin"))
        try f.target.storageInfo.write(to: run.appendingPathComponent("output-storage-info.bin"))
        let manifest: [String:Any] = ["sourceSHA256": f.raw.sha256,"outputSHA256": f.target.outputSHA256,"candidateHandle":77,"readOnlyRecovery":true,"privateQuarantine":true]
        try JSONSerialization.data(withJSONObject: manifest).write(to: run.appendingPathComponent("conversion-manifest.json"))
        let reference = ["sha256":f.raw.sha256,"retainedRun":f.raw.fileURL.deletingLastPathComponent().lastPathComponent,"filename":"source.RAF"]
        try JSONEncoder().encode(reference).write(to: run.appendingPathComponent("source-reference.json"))
        let loaded = try await RetainedExactCleanupProof.prepare(documents: f.directory,raw: f.raw,destination: f.directory)
        #expect(loaded.handle == 77 && loaded.outputSHA256 == f.target.outputSHA256)
        try Data([0]).write(to: run.appendingPathComponent("output-object-info-after.bin"))
        await #expect(throws: (any Error).self) { try await RetainedExactCleanupProof.prepare(documents: f.directory,raw: f.raw,destination: f.directory) }
        try f.target.objectInfo.write(to: run.appendingPathComponent("output-object-info-after.bin"))
        try FileManager.default.copyItem(at: run,to: root.appendingPathComponent(UUID().uuidString))
        await #expect(throws: (any Error).self) { try await RetainedExactCleanupProof.prepare(documents: f.directory,raw: f.raw,destination: f.directory) }
    }
#endif
    private func probe(_ wire: CleanupWire) -> XT5RawBaselineProbe {
        XT5RawBaselineProbe(transport: wire,validateSession: { try await wire.validate() },closeSession: { await wire.close() },pollWait: { })
    }
}

private struct CleanupFixture {
    let directory: URL, raw: PreparedRAW, target: XT5ExactCleanupTarget, jpeg: Data
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.RAF"); try Data(repeating: 0x52,count: 256).write(to: source)
        raw = PreparedRAW(fileURL: source,sha256: try ResourceChecksum.sha256(source),sourceID: "PRIVATE",sourceRevision: "PRIVATE",metadata: ObjectObservationFixture.metadata)
        jpeg = try ObjectObservationFixture.jpeg()
        let preserved = directory.appendingPathComponent("preserved-phase-G.bin"); try jpeg.write(to: preserved)
        target = XT5ExactCleanupTarget(handle: 77,sourceSHA256: raw.sha256,outputSHA256: try ResourceChecksum.sha256(preserved),quarantineURL: preserved,
            objectInfo: Self.objectInfo(size: jpeg.count),storageInfo: Self.storageInfo())
    }
    static func objectInfo(size: Int) -> Data {
        var info = ObjectObservationFixture.info(byteCount: UInt32(size))
        info.replaceSubrange(26..<34,with: Data(repeating: 0,count: 8)); info.replaceSubrange(42..<44,with: ProtocolProbeFixtures.word(2055)); return info
    }
    static func storageInfo() -> Data {
        var info = ObjectObservationFixture.storage(); info[0] = 3; info[4] = 2; return info
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor CleanupWire: PTPTransport {
    enum Mode { case normal, multiple, wrongHandle, changedObject, changedStorage, changedPayload, lateObjectChange, deleteRejected, notEmptyAfterDelete, finalZero, finalMultiple, finalReplacement }
    let mode: Mode, jpeg: Data
    var commands: [PTPCommand] = []
    var triggerPayloads: [Data] = []
    private var deleted = false, triggered = false
    var closed = false
    var triggeredViews = 0
    private var oldInfoReads = 0
    init(jpeg: Data,mode: Mode = .normal) { self.jpeg = jpeg; self.mode = mode }
    func validate() throws { guard !closed else { throw PTPError.notConnected } }
    func close() { closed = true }
    func execute(_ c: PTPCommand,data: Data?) throws -> PTPReply {
        try Task.checkCancellation(); commands.append(c)
        let bytes: Data
        switch (c.opcode,c.parameters) {
        case (0x1001,[]): bytes = ProtocolProbeFixtures.deviceInfo(properties: [0xD16E,0xD183,0xD185,0xD186,0xD187],operations: [0x1001,0x1005,0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D],firmware: "4.31")
        case (0x1015,[0xD16E]): bytes = Data([6,0])
        case (0x1015,[0xD186]),(0x1015,[0xD187]): bytes = ProtocolProbeFixtures.string("X-T5_0200")
        case (0x1007,[UInt32.max,0,0]):
            if triggered {
                triggeredViews += 1
                if triggeredViews >= 4 && mode == .finalZero { bytes = Data([0,0,0,0]) }
                else if triggeredViews >= 4 && mode == .finalMultiple { bytes = Data([2,0,0,0,88,0,0,0,89,0,0,0]) }
                else { bytes = Data([1,0,0,0,triggeredViews >= 4 && mode == .finalReplacement ? 89 : 88,0,0,0]) }
            }
            else if deleted && mode != .notEmptyAfterDelete { bytes = Data([0,0,0,0]) }
            else if mode == .multiple { bytes = Data([2,0,0,0,77,0,0,0,78,0,0,0]) }
            else { bytes = Data([1,0,0,0,mode == .wrongHandle ? 78 : 77,0,0,0]) }
        case (0x1008,[77]),(0x1008,[88]),(0x1008,[89]):
            var value = CleanupFixture.objectInfo(size: jpeg.count)
            if c.parameters == [77] { oldInfoReads += 1 }
            if mode == .changedObject || (mode == .lateObjectChange && oldInfoReads > 1) { value[46] = 1 }
            bytes = value
        case (0x1005,[0x10001]):
            var value = CleanupFixture.storageInfo(); if mode == .changedStorage { value[4] = 0 }; bytes = value
        case (0x1009,[77]),(0x1009,[88]): bytes = mode == .changedPayload ? Data(repeating: 0,count: jpeg.count) : jpeg
        case (0x100B,[77,0]):
            if mode == .deleteRejected { throw PTPError.responseCode(0x2002) }
            deleted = true; bytes = Data()
        case (0x900C,[0,0,0]),(0x900D,[]): bytes = Data()
        case (0x1015,[0xD185]): bytes = Data(repeating: 0,count: 625)
        case (0x1016,[0xD183]): triggered = true; triggerPayloads.append(data ?? Data()); bytes = Data()
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode: c.opcode,parameters: [],logicalTransactionID: c.transactionID,wireTransactionID: c.transactionID+9,correlation: .imageCaptureCoreCallback(echoedCommand: c),responseCode: 0x2001,rawResponse: Data(),data: bytes)
    }
}
