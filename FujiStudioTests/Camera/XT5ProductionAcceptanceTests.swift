@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

@MainActor struct XT5ProductionAcceptanceTests {
    @Test func explicitProbeUsesRealServiceForABAAndKeepsFrozenSnapshot() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let inputs=try inputs(f),wire=ProductionSession(fixture:f)
        let output=f.directory.appendingPathComponent("documents")
        let runner=XT5ProductionAcceptanceRunner(directory:output,prepare:{ _,_ in inputs },makeService:{ root in
            FujiCameraService(session:wire,journal:try CameraOperationJournal(directory:root, filePolicy: IOSCameraJournalFilePolicy()),pollWait:{},settle:{ _ in },registry:FujiCameraRegistry(adapters:[XT5Adapter(validateJPEG:{ _,m in Self.validated(m,lmo:true) })]))
        })
        await runner.runIfRequested(arguments:["--xt5-production-acceptance-probe"])
        let report=try evidence(output)
        #expect(report["complete"] as? Bool == true)
        #expect(report["trialCount"] as? Int == 3)
        #expect(report["nativeClosure"] as? String == "confirmed")
        #expect(report["banksPreserved"] as? Bool == true)
        #expect(report["sameFrozenSnapshot"] as? Bool == true)
        #expect(report["sameAKey"] as? Bool == true && report["differentBKey"] as? Bool == true)
        #expect(await wire.uploadHashes == [inputs.a.sha256,inputs.b.sha256,inputs.a.sha256])
        #expect(await wire.triggers == 3);#expect(await wire.deletes == [77,77,77]);#expect(await wire.closes == 1)
        #expect(!String(decoding:try Data(contentsOf:output.appendingPathComponent("xt5-production-acceptance-evidence.json")),as:UTF8.self).contains(inputs.a.sha256))
    }
    @Test func adjustedLMOIsRecordedBeforeStrictProbeStopsWithoutMoreTrials() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let inputs=try inputs(f),wire=ProductionSession(fixture:f),output=f.directory.appendingPathComponent("documents")
        let runner=XT5ProductionAcceptanceRunner(directory:output,prepare:{ _,_ in inputs },makeService:{ root in
            FujiCameraService(session:wire,journal:try CameraOperationJournal(directory:root, filePolicy: IOSCameraJournalFilePolicy()),pollWait:{},settle:{ _ in },registry:FujiCameraRegistry(adapters:[XT5Adapter(validateJPEG:{ _,m in Self.validated(m,lmo:false) })]))
        })
        await runner.runIfRequested(arguments:["--xt5-production-acceptance-probe"])
        let report=try evidence(output)
        #expect(report["complete"] as? Bool == false && report["trialCount"] as? Int == 1)
        let trials = try #require(report["trials"] as? [[String: Any]])
        let trial = try #require(trials.first)
        #expect(trial["lensOptimizerRequested"] as? Bool == true)
        #expect(trial["lensOptimizerEffective"] as? Bool == false)
        #expect(trial["lensOptimizerAdjusted"] as? Bool == true)
        #expect(trial["outputCleanupConfirmed"] as? Bool == true)
        #expect(await wire.triggers == 1);#expect(await wire.closes == 1)
        #expect(await wire.commands.allSatisfy { $0.parameters != [0xD18C] })
    }
    @Test func ordinaryConflictingAndFailedPreparationNeverCreateService() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let inputs=try inputs(f),wire=ProductionSession(fixture:f)
        for flag in [nil,"--xt5-raw-baseline-probe","--xt5-paired-baseline-probe","--xt5-bank-import-probe","--camera-reconnect-probe","--xt5-read-only-probe","--xt5-direct-values-probe","--xt5-recipe-batch-probe","--xt5-unchanged-baseline-probe","--xt5-output-recovery-probe","--xt5-output-quarantine-probe","--xt5-trigger-one-probe","--xt5-film-only-probe"] as [String?] {
            var made=false
            let output=f.directory.appendingPathComponent(UUID().uuidString)
            let runner=XT5ProductionAcceptanceRunner(directory:output,prepare:{ _,_ in inputs },makeService:{ root in made=true;return FujiCameraService(session:wire,journal:try CameraOperationJournal(directory:root, filePolicy: IOSCameraJournalFilePolicy())) })
            await runner.runIfRequested(arguments:flag.map { ["--xt5-production-acceptance-probe",$0] } ?? ["FujiStudio"])
            #expect(!made && !FileManager.default.fileExists(atPath:output.path))
        }
        var made=false
        let runner=XT5ProductionAcceptanceRunner(directory:f.directory.appendingPathComponent("failed"),prepare:{ _,_ in throw CameraServiceError.sourceChanged },makeService:{ root in made=true;return FujiCameraService(session:wire,journal:try CameraOperationJournal(directory:root, filePolicy: IOSCameraJournalFilePolicy())) })
        await runner.runIfRequested(arguments:["--xt5-production-acceptance-probe"])
        #expect(!made)
    }
    private func inputs(_ f:ProductionOperationFixture) throws -> XT5ProductionAcceptanceInputs {
        let bURL=f.directory.appendingPathComponent("second.RAF");try Data(repeating:43,count:256).write(to:bURL)
        let b=PreparedRAW(fileURL:bURL,sha256:try ResourceChecksum.sha256(bURL),sourceID:"second-source",sourceRevision:"v1",metadata:f.profile.metadata)
        let banks=try (1...7).map { $0 == 7 ? f.profile.bank : try BatchFixture().bank(slot:$0,properties:f.profile.properties) }
        return .init(a:f.raw,b:b,banks:banks)
    }
    private func evidence(_ directory:URL) throws -> [String:Any] { try #require(JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("xt5-production-acceptance-evidence.json"))) as? [String:Any]) }
    nonisolated private static func validated(_ m:RAWMetadata,lmo:Bool)->ValidatedJPEGMetadata { .init(width:m.recordedGeometry.width,height:m.recordedGeometry.height,orientation:m.orientation,make:"FUJIFILM",model:"X-T5",quality:.fine,lensOptimizer:lmo) }
}
