#if DEBUG
import Foundation

struct RetainedRecipeBatchInputs: Sendable {
    let banks: [RecipeSnapshot]
    let target: XT5ExactCleanupTarget
    private struct BankCapture: Decodable { let complete:Bool;let snapshots:[RecipeSnapshot];let verificationSnapshots:[RecipeSnapshot] }
    private struct SourceReference: Decodable { let retainedRun:String,filename:String,sha256:String }
    static func prepare(documents:URL,raw:PreparedRAW,reference:XT5FilmProbeReference,destination:URL) async throws -> Self {
        let task=Task.detached { () throws -> Self in
            try reference.validate(raw:raw)
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            let bankData=try XT5CreatedOutputProof.bounded("xt5-bank-import-private.json",directory:documents,maximum:1_048_576)
            let capture=try decoder.decode(BankCapture.self,from:bankData)
            guard capture.complete,XT5FiniteRecipePatch.sameBanks(capture.snapshots,capture.verificationSnapshots) else { throw XT5RecipeBatchIssue.invalidReference }
            for bank in capture.snapshots { _ = try XT5FiniteRecipePatch.make(bank:bank,referenceBanks:capture.snapshots,reference:reference) }
            let root=documents.appendingPathComponent("xt5-film-only-private",isDirectory:true)
            let entries=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey])
            let runs=entries.filter { UUID(uuidString:$0.lastPathComponent) != nil && FileManager.default.fileExists(atPath:$0.appendingPathComponent("quarantined-candidate.bin").path) }
            guard runs.count == 1,let run=runs.first else { throw XT5RecipeBatchIssue.invalidReference }
            let source=try decoder.decode(SourceReference.self,from:XT5CreatedOutputProof.bounded("source-reference.json",directory:run,maximum:65_536))
            guard source.sha256 == raw.sha256,source.filename == "source.RAF",source.retainedRun == raw.fileURL.deletingLastPathComponent().lastPathComponent else { throw XT5RecipeBatchIssue.invalidReference }
            for name in ["baseline.bin","profile-echo.bin","profile-echo-readback.bin"] {
                guard try XT5CreatedOutputProof.bounded(name,directory:run,maximum:625) == reference.baseline else { throw XT5RecipeBatchIssue.invalidReference }
            }
            var film=reference.baseline;film.replaceSubrange(541..<545,with:Data([11,0,0,0]))
            for name in ["profile-film-patch.bin","profile-film-readback.bin"] {
                guard try XT5CreatedOutputProof.bounded(name,directory:run,maximum:625) == film else { throw XT5RecipeBatchIssue.invalidReference }
            }
            let target=try XT5CreatedOutputProof.load(directory:run,raw:raw)
            try Task.checkCancellation()
            try bankData.write(to:destination.appendingPathComponent("retained-bank-reference.json"),options:[.atomic,.completeFileProtection])
            let binding=["sourceSHA256":raw.sha256,"phaseJRun":run.lastPathComponent,"outputSHA256":target.outputSHA256,"referenceBanks":"retained-bank-reference.json"]
            try JSONEncoder().encode(binding).write(to:destination.appendingPathComponent("batch-source-reference.json"),options:[.atomic,.completeFileProtection])
            return Self(banks:capture.snapshots,target:target)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
#endif
