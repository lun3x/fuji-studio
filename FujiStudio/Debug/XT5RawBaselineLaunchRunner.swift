#if DEBUG
import Foundation
import Observation

enum RAWBaselinePreparationIssue: Error, Sendable { case noCompatibleRAW }

/// Diagnostic selection only. Existing Photos access is required; no grant request or library write.
struct RAWBaselineSourcePreparer: Sendable {
    struct Selection: Sendable { let source: PhotoSource; let raw: PreparedRAW }
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
    private func candidate(_ source: PhotoSource, directory: URL, requireReference: Bool) async throws -> (selected: Selection?, compatible: Bool) {
        try Task.checkCancellation()
        let local = try await reader.materialize(source.originalResources.raf, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        let parse = Task.detached { try prepare(local) }
        let raw: PreparedRAW
        do {
            raw = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
        } catch ResourceError.incompatibleCamera { return (nil, false) }
          catch ResourceError.invalidRAF { return (nil, false) }
        try Task.checkCancellation()
        guard raw.metadata.cameraModel == "X-T5" else { return (nil, false) }
        if requireReference && raw.metadata.recordedGeometry != PixelSize(width: 7728, height: 5152) { return (nil, true) }
        let destination = directory.appendingPathComponent("source.RAF")
        try FileManager.default.moveItem(at: local.fileURL, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        let selected = PreparedRAW(fileURL: destination, sha256: raw.sha256, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, metadata: raw.metadata)
        let manifest = SourceManifest(source: source, raw: selected)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("source-manifest.json"), options: [.atomic, .completeFileProtection])
        return (Selection(source: source, raw: selected), true)
    }
    private struct SourceManifest: Encodable {
        let sourceID: String, sourceRevision: String, originalFilename: String, resourceRole: String, sha256: String
        let captureDate: Date?
        let pairedJPEGAvailable: Bool
        let cameraModel: String
        let containerWidth: Int, containerHeight: Int, recordedWidth: Int, recordedHeight: Int
        let aspectWidth: Int, aspectHeight: Int, cropTop: Int, cropLeft: Int, orientation: Int
        init(source: PhotoSource, raw: PreparedRAW) {
            sourceID = raw.sourceID; sourceRevision = raw.sourceRevision; originalFilename = source.originalResources.raf.originalFilename
            resourceRole = source.originalResources.raf.role.rawValue; sha256 = raw.sha256; captureDate = source.captureDate
            pairedJPEGAvailable = source.originalResources.jpeg != nil
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
    private var directory: URL?
    private var didRun = false
    private var artifactWriteFailed = false
    init(transport: ImageCaptureTransport = ImageCaptureTransport(), directory: URL? = nil,
         preparer: RAWBaselineSourcePreparer = RAWBaselineSourcePreparer(reader: PhotoLibraryReader())) {
        self.transport = transport; requestedDirectory = directory; self.preparer = preparer
    }
    func runIfRequested(arguments: [String]) async {
        let otherFlags = ["--xt5-read-only-probe", "--xt5-direct-values-probe", "--camera-reconnect-probe", "--xt5-bank-import-probe"]
        guard arguments.contains("--xt5-raw-baseline-probe"), !otherFlags.contains(where: arguments.contains), !didRun else { return }
        didRun = true
        var probeOwnsClose = false
        do {
            let output = try requestedDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let privateRun = output.appendingPathComponent("xt5-raw-baseline-private", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: privateRun, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            directory = output
            try Data("{\"state\":\"preparing original\"}".utf8).write(to: output.appendingPathComponent("xt5-raw-baseline-evidence.json"), options: .atomic)
            saveLifecycle()
            try writeStatus("Preparing one original using existing Photos access")
            let selected = try await preparer.prepareOne(in: privateRun)
            try writeStatus("Original retained privately; connecting for bounded RAW upload")
            try await transport.connect()
            let native = transport
            let generation = try native.currentSession().generation
            let probe = XT5RawBaselineProbe(transport: native, validateSession: {
                guard try await native.currentSession().generation == generation else { throw XT5BankImportIssue.sessionChanged }
            }, closeSession: {
                // MainActor keeps identity validation and close initiation together. There is no
                // independent connect path on this privately owned transport during the operation.
                try await Self.close(native, expectedGeneration: generation)
            })
            probeOwnsClose = true
            _ = try await probe.capture(raw: selected.raw, directory: privateRun) { [weak self] report in await self?.save(report) }
            try writeStatus(artifactWriteFailed ? "Baseline operation finished, but public evidence writing failed" : "Baseline probe complete; native session closed; upload buffer cleanup remains unconfirmed; conversion unvalidated")
        } catch let failure as XT5RawBaselineFailure {
            try? writeStatus("Baseline probe incomplete: \(failure.evidence.failure ?? failure.evidence.sessionClosureFailure ?? "unknown outcome"); native closure \(failure.evidence.sessionClosure); buffer cleanup unconfirmed")
        } catch {
            let message = error is RAWBaselinePreparationIssue ? "no compatible RAW found within diagnostic search limit" : XT5RawBaselineProbe.safeFailure(error)
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
    private func save(_ report: XT5RawBaselineEvidence) {
        guard let directory else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: directory.appendingPathComponent("xt5-raw-baseline-evidence.json"), options: .atomic)
            try writeStatus("RAW upload accepted: \(report.rawUploadSucceeded); baseline bytes: \(report.baselineBytes ?? 0); native closure: \(report.sessionClosure); buffer cleanup unconfirmed")
        } catch { artifactWriteFailed = true; status = "Evidence file write failed; native closure must still finish" }
        saveLifecycle()
    }
    private func writeStatus(_ message: String) throws {
        status = message
        guard let directory else { return }
        try "\(Date().formatted(.iso8601))\n\(message)\nPrivate source/profile/context under xt5-raw-baseline-private; never publish these files.\n"
            .write(to: directory.appendingPathComponent("xt5-raw-baseline-status.txt"), atomically: true, encoding: .utf8)
    }
    private func saveLifecycle() {
        guard let directory else { return }
        let text = "Public lifecycle:\n" + transport.lifecycleDiagnosticMessages().joined(separator: "\n")
            + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
