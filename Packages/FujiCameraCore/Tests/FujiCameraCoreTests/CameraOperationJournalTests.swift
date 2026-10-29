@testable import FujiCameraCore
import Foundation
import Testing

struct CameraOperationJournalTests {
    @Test func deleteIntentSurvivesJournalReopen() throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        var record=try journal.create(raw:f.raw,recipe:f.profile.bank,context:f.context)
        record.phase = .captured;record.triggerIntent = true;record.outputValidated = true
        record.outputHandle=31;record.outputSHA256="synthetic";record.objectInfo=Data([1]);record.storageInfo=Data([2])
        try journal.save(record)
        try journal.beginDelete(&record)
        let reopened=try CameraOperationJournal(directory:journal.directory, filePolicy: TestJournalFilePolicy())
        let loaded=try reopened.load(record.id)
        #expect(loaded.phase == .deleteIntent && loaded.deleteIntent)
        #expect(try reopened.unresolved().map(\.id) == [record.id])
        #expect(loaded.recipeSnapshotID == f.profile.bank.id && loaded.sourceSHA256 == f.raw.sha256)
        var replay=loaded
        #expect(throws: CameraServiceError.uncertainOperation(record.id)) { try reopened.beginDelete(&replay) }
    }
    @Test func partialMarkerBlocksEvenIfJournalWriteNeverRecordedIntent() throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        var record=try journal.create(raw:f.raw,recipe:f.profile.bank,context:f.context)
        record.phase = .captured;record.outputValidated=true;record.outputHandle=31;record.outputSHA256="synthetic";record.objectInfo=Data([1]);record.storageInfo=Data([2])
        try journal.save(record)
        try Data([0]).write(to:journal.operationDirectory(record.id).appendingPathComponent("delete-intent.json"))
        #expect(throws: CameraServiceError.uncertainOperation(record.id)) { try journal.beginDelete(&record) }
        #expect(try journal.unresolved().count == 1)
    }
    @Test func completionDoesNotRequireRetainingDuplicateAdoptedImageAndMalformedRecordBlocks() throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        var record=try journal.create(raw:f.raw,recipe:f.profile.bank,context:f.context)
        record.phase = .completed;record.deleteAcknowledged=true;record.emptyViewVerified=true
        try journal.save(record)
        #expect(try CameraOperationJournal(directory:journal.directory, filePolicy: TestJournalFilePolicy()).unresolved().isEmpty)
        try Data([0]).write(to:journal.operationDirectory(record.id).appendingPathComponent("journal.json"))
        #expect(throws: CameraServiceError.storage) { try journal.unresolved() }
    }
}

struct ProductionOperationFixture {
    let profile:ProductionProfileFixture,directory:URL,raw:PreparedRAW,context:CameraExecutionContext
    init() throws {
        profile=try ProductionProfileFixture()
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("synthetic.RAF");try Data(repeating:42,count:256).write(to:url)
        raw=PreparedRAW(fileURL:url,sha256:try ResourceChecksum.sha256(url),sourceID:"synthetic-source",sourceRevision:"v1",metadata:profile.metadata)
        context=CameraExecutionContext(model:"X-T5",firmware:"4.31",capability:"X-T5_0200",supportVersion:XT5WorkingProfile.supportVersion,sessionIdentity:UUID(),generation:1)
    }
    func remove() { try? FileManager.default.removeItem(at:directory) }
}
