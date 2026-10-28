import FujiCameraCore
#if DEBUG
import Foundation
import Observation

enum RAWBaselinePreparationIssue: Error, Sendable { case noCompatibleRAW }

/// Diagnostic selection only. Existing Photos access is required; no grant request or library write.
struct RAWBaselineSourcePreparer: Sendable {
    struct Selection: Sendable { let source: PhotoSource; let raw: PreparedRAW; var candidatesExamined = 0 }
    private let reader: any PhotoLibraryReading
    private let maximumCandidates: Int
    private let prepare: @Sendable (LocalResource) throws -> PreparedRAW
    init(reader: any PhotoLibraryReading, maximumCandidates: Int = 8,
         prepare: @escaping @Sendable (LocalResource) throws -> PreparedRAW = { try RAFMetadataReader().prepare($0) }) {
        self.reader = reader; self.maximumCandidates = maximumCandidates; self.prepare = prepare
    }
    func prepareOne(in directory: URL) async throws -> Selection {
        var fallback: PhotoSource?
        var attempted = 0
        search: for try await batch in await reader.sources() {
            for source in batch {
                guard attempted < maximumCandidates else { break search }
                attempted += 1
                let result = try await candidate(source, directory: directory, requireReference: true)
                if let selected = result.selected { return selected }
                if result.compatible && fallback == nil { fallback = source }
            }
        }
        // Keep only descriptors while searching, so a fallback needs one fresh materialization.
        if let fallback, let selected = try await candidate(fallback, directory: directory, requireReference: false).selected { return selected }
        throw RAWBaselinePreparationIssue.noCompatibleRAW
    }
    /// Phase-M evidence: pairs only, no reference-aspect preference or standalone fallback.
    func preparePaired(in directory: URL) async throws -> Selection {
        var attempted = 0
        for try await batch in await reader.sources() {
            try Task.checkCancellation()
            for source in batch where source.originalResources.jpeg != nil {
                try Task.checkCancellation()
                guard attempted < min(8, maximumCandidates) else { throw RAWBaselinePreparationIssue.noCompatibleRAW }
                try Self.validatePair(source)
                attempted += 1
                if var selected = try await candidate(source, directory: directory, requireReference: false, requirePair: true).selected {
                    selected.candidatesExamined = attempted
                    return selected
                }
            }
        }
        try Task.checkCancellation()
        throw RAWBaselinePreparationIssue.noCompatibleRAW
    }
    private static func validatePair(_ source: PhotoSource) throws {
        guard let jpeg = source.originalResources.jpeg,
              source.originalResources.raf.assetID == source.id, jpeg.assetID == source.id,
              source.originalResources.raf.sourceRevision == source.resourceRevision,
              jpeg.sourceRevision == source.resourceRevision,
              try RawResourceSelector.select([jpeg, source.originalResources.raf]) == source.originalResources else {
            throw ResourceError.resourceChanged
        }
    }
    private func candidate(_ source: PhotoSource, directory: URL, requireReference: Bool, requirePair: Bool = false) async throws -> (selected: Selection?, compatible: Bool) {
        try Task.checkCancellation()
        let local = try await reader.materialize(source.originalResources.raf, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        try Task.checkCancellation()
        if requirePair && local.token != source.originalResources.raf { throw ResourceError.resourceChanged }
        let parse = Task.detached { try prepare(local) }
        let raw: PreparedRAW
        do {
            raw = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
        } catch ResourceError.incompatibleCamera { try Task.checkCancellation(); return (nil, false) }
          catch ResourceError.invalidRAF { try Task.checkCancellation(); return (nil, false) }
        try Task.checkCancellation()
        if requirePair {
            guard raw.fileURL == local.fileURL, raw.sourceID == source.id,
                  raw.sourceRevision == source.resourceRevision, raw.sha256 == local.checksum else { throw ResourceError.resourceChanged }
            let current = try await reader.source(id: source.id)
            try Self.validatePair(current)
            guard current.id == source.id, current.resourceRevision == source.resourceRevision,
                  current.originalResources == source.originalResources else { throw ResourceError.resourceChanged }
            try Task.checkCancellation()
        }
        guard raw.metadata.cameraModel == "X-T5" else { return (nil, false) }

        if requireReference && raw.metadata.recordedGeometry != PixelSize(width: 7728, height: 5152) { return (nil, true) }
        let destination = directory.appendingPathComponent("source.RAF")
        let manifestURL = directory.appendingPathComponent("source-manifest.json")
        // Never replace prior retained evidence. Roll back only files this attempt creates.
        guard !FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.fileExists(atPath: manifestURL.path) else { throw ResourceError.resourceChanged }
        var moved = false, complete = false
        defer {
            if moved && !complete {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: manifestURL)
            }
        }
        try FileManager.default.moveItem(at: local.fileURL, to: destination)
        moved = true

        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        let selected = PreparedRAW(fileURL: destination, sha256: raw.sha256, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, metadata: raw.metadata)
        let manifest = SourceManifest(source: source, raw: selected)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("source-manifest.json"), options: [.atomic, .completeFileProtection])
        try Task.checkCancellation()
        complete = true
        var confirmedSource = source
        if requirePair { confirmedSource.compatibility = .xt5 }
        return (Selection(source: confirmedSource, raw: selected), true)
    }
    private struct SourceManifest: Encodable {
        let sourceID: String, sourceRevision: String, originalFilename: String, resourceRole: String, sha256: String
        let captureDate: Date?
        let pairedJPEGAvailable: Bool
        let jpegSourceID: String?, jpegSourceRevision: String?, jpegResourceRole: String?, jpegOriginalFilename: String?, jpegDiscriminator: String?
        let rafDiscriminator: String
        let compatibility = "xt5"
        let cameraModel: String
        let containerWidth: Int, containerHeight: Int, recordedWidth: Int, recordedHeight: Int
        let aspectWidth: Int, aspectHeight: Int, cropTop: Int, cropLeft: Int, orientation: Int
        init(source: PhotoSource, raw: PreparedRAW) {
            sourceID = raw.sourceID; sourceRevision = raw.sourceRevision; originalFilename = source.originalResources.raf.originalFilename
            resourceRole = source.originalResources.raf.role.rawValue; sha256 = raw.sha256; captureDate = source.captureDate
            pairedJPEGAvailable = source.originalResources.jpeg != nil
            let jpeg = source.originalResources.jpeg
            jpegSourceID = jpeg?.assetID; jpegSourceRevision = jpeg?.sourceRevision; jpegResourceRole = jpeg?.role.rawValue
            jpegOriginalFilename = jpeg?.originalFilename; jpegDiscriminator = jpeg?.discriminator
            rafDiscriminator = source.originalResources.raf.discriminator
            let m = raw.metadata; cameraModel = m.cameraModel; containerWidth = m.containerGeometry.width; containerHeight = m.containerGeometry.height
            recordedWidth = m.recordedGeometry.width; recordedHeight = m.recordedGeometry.height; aspectWidth = m.recordedAspect.width; aspectHeight = m.recordedAspect.height
            cropTop = m.cropTop; cropLeft = m.cropLeft; orientation = m.orientation
        }
    }
}

/// Owns the lifecycle for one explicit diagnostic. No concurrent manual reconnect can use it.
@MainActor @Observable
final class XT5RawBaselineLaunchRunner {
    var status = "RAW baseline probe has not run"
    private let transport: ImageCaptureTransport
    private let requestedDirectory: URL?
    private let preparer: RAWBaselineSourcePreparer
    private let retainedSource: @Sendable (URL, URL) async throws -> PreparedRAW
    private var prefix = "xt5-raw-baseline"
    private var directory: URL?
    private var didRun = false
    private var artifactWriteFailed = false
    init(transport: ImageCaptureTransport = ImageCaptureTransport(), directory: URL? = nil,
         preparer: RAWBaselineSourcePreparer = RAWBaselineSourcePreparer(reader: PhotoLibraryReader()),
         retainedSource: @escaping @Sendable (URL, URL) async throws -> PreparedRAW = { try await RetainedRAWProbeSource.prepare(documents: $0,destination: $1) }) {
        self.transport = transport; requestedDirectory = directory; self.preparer = preparer
        self.retainedSource = retainedSource
    }
    func runIfRequested(arguments: [String]) async {
        let otherFlags = ["--xt5-read-only-probe", "--xt5-direct-values-probe", "--camera-reconnect-probe", "--xt5-bank-import-probe", "--xt5-production-acceptance-probe"]
        let baseline = arguments.contains("--xt5-raw-baseline-probe")
        let paired = arguments.contains("--xt5-paired-baseline-probe")
        let unchanged = arguments.contains("--xt5-unchanged-baseline-probe")
        let recovery = arguments.contains("--xt5-output-recovery-probe")
        let quarantine = arguments.contains("--xt5-output-quarantine-probe")
        let triggerOne = arguments.contains("--xt5-trigger-one-probe")
        let film = arguments.contains("--xt5-film-only-probe")
        let batch = arguments.contains("--xt5-recipe-batch-probe")
        let readOnly = recovery || quarantine
        guard [baseline,paired,unchanged,recovery,quarantine,triggerOne,film,batch].filter({ $0 }).count == 1, !otherFlags.contains(where: arguments.contains), !didRun else { return }
        didRun = true
        if paired { prefix = "xt5-paired-baseline" }
        if unchanged { prefix = "xt5-unchanged-baseline" }
        if recovery { prefix = "xt5-output-recovery" }
        if quarantine { prefix = "xt5-output-quarantine" }
        if triggerOne { prefix = "xt5-trigger-one" }
        if film { prefix = "xt5-film-only" }
        if batch { prefix = "xt5-recipe-batch" }
        var probeOwnsClose = false
        do {
            let output = try requestedDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let privateRun = output.appendingPathComponent(prefix + "-private", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: privateRun, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            directory = output
            try Data("{\"state\":\"preparing original\"}".utf8).write(to: output.appendingPathComponent(prefix + "-evidence.json"), options: .atomic)
            if paired { try Data("{\"state\":\"preparing\"}".utf8).write(to: output.appendingPathComponent(prefix + "-source-evidence.json"), options: .atomic) }
            saveLifecycle()
            try writeStatus(readOnly ? "Verifying retained original for read-only existing-output observation" : !baseline && !paired ? "Verifying retained original and required private diagnostic proof" : "Preparing one original using existing Photos access")
            let raw: PreparedRAW
            if paired {
                let selection = try await preparer.preparePaired(in: privateRun)
                raw = selection.raw
                let sourceEvidence: [String: Any] = ["pairedOriginals": true,
                    "pairedCandidatesExamined": selection.candidatesExamined, "maximumPairedCandidates": 8,
                    "width": raw.metadata.recordedGeometry.width, "height": raw.metadata.recordedGeometry.height,
                    "orientation": raw.metadata.orientation, "compatibility": "X-T5", "originalJPEGDownloaded": false]
                try JSONSerialization.data(withJSONObject: sourceEvidence, options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent(prefix + "-source-evidence.json"), options: .atomic)
            } else if !baseline { raw = try await retainedSource(output, privateRun) }

            else { raw = try await preparer.prepareOne(in: privateRun).raw }
            let cleanupTarget = triggerOne ? try await RetainedExactCleanupProof.prepare(documents: output, raw: raw, destination: privateRun) : nil
            let filmReference = (film || batch) ? try await RetainedFilmProbeReference.prepare(raw: raw, destination: privateRun) : nil
            let batchInputs = batch ? try await RetainedRecipeBatchInputs.prepare(documents: output, raw: raw, reference: filmReference!, destination: privateRun) : nil
            try writeStatus(readOnly ? "Connecting for read-only output observation; no upload or trigger" : "Original retained privately; connecting for bounded RAW upload")
            try await transport.connect()
            let native = transport
            let generation = try native.currentSession().generation
            let probe = XT5RawBaselineProbe(transport: native, validateSession: {
                guard try await native.currentSession().generation == generation else { throw XT5BankImportIssue.sessionChanged }
            }, closeSession: {
                // MainActor keeps identity validation and close initiation together. There is no
                // independent connect path on this privately owned transport during the operation.
                try await Self.close(native, expectedGeneration: generation)
            }, experiment: unchanged ? .unchangedTrigger0 : .baselineOnly)
            probeOwnsClose = true
            if let batchInputs, let filmReference {
                let batchProbe = XT5RecipeBatchProbe(transport: native, sessionGeneration: generation, validateSession: {
                    guard try await native.currentSession().generation == generation else { throw XT5BankImportIssue.sessionChanged }
                }, closeSession: { try await Self.close(native, expectedGeneration: generation) })
                _ = try await batchProbe.run(raw: raw, reference: filmReference, referenceBanks: batchInputs.banks, initialTarget: batchInputs.target, directory: privateRun) { [weak self] report in await self?.saveBatch(report) }
            } else if let filmReference {
                _ = try await probe.captureFilmOnly(raw: raw, reference: filmReference, directory: privateRun) { [weak self] report in await self?.save(report) }
            } else if let cleanupTarget {
                _ = try await probe.captureTriggerOne(after: cleanupTarget, raw: raw, directory: privateRun) { [weak self] report in await self?.save(report) }
            } else if readOnly {
                _ = try await probe.recoverExistingOutput(raw: raw, directory: privateRun, quarantine: quarantine) { [weak self] report in await self?.save(report) }
            } else {
                _ = try await probe.capture(raw: raw, directory: privateRun) { [weak self] report in await self?.save(report) }
            }
            let success = batch ? "Seven experimental candidates captured and owned outputs cleaned; banks unchanged and selector restored; native close confirmed; fidelity/FINE/dormant grain size remain offline gates" : film ? "Echo and film-only readbacks matched; trigger 1 diagnostic captured; native close confirmed; recipe fidelity, FINE and cleanup remain unvalidated" : triggerOne ? "Exact old output deletion verified; trigger 1 private diagnostic captured; native close confirmed; new output/input cleanup unconfirmed; FINE and recipes unvalidated" : quarantine ? "Private quarantine captured; never promoted to validated output; native session closed; provenance and cleanup unconfirmed" : recovery ? "Existing candidate retained; native session closed; provenance and cleanup unconfirmed; no upload or trigger performed" : unchanged ? "Unchanged-baseline JPEG retained; native session closed; input/output cleanup unconfirmed; FINE and imported recipes unvalidated" : "Baseline probe complete; native session closed; upload buffer cleanup remains unconfirmed; conversion unvalidated"
            try writeStatus(artifactWriteFailed ? "Probe operation finished, but public evidence writing failed" : success)
        } catch let failure as XT5RecipeBatchFailure {
            try? writeStatus("Recipe batch stopped: \(failure.evidence.failure ?? "incomplete"); native closure \(failure.evidence.sessionClosure); input buffer cleanup unconfirmed")
        } catch let failure as XT5RawBaselineFailure {
            try? writeStatus("Baseline probe incomplete: \(failure.evidence.failure ?? failure.evidence.sessionClosureFailure ?? "unknown outcome"); native closure \(failure.evidence.sessionClosure); buffer cleanup unconfirmed")
        } catch {
            let message: String
            if error is RAWBaselinePreparationIssue {
                message = paired ? "no compatible paired RAW found within diagnostic search limit" : "no compatible RAW found within diagnostic search limit"
            } else if let resource = error as? ResourceError, resource == .resourceChanged {
                message = "source asset, revision or original resource changed"
            } else { message = XT5RawBaselineProbe.safeFailure(error) }

            status = "Baseline probe failed: \(message)"; try? writeStatus(status)
        }
        if !probeOwnsClose {
            // Includes a failed connect. Await native termination rather than treating disconnect
            // initiation as proof. An uncancelled task cannot skip this on parent cancellation.
            let native = transport
            let close = Task { @MainActor in try await native.disconnectAndWaitForConfirmation() }
            do { try await close.value }
            catch { try? writeStatus("Baseline probe incomplete; native closure unconfirmed: \(XT5RawBaselineProbe.safeFailure(error))") }
        }
        saveLifecycle()
    }
    private static func close(_ native: ImageCaptureTransport, expectedGeneration: UInt64) async throws {
        if let current = try? native.currentSession(), current.generation != expectedGeneration { throw XT5BankImportIssue.sessionChanged }
        try await native.disconnectAndWaitForConfirmation()
    }
    private func saveBatch(_ report: XT5RecipeBatchEvidence) {
        guard let directory else { return }
        do {
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(report).write(to:directory.appendingPathComponent(prefix + "-evidence.json"),options:.atomic)
            let last=report.slots.last
            try writeStatus("Experimental slots started: \(report.slots.count)/7; current C\(last?.slot ?? 0); profile readback \(last?.capture?.batchProfileReadbackMatches ?? false); capture \(last?.capture?.batchTrialCaptured ?? false); cleanup empty \(last?.cleanup?.emptyViewVerified ?? false); banks before/after \(report.beforeBanksMatch)/\(report.afterBanksMatch); native closure \(report.sessionClosure); fidelity unvalidated")
        } catch { artifactWriteFailed=true;status="Recipe batch public evidence write failed" }
        saveLifecycle()
    }
    private func save(_ report: XT5RawBaselineEvidence) {
        guard let directory else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: directory.appendingPathComponent(prefix + "-evidence.json"), options: .atomic)
            if let film = report.filmProbe {
                try writeStatus("Baseline match: \(film.baselineMatchesReference); echo accepted/readback: \(film.echoAccepted)/\(film.echoReadbackMatches); film patch accepted/readback: \(film.patchAccepted)/\(film.patchReadbackMatches); trigger accepted: \(report.unchangedConversion?.triggerAccepted ?? false); capture: \(report.unchangedConversion?.captureOutcome ?? "notCaptured"); native closure: \(report.sessionClosure); diagnostic only, cleanup unconfirmed")
            } else if let cleanup = report.exactCleanup {
                try writeStatus("Exact old output delete acknowledged: \(cleanup.deleteAcknowledged); empty view verified: \(cleanup.emptyViewVerified); trigger 1 accepted: \(report.unchangedConversion?.triggerAccepted ?? false); capture: \(report.unchangedConversion?.captureOutcome ?? "notCaptured"); native closure: \(report.sessionClosure); new output/input cleanup unconfirmed")
            } else if report.readOnlyRecovery {
                try writeStatus("Read-only observation: \(report.unchangedConversion?.captureOutcome ?? "notCaptured"); native closure: \(report.sessionClosure); provenance and cleanup unconfirmed")
            } else {
                try writeStatus("RAW upload accepted: \(report.rawUploadSucceeded); baseline bytes: \(report.baselineBytes ?? 0); native closure: \(report.sessionClosure); buffer cleanup unconfirmed")
            }
        } catch { artifactWriteFailed = true; status = "Evidence file write failed; native closure must still finish" }
        saveLifecycle()
    }
    private func writeStatus(_ message: String) throws {
        status = message
        guard let directory else { return }
        try "\(Date().formatted(.iso8601))\n\(message)\nPrivate source/profile/context under \(prefix)-private; never publish these files.\n"
            .write(to: directory.appendingPathComponent(prefix + "-status.txt"), atomically: true, encoding: .utf8)
    }
    private func saveLifecycle() {
        guard let directory else { return }
        let text = "Public lifecycle:\n" + transport.lifecycleDiagnosticMessages().joined(separator: "\n")
            + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}
#endif

#if DEBUG
/// Reuses exactly one retained phase-D original. No Photos fallback and no most-recent guessing.
enum RetainedRAWProbeSource {
    private struct Manifest: Decodable {
        let sourceID: String, sourceRevision: String, originalFilename: String, resourceRole: String, sha256: String
    }
    static func prepare(documents: URL, destination: URL) async throws -> PreparedRAW {
        let task = Task.detached { try load(documents: documents, destination: destination) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func load(documents: URL, destination: URL) throws -> PreparedRAW {
        let root = documents.appendingPathComponent("xt5-raw-baseline-private",isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root,includingPropertiesForKeys: [.isDirectoryKey]) else { throw XT5ConversionProbeIssue.retainedSourceUnavailable }
        let candidates = entries.filter {
            UUID(uuidString: $0.lastPathComponent) != nil &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.RAF").path) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("source-manifest.json").path)
        }
        guard candidates.count == 1, let run = candidates.first else { throw XT5ConversionProbeIssue.retainedSourceUnavailable }
        let data = try Data(contentsOf: run.appendingPathComponent("source-manifest.json"))
        guard data.count <= 65_536 else { throw XT5ProtocolError.oversized }
        let manifest = try JSONDecoder().decode(Manifest.self,from: data)
        guard let role = ResourceRole(rawValue: manifest.resourceRole), role != .adjusted else { throw XT5ConversionProbeIssue.retainedSourceUnavailable }
        let token = ResourceToken(assetID: manifest.sourceID,role: role,contentTypeIdentifier: "com.fuji.raw-image",format: .raf,
                                  originalFilename: manifest.originalFilename,discriminator: "retained-original",sourceRevision: manifest.sourceRevision)
        let local = LocalResource(token: token,fileURL: run.appendingPathComponent("source.RAF"),checksum: manifest.sha256)
        try Task.checkCancellation()
        let raw = try RAFMetadataReader().prepare(local)
        try Task.checkCancellation()
        try data.write(to: destination.appendingPathComponent("source-manifest.json"),options: [.atomic,.completeFileProtection])
        let reference = ["retainedRun": run.lastPathComponent,"filename": "source.RAF","sha256": raw.sha256]
        try JSONEncoder().encode(reference).write(to: destination.appendingPathComponent("source-reference.json"),options: [.atomic,.completeFileProtection])
        return raw
    }
}
#endif

#if DEBUG
/// Loads exactly the existing phase-G quarantine proof; no latest-run or Photos fallback.
enum RetainedExactCleanupProof {
    private struct Manifest: Decodable {
        let sourceSHA256: String, outputSHA256: String
        let candidateHandle: UInt32
        let readOnlyRecovery: Bool, privateQuarantine: Bool
    }
    private struct Reference: Decodable { let retainedRun: String, filename: String, sha256: String }
    static func prepare(documents: URL, raw: PreparedRAW, destination: URL) async throws -> XT5ExactCleanupTarget {
        let task = Task.detached { try load(documents: documents, raw: raw, destination: destination) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func load(documents: URL, raw: PreparedRAW, destination: URL) throws -> XT5ExactCleanupTarget {
        let root = documents.appendingPathComponent("xt5-output-quarantine-private", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let candidates = entries.filter {
            UUID(uuidString: $0.lastPathComponent) != nil && FileManager.default.fileExists(atPath: $0.appendingPathComponent("quarantined-candidate.bin").path)
        }
        guard candidates.count == 1, let run = candidates.first else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        func bounded(_ name: String, maximum: Int) throws -> Data {
            let url = run.appendingPathComponent(name)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maximum else { throw XT5ExactCleanupIssue.invalidPreservedProof }
            return try Data(contentsOf: url)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: bounded("conversion-manifest.json", maximum: 65_536))
        let reference = try JSONDecoder().decode(Reference.self, from: bounded("source-reference.json", maximum: 65_536))
        guard manifest.readOnlyRecovery, manifest.privateQuarantine, manifest.sourceSHA256 == raw.sha256,
              reference.sha256 == raw.sha256, reference.filename == "source.RAF",
              reference.retainedRun == raw.fileURL.deletingLastPathComponent().lastPathComponent else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let object = try bounded("output-object-info.bin", maximum: 4096)
        guard try bounded("output-object-info-after.bin", maximum: 4096) == object else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let target = XT5ExactCleanupTarget(handle: manifest.candidateHandle, sourceSHA256: manifest.sourceSHA256, outputSHA256: manifest.outputSHA256,
            quarantineURL: run.appendingPathComponent("quarantined-candidate.bin"), objectInfo: object, storageInfo: try bounded("output-storage-info.bin", maximum: 4096))
        try Task.checkCancellation()
        _ = try target.validateLocal(raw: raw)
        let link = ["preservedRun":run.lastPathComponent, "sourceSHA256":raw.sha256, "outputSHA256":manifest.outputSHA256]
        try JSONEncoder().encode(link).write(to: destination.appendingPathComponent("cleanup-source-reference.json"), options: [.atomic,.completeFileProtection])
        return target
    }
}
#endif

#if DEBUG
/// Phase-D baseline must be bound to the exact already parsed retained original, not a latest file.
enum RetainedFilmProbeReference {
    private struct Manifest: Decodable { let sourceSHA256: String }
    static func prepare(raw: PreparedRAW, destination: URL) async throws -> XT5FilmProbeReference {
        let task = Task.detached { () throws -> XT5FilmProbeReference in
            let run = raw.fileURL.deletingLastPathComponent()
            let url = run.appendingPathComponent("baseline.bin")
            let manifestURL = run.appendingPathComponent("protocol-manifest.json")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 625,
                  let manifestSize = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  manifestSize > 0 && manifestSize <= 65_536 else { throw XT5FilmProbeIssue.invalidReference }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            let reference = XT5FilmProbeReference(sourceSHA256: manifest.sourceSHA256, baseline: try Data(contentsOf: url))
            try reference.validate(raw: raw)
            guard try ResourceChecksum.sha256(raw.fileURL) == reference.sourceSHA256 else { throw XT5FilmProbeIssue.invalidReference }
            try Task.checkCancellation()
            try reference.baseline.write(to: destination.appendingPathComponent("reference-baseline.bin"), options: [.atomic,.completeFileProtection])
            return reference
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
#endif
