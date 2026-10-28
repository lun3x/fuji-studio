import FujiCameraCore
import Foundation

/// Exact retained-source diagnostic. This shape/offset is not a general _0200 grammar.
struct XT5FilmProbeReference: Sendable {
    static let byteCount = 625
    static let filmOffset = 513 + 7 * 4
    static let originalFilm: UInt32 = 15 // Actual baseline + vendor AsShot: ACROS+G.
    static let targetFilm: UInt32 = 11 // Pinned libfuji FP_ClassicChrome; vendor differential: Classic.
    let sourceSHA256: String
    let baseline: Data
    func validate(raw: PreparedRAW) throws {
        guard sourceSHA256 == raw.sha256, baseline.count == Self.byteCount,
              baseline.prefix(3) == Data([29,0,8]),
              baseline.subdata(in: Self.filmOffset..<Self.filmOffset+4) == Data([15,0,0,0]) else { throw XT5FilmProbeIssue.invalidReference }
    }
}
enum XT5FilmProbeIssue: Error, Sendable { case invalidReference, baselineMismatch, echoMismatch, patchMismatch }
struct XT5FilmProbeObservation: Sendable, Encodable {
    let label = "experimental film-only working profile; no imported bank applied"
    let byteCount = XT5FilmProbeReference.byteCount
    let filmOffset = XT5FilmProbeReference.filmOffset
    let expectedOriginalFilm = XT5FilmProbeReference.originalFilm
    let targetFilm = XT5FilmProbeReference.targetFilm
    var baselineMatchesReference = false
    var echoAttempted = false
    var echoAccepted = false
    var echoReadbackMatches = false
    var patchAttempted = false
    var patchAccepted = false
    var patchReadbackMatches = false
    var failure: String?
}

/// Called only inside the upload owner's session/gate. No trigger, cleanup or general encoder.
actor XT5FilmWorkingProfileProbe {
    typealias Send = @Sendable (UInt16, [UInt32], Data?) async throws -> PTPReply
    private let send: Send
    init(send: @escaping Send) { self.send = send }
    func run(baseline: Data, reference: XT5FilmProbeReference, directory: URL,
             onUpdate: @Sendable (XT5FilmProbeObservation) async -> Void) async -> XT5FilmProbeObservation {
        var report = XT5FilmProbeObservation()
        do {
            guard baseline == reference.baseline else { throw XT5FilmProbeIssue.baselineMismatch }
            report.baselineMatchesReference = true
            try write(baseline, name: "profile-echo.bin", directory: directory)
            report.echoAttempted = true; await onUpdate(report)
            _ = try await send(0x1016, [0xD185], baseline)
            report.echoAccepted = true; await onUpdate(report)
            let echoed = try await send(0x1015, [0xD185], nil).data
            try write(echoed, name: "profile-echo-readback.bin", directory: directory)
            guard echoed == baseline else { throw XT5FilmProbeIssue.echoMismatch }
            report.echoReadbackMatches = true; await onUpdate(report)
            var patched = baseline
            let offset = XT5FilmProbeReference.filmOffset
            patched.replaceSubrange(offset..<offset+4, with: Data([11,0,0,0]))
            try write(patched, name: "profile-film-patch.bin", directory: directory)
            report.patchAttempted = true; await onUpdate(report)
            _ = try await send(0x1016, [0xD185], patched)
            report.patchAccepted = true; await onUpdate(report)
            let readback = try await send(0x1015, [0xD185], nil).data
            try write(readback, name: "profile-film-readback.bin", directory: directory)
            guard readback == patched else { throw XT5FilmProbeIssue.patchMismatch }
            report.patchReadbackMatches = true
        } catch { report.failure = XT5RawBaselineProbe.safeFailure(error) }
        await onUpdate(report)
        return report
    }
    private func write(_ data: Data, name: String, directory: URL) throws {
        guard data.count <= 65_536 else { throw XT5ProtocolError.oversized }
        do { try data.write(to: directory.appendingPathComponent(name), options: [.atomic,.completeFileProtection]) }
        catch { throw XT5RawBaselineIssue.artifactWriteFailed }
    }
}
