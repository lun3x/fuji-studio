import Foundation
import Testing
@testable import FujiStudio

struct XT5RecipeBatchTests {
    @Test func finitePatchPreservesOpaqueBytesAndUsesSignedRawDials() throws {
        let f = try BatchFixture()
        let patch = try XT5FiniteRecipePatch.make(bank: f.banks[6], referenceBanks: f.banks, reference: f.reference)
        #expect(patch.bytes.count == 625)
        #expect(patch.bytes.subdata(in: 561..<565) == Data([0xfc,0xff,0xff,0xff]))
        #expect(patch.bytes.subdata(in: 573..<577) == Data([0xec,0xff,0xff,0xff]))
        #expect(patch.bytes[545] == 3)
        let allowed = Set(XT5FiniteRecipePatch.offsets.flatMap { Array($0..<$0+4) })
        #expect((0..<625).filter { !allowed.contains($0) }.allSatisfy { patch.bytes[$0] == f.baseline[$0] })
        #expect(!patch.dormantGrainSizeNotApplied)
        let off = try XT5FiniteRecipePatch.make(bank: f.banks[0], referenceBanks: f.banks, reference: f.reference)
        #expect(off.bytes[545] == 1 && off.dormantGrainSizeNotApplied)
    }
    @Test func finitePatchRejectsChangedSnapshotUnknownDomainAndBaselineWord() throws {
        let f = try BatchFixture()
        var changed = f.properties; changed[0xD197] = 4
        let bad = try f.bank(slot: 1, properties: changed)
        #expect(throws: XT5RecipeBatchIssue.self) { try XT5FiniteRecipePatch.make(bank: bad, referenceBanks: f.banks, reference: f.reference) }
        var invalidBanks = f.banks; invalidBanks[0] = bad
        #expect(throws: XT5RecipeBatchIssue.self) { try XT5FiniteRecipePatch.make(bank: bad, referenceBanks: invalidBanks, reference: f.reference) }
        var baseline = f.baseline; baseline[553] = 2
        #expect(throws: XT5RecipeBatchIssue.self) { try XT5FiniteRecipePatch.make(bank: f.banks[0], referenceBanks: f.banks, reference: .init(sourceSHA256: "synthetic", baseline: baseline)) }
    }
}
struct BatchFixture {
    let baseline: Data
    let properties: [UInt16:UInt16]
    let banks: [RecipeSnapshot]
    var reference: XT5FilmProbeReference { .init(sourceSHA256: "synthetic", baseline: baseline) }
    init() throws {
        var b = Data(repeating: 0xa5, count: 625); b.replaceSubrange(0..<3,with: [29,0,8])
        let words: [Int:UInt32] = [5:400,7:15,8:1,9:3,10:1,11:0,12:3,13:UInt32(bitPattern: -4),14:0,15:20,16:20,17:0,18:0,19:32768,20:2,21:1,22:0,24:3,25:0,26:0,6:0]
        for (i,v) in words { b.replaceSubrange(513+i*4..<517+i*4,with: (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
        baseline = b
        var p = Dictionary(uniqueKeysWithValues: (UInt16(0xD18E)...0xD1A4).map { ($0,UInt16(1)) })
        for (k,v): (UInt16,UInt16) in [0xD190:400,0xD191:0,0xD192:11,0xD193:0,0xD194:0,0xD195:7,0xD196:3,0xD197:2,0xD198:1,0xD199:2,0xD19A:65532,0xD19B:3,0xD19C:6700,0xD19D:65516,0xD19E:20,0xD19F:0,0xD1A0:0,0xD1A1:32768,0xD1A2:0] { p[k] = v }
        properties = p
        banks = try (1...7).map { slot in var values = p; if slot == 7 { values[0xD195] = 3 }; return try Self.makeBank(slot: slot, properties: values) }
    }
    func bank(slot: Int, properties: [UInt16:UInt16]) throws -> RecipeSnapshot { try Self.makeBank(slot: slot, properties: properties) }
    private static func makeBank(slot: Int, properties: [UInt16:UInt16]) throws -> RecipeSnapshot {
        try XT5RecipeCodec.recipe(slot: slot, nameData: ProtocolProbeFixtures.string("Synthetic \(slot)"), properties: properties.mapValues { ProtocolProbeFixtures.word($0) }, context: .init(model: "X-T5",firmware: "4.31",capability: "X-T5_0200",sessionIdentity: UUID(),sessionGeneration: 1), importedAt: Date())
    }
}

extension XT5RecipeBatchTests {
    @Test func batchSequentiallyCapturesAllSevenCleansExactOutputsAndClosesOnce() async throws {
        let f = try BatchRunFixture(); defer { f.remove() }
        let wire = BatchWire(fixture:f)
        let result = try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory)
        #expect(result.complete && result.beforeBanksMatch && result.afterBanksMatch)
        #expect(result.slots.map(\.slot) == [7,1,2,3,4,5,6])
        #expect(result.slots.allSatisfy { $0.capture?.batchTrialCaptured == true && $0.capture?.probeFinished == false && $0.capture?.sessionClosure == "heldByBatchOwner" && $0.cleanup?.emptyViewVerified == true })
        #expect(result.sessionClosure == "confirmed")
        #expect(await wire.closes == 1)
        #expect(await wire.triggers == 7)
        #expect(await wire.deletes == [88,101,102,103,104,105,106,107])
        #expect(await wire.selected == 1)
        #expect(await wire.writes.count == 7)
        #expect(await wire.operationsInOrder)
        #expect(FileManager.default.fileExists(atPath:f.target.attemptURL.path))
    }
    @Test func batchStopsAtMismatchWithoutNextTrialOrUnsafeDeletionAndStillCloses() async throws {
        for mode in [BatchWire.Mode.bankMismatch,.readbackMismatch,.cleanupChanged,.afterBankMismatch,.lostContext] {
            let f = try BatchRunFixture(); defer { f.remove() }
            let wire = BatchWire(fixture:f,mode:mode)
            do { _ = try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory); Issue.record("Expected batch refusal") }
            catch let failure as XT5RecipeBatchFailure {
                #expect(!failure.evidence.complete && failure.evidence.sessionClosure == "confirmed")
                if mode == .bankMismatch { #expect(await wire.deletes == [88]); #expect(await wire.writes.isEmpty); #expect(await wire.triggers == 0) }
                if mode == .readbackMismatch || mode == .lostContext { #expect(await wire.triggers == 0); #expect(await wire.deletes == [88]) }
                if mode == .cleanupChanged { #expect(await wire.triggers == 1); #expect(await wire.deletes == [88]) }
                if mode == .afterBankMismatch { #expect(await wire.triggers == 7 && !failure.evidence.afterBanksMatch) }
            }
            #expect(await wire.closes == 1)
        }
    }
    @Test func emptyViewSkipsOldDeletionAndCancellationNeverStartsNextTrial() async throws {
        let f = try BatchRunFixture(); defer { f.remove() }
        let wire = BatchWire(fixture:f,mode:.initiallyEmpty)
        let task = Task { try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory) { report in
            if report.slots.last?.capture?.rawUploadSucceeded == true { withUnsafeCurrentTask { $0?.cancel() } }
        } }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch let failure as XT5RecipeBatchFailure { #expect(failure.evidence.initialOutputAbsent && failure.evidence.sessionClosure == "confirmed") }
        #expect(await wire.deletes.isEmpty); #expect(await wire.triggers == 0); #expect(await wire.closes == 1)
    }
    @Test func wrongSourceAndUnconfirmedNativeCloseCannotCompleteBatch() async throws {
        let f=try BatchRunFixture();defer { f.remove() }
        let wire=BatchWire(fixture:f)
        let probe=XT5RecipeBatchProbe(transport:wire,sessionGeneration:1,validateSession:{ try await wire.validate() },closeSession:{ await wire.close();throw XT5BankImportIssue.sessionChanged },settle:{ _ in },pollWait:{})
        do {
            _ = try await probe.run(raw:f.raw,reference:.init(sourceSHA256:"different source",baseline:f.codec.baseline),referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory)
            Issue.record("Expected source and close refusal")
        } catch let failure as XT5RecipeBatchFailure {
            #expect(!failure.evidence.complete && failure.evidence.sessionClosure == "unconfirmed")
            #expect(!failure.evidence.beforeBanksMatch)
        }
        #expect(await wire.deletes.isEmpty)
        #expect(await wire.writes.isEmpty)
        #expect(await wire.triggers == 0)
        #expect(await wire.closes == 1)
    }
    @Test func cancellationBeforeGateStillClosesWithoutCameraCommands() async throws {
        let f=try BatchRunFixture();defer { f.remove() }
        let wire=BatchWire(fixture:f)
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory)
                Issue.record("Expected pre-entry cancellation")
            } catch let failure as XT5RecipeBatchFailure {
                #expect(failure.evidence.sessionClosure == "confirmed" && !failure.evidence.complete)
            } catch { Issue.record("Cancellation escaped the batch close owner") }
        }
        await task.value
        #expect(await wire.closes == 1)
        #expect(await wire.deletes.isEmpty)
        #expect(await wire.writes.isEmpty)
    }
    @Test func knownOutputMaintenancePrecedesBusySelectorButBankEqualityStillPrecedesUpload() async throws {
        let f=try BatchRunFixture();defer { f.remove() }
        let wire=BatchWire(fixture:f,mode:.busyWithOutput)
        let result=try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory)
        #expect(result.complete && result.initialCleanup?.emptyViewVerified == true && result.beforeBanksMatch)
        #expect(await wire.selectorWritesWhileObjectPresent == 0)
        #expect(await wire.triggers == 7)
        #expect(await wire.closes == 1)
    }
    @Test func freshContextAndInitialObjectViewRefusalsNeverDeleteOrSelect() async throws {
        for mode in [BatchWire.Mode.wrongFirmware,.wrongMode,.wrongKey,.handleReadFails] {
            let f=try BatchRunFixture();defer { f.remove() }
            let wire=BatchWire(fixture:f,mode:mode)
            do { _ = try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory); Issue.record("Expected fresh context/view refusal") }
            catch let failure as XT5RecipeBatchFailure { #expect(failure.evidence.sessionClosure == "confirmed" && !failure.evidence.complete) }
            #expect(await wire.deletes.isEmpty)
            #expect(await wire.selectorWrites == 0)
            #expect(await wire.writes.isEmpty)
            #expect(await wire.triggers == 0)
        }
    }
    @Test func firstFailedSelectorCommandSurvivesDifferentRestorationFailure() async throws {
        for mode in [BatchWire.Mode.selectorBusy,.selectorReadbackBusy] {
            let f=try BatchRunFixture();defer { f.remove() }
            let wire=BatchWire(fixture:f,mode:mode)
            do { _ = try await batch(wire).run(raw:f.raw,reference:f.reference,referenceBanks:f.codec.banks,initialTarget:f.target,directory:f.directory); Issue.record("Expected selector failure") }
            catch let failure as XT5RecipeBatchFailure {
                let first=try #require(failure.evidence.beforeScan?.firstFailedCommand)
                #expect(first.opcode == (mode == .selectorBusy ? "0x1016" : "0x1015"))
                #expect(first.property == "0xD18C" && first.responseCode == "0x2019")
                #expect(first.stage == (mode == .selectorBusy ? "scan 1 C1 selector write" : "scan 1 C1 selector readback"))
                #expect(failure.evidence.beforeScan?.restorationFailure == "PTP response 0x2002")
                #expect(failure.evidence.beforeScan?.restoration == .unconfirmed)
                #expect(failure.evidence.sessionClosure == "confirmed")
            }
            #expect(await wire.selectorWrites == 2)
            #expect(await wire.deletes == [88])
            #expect(await wire.writes.isEmpty)
            #expect(await wire.triggers == 0)
        }
    }
    private func batch(_ wire: BatchWire) -> XT5RecipeBatchProbe {
        .init(transport:wire,sessionGeneration:1,validateSession:{ try await wire.validate() },closeSession:{ await wire.close() },settle:{ _ in },pollWait:{})
    }
}
private struct BatchRunFixture {
    let codec: BatchFixture, directory: URL, raw: PreparedRAW, jpeg: Data, target: XT5ExactCleanupTarget
    var reference: XT5FilmProbeReference { .init(sourceSHA256:raw.sha256,baseline:codec.baseline) }
    init() throws {
        codec = try BatchFixture(); directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let source = directory.appendingPathComponent("source.RAF"); try Data(repeating:0x52,count:256).write(to:source)
        raw = PreparedRAW(fileURL:source,sha256:try ResourceChecksum.sha256(source),sourceID:"synthetic",sourceRevision:"synthetic",metadata:ObjectObservationFixture.metadata)
        jpeg = try ObjectObservationFixture.jpeg()
        let old = directory.appendingPathComponent("old",isDirectory:true); try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
        let image = old.appendingPathComponent("quarantined-candidate.bin"); try jpeg.write(to:image)
        var storage = ObjectObservationFixture.storage(); storage[0] = 3; storage[4] = 2
        var info = ObjectObservationFixture.info(byteCount:UInt32(jpeg.count)); info.replaceSubrange(26..<34,with:Data(repeating:0,count:8)); info.replaceSubrange(42..<44,with:ProtocolProbeFixtures.word(2055))
        target = XT5ExactCleanupTarget(handle:88,sourceSHA256:raw.sha256,outputSHA256:try ResourceChecksum.sha256(image),quarantineURL:image,objectInfo:info,storageInfo:storage)
    }
    func remove() { try? FileManager.default.removeItem(at:directory) }
}
private actor BatchWire: PTPTransport {
    enum Mode { case normal, bankMismatch, readbackMismatch, cleanupChanged, afterBankMismatch, lostContext, initiallyEmpty, busyWithOutput, wrongFirmware, wrongMode, wrongKey, handleReadFails, selectorBusy, selectorReadbackBusy }
    let f: BatchRunFixture, mode: Mode
    var selected = 1, closes = 0, triggers = 0, deletes: [UInt32] = [], writes: [Data] = []
    var selectorWrites = 0, selectorWritesWhileObjectPresent = 0
    var operationsInOrder = true
    private var handle: UInt32?, profile: Data?, current = true, reads = 0, uploaded = false
    init(fixture:BatchRunFixture,mode:Mode = .normal) { f=fixture;self.mode=mode;handle=mode == .initiallyEmpty ? nil : 88 }
    func validate() throws { guard current else { throw XT5BankImportIssue.sessionChanged } }
    func close() { closes += 1; current=false }
    func execute(_ c: PTPCommand,data:Data?) throws -> PTPReply {
        let bytes: Data
        switch(c.opcode,c.parameters) {
        case (0x1001,[]): bytes=ProtocolProbeFixtures.deviceInfo(properties:[0xD16E,0xD183,0xD185,0xD186,0xD187,0xD18C,0xD18D]+Array(0xD18E...0xD1A4),operations:[0x1001,0x1005,0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D],firmware:mode == .wrongFirmware ? "different" : "4.31")
        case (0x1015,[0xD16E]): bytes=Data([mode == .wrongMode ? 1 : 6,0])
        case (0x1015,[0xD186]),(0x1015,[0xD187]): bytes=ProtocolProbeFixtures.string(mode == .wrongKey ? "X-T5_0100" : "X-T5_0200")
        case (0x1015,[0xD18C]): if mode == .selectorReadbackBusy && selectorWrites == 1 { throw PTPError.responseCode(0x2019) };bytes=ProtocolProbeFixtures.word(UInt16(selected))
                case (0x1016,[0xD18C]):
            selectorWrites += 1
            if handle != nil { selectorWritesWhileObjectPresent += 1 }
            if mode == .busyWithOutput && handle != nil { throw PTPError.responseCode(0x2019) }
            if mode == .selectorBusy { throw PTPError.responseCode(selectorWrites == 1 ? 0x2019 : 0x2002) }
            if mode == .selectorReadbackBusy && selectorWrites > 1 { throw PTPError.responseCode(0x2002) }
            selected=Int(data![0]);bytes=Data()

        case (0x1015,[0xD18D]):
            let changed = mode == .bankMismatch || (mode == .afterBankMismatch && triggers == 7)
            bytes=ProtocolProbeFixtures.string(changed ? "Changed" : "Synthetic \(selected)")
        case (0x1015,let params) where params.count == 1 && (0xD18E...0xD1A4).contains(params[0]): let code=params[0]; bytes=f.codec.banks[selected-1].importedSettings.first { $0.code == code }!.raw
        case (0x1007,[UInt32.max,0,0]): if mode == .handleReadFails { throw PTPError.responseCode(0x2019) }; bytes=handle.map { h in Data([1,0,0,0])+Data((0..<4).map { i in UInt8(truncatingIfNeeded:h >> (i*8)) }) } ?? Data([0,0,0,0])
        case (0x1008,let params) where params.count == 1: let h=params[0]
            guard h == handle else { throw PTPError.invalidParameters }; reads += 1
            var info=f.target.objectInfo; if mode == .cleanupChanged && triggers == 1 && reads > 6 { info[40] ^= 1 };bytes=info
        case (0x1005,[0x10001]): bytes=f.target.storageInfo
        case (0x1009,let params) where params.count == 1: let h=params[0]; guard h == handle else { throw PTPError.invalidParameters }; bytes=f.jpeg
        case (0x100B,let params) where params.count == 2 && params[1] == 0: let h=params[0]; guard h == handle else { throw PTPError.invalidParameters };deletes.append(h);handle=nil;bytes=Data()
        case (0x900C,[0,0,0]): operationsInOrder = operationsInOrder && handle == nil;bytes=Data()
        case (0x900D,[]): uploaded=true;profile=nil;bytes=Data()
        case (0x1015,[0xD185]): var p=profile ?? f.codec.baseline; if mode == .readbackMismatch && profile != nil { p[600] ^= 1 };bytes=p
        case (0x1016,[0xD185]): writes.append(data!);profile=data;if mode == .lostContext { current=false };bytes=Data()
        case (0x1016,[0xD183]): operationsInOrder = operationsInOrder && uploaded && profile != nil && data == Data([1,0]) && handle == nil;triggers += 1;handle=UInt32(100+triggers);uploaded=false;bytes=Data()
        default: throw PTPError.invalidParameters
        }
        return PTPReply(opcode:c.opcode,parameters:[],logicalTransactionID:c.transactionID,wireTransactionID:c.transactionID+9,correlation:.imageCaptureCoreCallback(echoedCommand:c),responseCode:0x2001,rawResponse:Data(),data:bytes)
    }
}
#if DEBUG
extension XT5RecipeBatchTests {
    @Test func batchLoaderRequiresJCreationProofAndCompleteMatchingRetainedBanks() async throws {
        let f=try BatchRunFixture();defer { f.remove() }
        let root=f.directory.appendingPathComponent("xt5-film-only-private",isDirectory:true)
        let run=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
        try f.jpeg.write(to:run.appendingPathComponent("quarantined-candidate.bin"))
        try f.target.objectInfo.write(to:run.appendingPathComponent("output-object-info.bin"))
        try f.target.objectInfo.write(to:run.appendingPathComponent("output-object-info-after.bin"))
        try f.target.storageInfo.write(to:run.appendingPathComponent("output-storage-info.bin"))
        let conversion:[String:Any] = ["sourceSHA256":f.raw.sha256,"outputSHA256":f.target.outputSHA256,"candidateHandle":88,"readOnlyRecovery":false,"privateQuarantine":true,"handleViews":[[],[88],[88]]]
        try JSONSerialization.data(withJSONObject:conversion).write(to:run.appendingPathComponent("conversion-manifest.json"))
        let proto:[String:Any] = ["sourceSHA256":f.raw.sha256,"beforeHandles":[],"afterHandles":[88]]
        try JSONSerialization.data(withJSONObject:proto).write(to:run.appendingPathComponent("protocol-manifest.json"))
        try JSONEncoder().encode(["sha256":f.raw.sha256,"filename":"source.RAF","retainedRun":f.raw.fileURL.deletingLastPathComponent().lastPathComponent]).write(to:run.appendingPathComponent("source-reference.json"))
        for name in ["baseline.bin","profile-echo.bin","profile-echo-readback.bin"] { try f.codec.baseline.write(to:run.appendingPathComponent(name)) }
        var film=f.codec.baseline;film[541]=11
        for name in ["profile-film-patch.bin","profile-film-readback.bin"] { try film.write(to:run.appendingPathComponent(name)) }
        struct Capture: Encodable { let complete:Bool;let snapshots:[RecipeSnapshot];let verificationSnapshots:[RecipeSnapshot] }
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let bankURL=f.directory.appendingPathComponent("xt5-bank-import-private.json")
        try encoder.encode(Capture(complete:true,snapshots:f.codec.banks,verificationSnapshots:f.codec.banks)).write(to:bankURL)
        let input=try await RetainedRecipeBatchInputs.prepare(documents:f.directory,raw:f.raw,reference:f.reference,destination:f.directory)
        #expect(XT5FiniteRecipePatch.sameBanks(input.banks,f.codec.banks))
        #expect(input.target.handle == 88)
        try encoder.encode(Capture(complete:false,snapshots:f.codec.banks,verificationSnapshots:f.codec.banks)).write(to:bankURL)
        await #expect(throws: XT5RecipeBatchIssue.self) { try await RetainedRecipeBatchInputs.prepare(documents:f.directory,raw:f.raw,reference:f.reference,destination:f.directory) }
        try encoder.encode(Capture(complete:true,snapshots:f.codec.banks,verificationSnapshots:f.codec.banks)).write(to:bankURL)
        try Data([1]).write(to:run.appendingPathComponent("exact-cleanup-attempt.json"))
        await #expect(throws: XT5ExactCleanupIssue.self) { try await RetainedRecipeBatchInputs.prepare(documents:f.directory,raw:f.raw,reference:f.reference,destination:f.directory) }
    }
}
#endif
