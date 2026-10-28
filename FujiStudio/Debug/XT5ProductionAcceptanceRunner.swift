import FujiCameraCore
#if DEBUG
import Foundation
import Observation

struct XT5ProductionAcceptanceInputs: Sendable {
    let a: PreparedRAW, b: PreparedRAW
    let banks: [RecipeSnapshot]
}

enum RetainedProductionAcceptanceInputs {
    private struct BankCapture: Decodable { let complete:Bool;let snapshots:[RecipeSnapshot];let verificationSnapshots:[RecipeSnapshot] }
    private struct Manifest: Decodable {
        let sourceID:String,sourceRevision:String,originalFilename:String,resourceRole:String,sha256:String
        let pairedJPEGAvailable:Bool
        let jpegSourceID:String?,jpegSourceRevision:String?,jpegResourceRole:String?
        let containerWidth:Int,containerHeight:Int,recordedWidth:Int,recordedHeight:Int,aspectWidth:Int,aspectHeight:Int,cropTop:Int,cropLeft:Int,orientation:Int
    }
    private struct ProtocolManifest: Decodable { let sourceSHA256:String }
    static func prepare(documents:URL,destination:URL) async throws -> XT5ProductionAcceptanceInputs {
        let task=Task.detached { () throws -> XT5ProductionAcceptanceInputs in
            let a=try loadSource(root:documents.appendingPathComponent("xt5-raw-baseline-private"),paired:false).raw
            try Task.checkCancellation()
            let b=try loadSource(root:documents.appendingPathComponent("xt5-paired-baseline-private"),paired:true).raw
            guard a.sha256 != b.sha256,a.sourceID != b.sourceID else { throw CameraServiceError.sourceChanged }
            let bytes=try bounded(documents.appendingPathComponent("xt5-bank-import-private.json"),limit:1_048_576)
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            let capture=try decoder.decode(BankCapture.self,from:bytes)
            guard capture.complete,XT5FiniteRecipePatch.sameBanks(capture.snapshots,capture.verificationSnapshots) else { throw CameraServiceError.unsupportedSettings }
            for recipe in capture.snapshots { _ = try recipe.settings(using: RecipeCodecRegistry()) }
            try Task.checkCancellation()
            try bytes.write(to:destination.appendingPathComponent("frozen-banks.json"),options:[.atomic,.completeFileProtection])
            let binding=["sourceA":a.fileURL.path,"sourceASHA256":a.sha256,"sourceAID":a.sourceID,"sourceARevision":a.sourceRevision,
                         "sourceB":b.fileURL.path,"sourceBSHA256":b.sha256,"sourceBID":b.sourceID,"sourceBRevision":b.sourceRevision]
            try JSONEncoder().encode(binding).write(to:destination.appendingPathComponent("source-bindings.json"),options:[.atomic,.completeFileProtection])
            return XT5ProductionAcceptanceInputs(a:a,b:b,banks:capture.snapshots)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel:{ task.cancel() }
    }
    static func loadSource(root:URL,paired:Bool) throws -> RetainedRAWSource {
        let entries=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        let candidates=entries.filter { UUID(uuidString:$0.lastPathComponent) != nil && FileManager.default.fileExists(atPath:$0.appendingPathComponent("source.RAF").path) && FileManager.default.fileExists(atPath:$0.appendingPathComponent("source-manifest.json").path) }
        guard candidates.count == 1,let run=candidates.first else { throw CameraServiceError.sourceChanged }
        let manifest=try JSONDecoder().decode(Manifest.self,from:bounded(run.appendingPathComponent("source-manifest.json"),limit:65_536))
        let proto=try JSONDecoder().decode(ProtocolManifest.self,from:bounded(run.appendingPathComponent("protocol-manifest.json"),limit:1_048_576))
        guard manifest.pairedJPEGAvailable == paired,manifest.sha256 == proto.sourceSHA256,
              let role=ResourceRole(rawValue:manifest.resourceRole),role != .adjusted else { throw CameraServiceError.sourceChanged }
        if paired {
            guard manifest.jpegSourceID == manifest.sourceID,manifest.jpegSourceRevision == manifest.sourceRevision,
                  let jpegRole=manifest.jpegResourceRole.flatMap(ResourceRole.init(rawValue:)),jpegRole != .adjusted,jpegRole != role else { throw CameraServiceError.sourceChanged }
        }
        let token=ResourceToken(assetID:manifest.sourceID,role:role,contentTypeIdentifier:"com.fuji.raw-image",format:.raf,originalFilename:manifest.originalFilename,discriminator:"retained-original",sourceRevision:manifest.sourceRevision)
        let raw=try RAFMetadataReader().prepare(LocalResource(token:token,fileURL:run.appendingPathComponent("source.RAF"),checksum:manifest.sha256))
        let m=raw.metadata
        guard m.containerGeometry == PixelSize(width:manifest.containerWidth,height:manifest.containerHeight),
              m.recordedGeometry == PixelSize(width:manifest.recordedWidth,height:manifest.recordedHeight),
              m.recordedAspect == PixelSize(width:manifest.aspectWidth,height:manifest.aspectHeight),
              m.cropTop == manifest.cropTop,m.cropLeft == manifest.cropLeft,m.orientation == manifest.orientation else { throw CameraServiceError.sourceChanged }
        try XT5WorkingProfile.validateSource(m)
        return RetainedRAWSource(raw:raw,rafRole:role,jpegRole:manifest.jpegResourceRole.flatMap(ResourceRole.init(rawValue:)),originalFilename:manifest.originalFilename,manifestURL:run.appendingPathComponent("source-manifest.json"),protocolURL:run.appendingPathComponent("protocol-manifest.json"))
    }
    private static func bounded(_ url:URL,limit:Int) throws -> Data {
        guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size > 0,size <= limit else { throw CameraServiceError.sourceChanged }
        return try Data(contentsOf:url)
    }
}

struct XT5ProductionAcceptanceEvidence: Encodable {
    struct Trial: Encodable {
        let source:String,width:Int,height:Int,orientation:Int,bytes:Int
        let fullResolutionFine:Bool,lensOptimizerRequested:Bool,lensOptimizerEffective:Bool,lensOptimizerAdjusted:Bool
        let outputCleanupConfirmed:Bool
    }
    let schemaVersion=1
    var model:String?,firmware:String?,capability:String?
    var stage="preparing retained sources"
    var trialCount=0,trials:[Trial]=[]
    var banksPreserved=false,sameFrozenSnapshot=false,sameAKey=false,differentBKey=false
    var nativeClosure="notOpened",complete=false,failure:String?
    let inputBufferLifetime="unknown"
    let generalSourceSupport=false
}

/// Explicit acceptance calls the real service. No alternate converter, Photos or source fallback.
@MainActor @Observable final class XT5ProductionAcceptanceRunner {
    typealias Prepare = @Sendable (URL,URL) async throws -> XT5ProductionAcceptanceInputs
    typealias ServiceFactory = @MainActor (URL) throws -> any CameraServing
    var status="Production acceptance has not run"
    private let native:ImageCaptureTransport
    private let requestedDirectory:URL?
    private let prepare:Prepare
    private let makeService:ServiceFactory
    private var didRun=false
    init(transport:ImageCaptureTransport=ImageCaptureTransport(),directory:URL?=nil,
         prepare:@escaping Prepare = { try await RetainedProductionAcceptanceInputs.prepare(documents:$0,destination:$1) },makeService:ServiceFactory?=nil) {
        native=transport;requestedDirectory=directory;self.prepare=prepare
        self.makeService=makeService ?? { root in FujiCameraService(session:ImageCaptureSessionTransport(native:transport),journal:try CameraOperationJournal(directory:root, filePolicy: IOSCameraJournalFilePolicy())) }
    }
    func runIfRequested(arguments:[String]) async {
        let others=["--xt5-read-only-probe","--xt5-direct-values-probe","--camera-reconnect-probe","--xt5-bank-import-probe","--xt5-raw-baseline-probe","--xt5-paired-baseline-probe","--xt5-unchanged-baseline-probe","--xt5-output-recovery-probe","--xt5-output-quarantine-probe","--xt5-trigger-one-probe","--xt5-film-only-probe","--xt5-recipe-batch-probe"]
        guard arguments.contains("--xt5-production-acceptance-probe"),!others.contains(where:arguments.contains),!didRun else { return }
        didRun=true
        var evidence=XT5ProductionAcceptanceEvidence()
        var output:URL?,service:(any CameraServing)?
        do {
            let documents=try requestedDirectory ?? FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let root=documents.appendingPathComponent("xt5-production-acceptance-private",isDirectory:true)
            let run=root.appendingPathComponent("runs").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
            output=documents;try save(evidence,to:documents)
            let inputs=try await prepare(documents,run)
            guard inputs.a.sha256 != inputs.b.sha256,let frozen=inputs.banks.first(where:{ $0.slot == 7 }),
                  XT5FiniteRecipePatch.sameBanks(inputs.banks,inputs.banks) else { throw CameraServiceError.sourceChanged }
            _ = try frozen.settings(using: RecipeCodecRegistry())
            let camera=try makeService(root.appendingPathComponent("operations"));service=camera
            evidence.stage="connecting verified production service";try save(evidence,to:documents)
            try await camera.connect()
            var results:[CameraJPEG]=[],before:[RecipeSnapshot]=[]
            for (index,raw) in [inputs.a,inputs.b,inputs.a].enumerated() {
                evidence.stage="rendering \(index == 1 ? "B" : "A") through production API";try save(evidence,to:documents)
                let result=try await camera.render(raw:raw,recipe:frozen,policy:.fullSizeFineRecordedGeometry)
                results.append(result)
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(results).write(to:run.appendingPathComponent("results.json"),options:[.atomic,.completeFileProtection])
                evidence.model=result.cameraContext.model;evidence.firmware=result.cameraContext.firmware;evidence.capability=result.cameraContext.capability
                evidence.trials.append(.init(source:index == 1 ? "B" : "A",width:result.width,height:result.height,orientation:result.orientation,
                    bytes:try result.fileURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0,fullResolutionFine:result.quality == .fullResolutionFine,
                    lensOptimizerRequested:result.effectiveRecipe.lensOptimizerRequested,lensOptimizerEffective:result.effectiveRecipe.lensOptimizerEffective,
                    lensOptimizerAdjusted:result.effectiveRecipe.lensOptimizerAdjusted,outputCleanupConfirmed:true))
                evidence.trialCount=results.count;try save(evidence,to:documents)
                guard result.recipeSnapshotID == frozen.id,result.sourceSHA256 == raw.sha256,
                      result.effectiveRecipe.lensOptimizerRequested,result.effectiveRecipe.lensOptimizerEffective else { throw CameraServiceError.invalidOutput }
                if index == 0 {
                    // M uploaded a RAW without producing an output. First A cleanup precedes selectors.
                    before=try await camera.importRecipes().recipes
                    try encoder.encode(before).write(to:run.appendingPathComponent("banks-before.json"),options:[.atomic,.completeFileProtection])
                }
            }
            let after=try await camera.importRecipes().recipes
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(after).write(to:run.appendingPathComponent("banks-after.json"),options:[.atomic,.completeFileProtection])
            evidence.banksPreserved=XT5FiniteRecipePatch.sameBanks(before,after)
            evidence.sameFrozenSnapshot=results.allSatisfy { $0.recipeSnapshotID == frozen.id && $0.settingsDigest == frozen.settingsDigest }
            evidence.sameAKey=results[0].key == results[2].key
            evidence.differentBKey=results[0].key != results[1].key
            guard evidence.banksPreserved,evidence.sameFrozenSnapshot,evidence.sameAKey,evidence.differentBKey,
                  Set(results.map(\.operationID)).count == 3,Set(results.map(\.fileURL)).count == 3 else { throw CameraServiceError.ownershipChanged }
            evidence.stage="awaiting native close";try save(evidence,to:documents)
        } catch { evidence.failure=FujiCameraService.safeFailure(FujiCameraService.failure(error)) }
        if let service {
            await service.disconnect()
            var stream=await service.states().makeAsyncIterator()
            if case .disconnected = await stream.next() { evidence.nativeClosure="confirmed" }
            else { evidence.nativeClosure="unconfirmed";evidence.failure=evidence.failure ?? "native close unconfirmed" }
        }
        evidence.complete=evidence.failure == nil && evidence.trialCount == 3 && evidence.nativeClosure == "confirmed" && evidence.banksPreserved
        evidence.stage=evidence.complete ? "A-B-A runtime validation complete; offline reference comparison pending" : "stopped; no automatic retry"
        if let output { do { try save(evidence,to:output) } catch { status="Production acceptance evidence write failed" } }
    }
    private func save(_ evidence:XT5ProductionAcceptanceEvidence,to output:URL) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(evidence).write(to:output.appendingPathComponent("xt5-production-acceptance-evidence.json"),options:.atomic)
        status="\(evidence.stage); trials \(evidence.trialCount)/3; close \(evidence.nativeClosure); \(evidence.failure ?? "no reported error")"
        try "\(Date().formatted(.iso8601))\n\(status)\nPrivate journals and output files: xt5-production-acceptance-private. No Photos writes.\n".write(to:output.appendingPathComponent("xt5-production-acceptance-status.txt"),atomically:true,encoding:.utf8)
        let diagnostics=native.lifecycleDiagnosticMessages().joined(separator:"\n")+"\n"+native.ptpDiagnosticMessages().joined(separator:"\n")
        try diagnostics.write(to:output.appendingPathComponent("camera-diagnostics.txt"),atomically:true,encoding:.utf8)
    }
}
#endif
