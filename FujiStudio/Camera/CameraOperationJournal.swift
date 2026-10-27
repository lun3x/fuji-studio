import Foundation

enum CameraOperationPhase: String, Sendable, Codable {
    case prepared, uploadIntent, baselineReceived, profileIntent, profileAccepted
    case triggerIntent, triggerAccepted, captured, deleteIntent, deleteAcknowledged
    case completed, aborted, uncertain, reconciledMissing
}

struct CameraOperationRecord: Sendable, Codable {
    let id: UUID
    let context: CameraExecutionContext
    let sourceID: SourceID, sourceRevision: String, sourceSHA256: String
    let recipeSnapshotID: UUID
    let settingsDigest: String
    let width: Int, height: Int, orientation: Int
    var phase: CameraOperationPhase = .prepared
    var baselineSHA256: String?, candidateSHA256: String?
    var initialViewEmpty = false
    var triggerIntent = false
    var triggerAcknowledged = false
    var outputHandle: UInt32?
    var outputSHA256: String?
    var objectInfo: Data?, storageInfo: Data?
    var outputValidated = false
    var deleteIntent = false
    var deleteAcknowledged = false
    var emptyViewVerified = false
    var closure: String = "notRequested"
    var failure: String?
    var result: CameraJPEG?
}

/// One service/gate owns updates. Exclusive marker creation also prevents replay after process loss.
/// JSON and markers are file-synchronized; a partial/malformed journal refuses admission.
struct CameraOperationJournal: Sendable {
    let directory: URL
    init(directory: URL) throws {
        self.directory=directory
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete]) }
        catch { throw CameraServiceError.storage }
    }
    func operationDirectory(_ id:UUID)->URL { directory.appendingPathComponent(id.uuidString,isDirectory:true) }
    func create(raw:PreparedRAW,recipe:RecipeSnapshot,context:CameraExecutionContext) throws -> CameraOperationRecord {
        let record=CameraOperationRecord(id:UUID(),context:context,sourceID:raw.sourceID,sourceRevision:raw.sourceRevision,sourceSHA256:raw.sha256,
            recipeSnapshotID:recipe.id,settingsDigest:recipe.settingsDigest,width:raw.metadata.recordedGeometry.width,height:raw.metadata.recordedGeometry.height,orientation:raw.metadata.orientation)
        do { try FileManager.default.createDirectory(at:operationDirectory(record.id),withIntermediateDirectories:false,attributes:[.protectionKey:FileProtectionType.complete]) }
        catch { throw CameraServiceError.storage }
        try save(record)
        return record
    }
    func save(_ record:CameraOperationRecord) throws {
        if record.phase == .completed && (!record.deleteAcknowledged || !record.emptyViewVerified) { throw CameraServiceError.uncertainOperation(record.id) }
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            let data=try encoder.encode(record)
            guard data.count <= 1_048_576 else { throw CameraServiceError.storage }
            try durable(data,to:operationDirectory(record.id).appendingPathComponent("journal.json"),exclusive:false)
        } catch { throw CameraServiceError.storage }
    }
    func load(_ id:UUID) throws -> CameraOperationRecord {
        do {
            let url=operationDirectory(id).appendingPathComponent("journal.json")
            guard let count=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,count > 0,count <= 1_048_576 else { throw CameraServiceError.storage }
            let record=try JSONDecoder().decode(CameraOperationRecord.self,from:Data(contentsOf:url))
            guard record.id == id else { throw CameraServiceError.storage }
            return record
        } catch { throw CameraServiceError.storage }
    }
    func unresolved() throws -> [CameraOperationRecord] {
        do {
            let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)
            var records:[CameraOperationRecord]=[]
            for url in urls {
                guard let id=UUID(uuidString:url.lastPathComponent) else { throw CameraServiceError.storage }
                let record=try load(id)
                if record.phase != .completed && record.phase != .aborted && record.phase != .reconciledMissing { records.append(record) }
            }
            return records
        } catch { throw CameraServiceError.storage }
    }
    func beginDelete(_ record:inout CameraOperationRecord) throws {
        guard record.phase == .captured,record.outputValidated,record.outputHandle != nil,
              record.outputSHA256 != nil,record.objectInfo != nil,record.storageInfo != nil,!record.deleteIntent else { throw CameraServiceError.uncertainOperation(record.id) }
        let marker=operationDirectory(record.id).appendingPathComponent("delete-intent.json")
        guard !FileManager.default.fileExists(atPath:marker.path) else { throw CameraServiceError.uncertainOperation(record.id) }
        do {
            let data=try JSONEncoder().encode(["operation":record.id.uuidString,"intent":"one exact delete; never replay"])
            try durable(data,to:marker,exclusive:true)
        } catch { throw CameraServiceError.uncertainOperation(record.id) }
        record.deleteIntent=true;record.phase = .deleteIntent
        try save(record)
    }
    @discardableResult func store(_ data:Data,name:String,id:UUID) throws -> URL {
        guard ["baseline.bin","candidate.bin","readback.bin","output.JPG"].contains(name),data.count <= PTPCodec.maximumDataBytes else { throw CameraServiceError.storage }
        let url=operationDirectory(id).appendingPathComponent(name)
        do { try durable(data,to:url,exclusive:true) }
        catch { throw CameraServiceError.storage }
        return url
    }
    private func durable(_ data:Data,to url:URL,exclusive:Bool) throws {
        try data.write(to:url,options:exclusive ? [.withoutOverwriting,.completeFileProtection] : [.atomic,.completeFileProtection])
        let handle=try FileHandle(forWritingTo:url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
