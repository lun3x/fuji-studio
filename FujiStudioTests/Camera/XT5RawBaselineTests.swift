import Foundation
import Testing
@testable import FujiStudio

struct XT5ConversionCodecTests {
    @Test func uploadInfoUsesPinnedVendorRAFFormatAndFixedTransferName() throws {
        let data = try XT5ConversionCodec.uploadInfo(byteCount: 0x123456)
        #expect(data.count == 82)
        #expect(Data(data.prefix(12)) == Data([0,0,0,0,2,248,0,0,86,52,18,0]))
        #expect(Data(data[12..<52]) == Data(repeating: 0, count: 40))
        #expect(Data(data.suffix(30)) == Data([13,70,0,85,0,80,0,95,0,70,0,73,0,76,0,69,0,46,0,100,0,97,0,116,0,0,0,0,0,0]))
    }
    @Test func refusesZeroAndOversizedUploadLengths() {
        for count in [0, -1, 128 * 1024 * 1024 + 1] {
            #expect(throws: (any Error).self) { try XT5ConversionCodec.uploadInfo(byteCount: count) }
        }
    }
    @Test func distinguishesTrulyEmptyHandlesFromMalformedOrOversizedEnumeration() throws {
        #expect(try XT5ConversionCodec.objectHandles(Data([0,0,0,0])) == [])
        let valid = Data([2,0,0,0,7,0,0,0,9,0,0,0])
        #expect(try XT5ConversionCodec.objectHandles(valid) == [7,9])
        for count in 0..<valid.count {
            #expect(throws: (any Error).self) { try XT5ConversionCodec.objectHandles(Data(valid.prefix(count))) }
        }
        for invalid in [valid + Data([0]), Data([255,255,255,255]), Data([1,0,0,0,0,0,0,0]), Data([2,0,0,0,7,0,0,0,7,0,0,0])] {
            #expect(throws: (any Error).self) { try XT5ConversionCodec.objectHandles(invalid) }
        }
    }
}

struct XT5RawBaselineTests {
    @Test func uploadPrecedesBaselineAndNeverDeletesEvenReturnedOrNewHandles() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let wire = BaselineWire()
        let result = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory)
        #expect(result.rawUploadSucceeded)
        #expect(result.baselineBytes == 601)
        #expect(result.preexistingObjectCount == 0)
        #expect(result.newObjectCount == 1)
        #expect(result.sessionClosure == "confirmed")
        #expect(result.bufferCleanup == "unconfirmed")
        let commands = await wire.commands
        #expect(commands.map(\.opcode) == [0x1001,0x1015,0x1015,0x1015,0x1007,0x900C,0x900D,0x1015,0x1007,0x1008])
        #expect(commands.first { $0.opcode == 0x900C }?.parameters == [0,0,0])
        #expect(commands.first { $0.opcode == 0x900D }?.parameters == [])
        #expect(await wire.outboundLengths == [82,256])
        #expect(await wire.closed)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("baseline.bin")) == Data(repeating: 0x5a, count: 601))
        #expect(FileManager.default.fileExists(atPath: fixture.raw.fileURL.path))
        let publicText = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!publicText.contains("PRIVATE"))
        #expect(!publicText.contains(fixture.raw.sha256))
        #expect(!publicText.contains("FUP_FILE.dat"))
    }
    @Test func nonemptyOrRejectedEnumerationAbortsBeforeMutationAndStillCloses() async throws {
        for mode in [BaselineWire.Mode.nonempty, .enumerationRejected, .enumerationMalformed] {
            let fixture = try BaselineFixture(); defer { fixture.remove() }
            let wire = BaselineWire(mode: mode)
            do { _ = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory); Issue.record("Expected preflight failure") }
            catch let failure as XT5RawBaselineFailure {
                #expect(!failure.evidence.rawUploadSucceeded)
                #expect(failure.evidence.sessionClosure == "confirmed")
            }
            #expect(await wire.commands.allSatisfy { ![0x900C,0x900D,0x100B,0x1016].contains($0.opcode) })
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("baseline.bin").path))
        }
    }
    @Test func failedUploadCannotReadBaselineAndDoesNotDeleteUnknownObjects() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let wire = BaselineWire(mode: .uploadRejected)
        do { _ = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory); Issue.record("Expected upload failure") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
        #expect(await wire.commands.allSatisfy { $0.parameters != [0xD185] && $0.opcode != 0x100B })
    }
    @Test func changedSourceIsRejectedBeforeUploadMetadataIsSent() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        try Data([0,1,2]).write(to: fixture.raw.fileURL)
        let wire = BaselineWire()
        do { _ = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory); Issue.record("Expected checksum failure") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.failure == "source checksum mismatch") }
        #expect(await wire.commands.allSatisfy { ![0x900C,0x900D].contains($0.opcode) })
    }
    @Test func unexpectedModeAbortsBeforeUploadAndMalformedBaselineIsNeverRetained() async throws {
        for mode in [BaselineWire.Mode.wrongMode, .emptyBaseline, .oversizedBaseline] {
            let fixture = try BaselineFixture(); defer { fixture.remove() }
            let wire = BaselineWire(mode: mode)
            do { _ = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory); Issue.record("Expected strict precondition or profile bound failure") }
            catch let failure as XT5RawBaselineFailure {
                #expect(failure.evidence.sessionClosure == "confirmed")
                #expect(!failure.evidence.probeFinished)
                #expect(failure.evidence.baselineBytes == nil)
            }
            if mode == .wrongMode { #expect(await wire.commands.allSatisfy { ![0x900C,0x900D].contains($0.opcode) }) }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("baseline.bin").path))
        }
    }
    @Test func staleGenerationStopsBaselineAndCannotCloseNewSession() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let wire = BaselineWire(mode: .staleAfterUpload)
        do { _ = try await probe(wire).capture(raw: fixture.raw, directory: fixture.directory); Issue.record("Expected stale session") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "unconfirmed") }
        #expect(await wire.commands.allSatisfy { $0.parameters != [0xD185] && $0.opcode != 0x100B })
        #expect(await wire.closed == false)
    }
    @Test func cancellationStillClosesAndGateStaysHeldUntilCloseFinishes() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let wire = BaselineWire(mode: .cancelledUpload)
        let barrier = BaselineCloseBarrier()
        let gate = SerialCameraGate()
        let probe = XT5RawBaselineProbe(transport: wire, validateSession: { try await wire.validate() }, closeSession: {
            try Task.checkCancellation()
            await barrier.close()
        }, gate: gate)
        let first = Task { try await probe.capture(raw: fixture.raw, directory: fixture.directory) }
        for _ in 0..<500 { if await barrier.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await barrier.started)
        first.cancel()
        let next = Task { try await gate.withExclusiveAccess { await barrier.enterNext() } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await barrier.nextEntered == false)
        await barrier.finish()
        do { _ = try await first.value; Issue.record("Expected cancellation") }
        catch let failure as XT5RawBaselineFailure { #expect(failure.evidence.sessionClosure == "confirmed") }
        try await next.value
        #expect(await barrier.nextEntered)
        #expect(await wire.commands.allSatisfy { $0.parameters != [0xD185] && $0.opcode != 0x100B })
    }
    private func probe(_ wire: BaselineWire) -> XT5RawBaselineProbe {
        XT5RawBaselineProbe(transport: wire, validateSession: { try await wire.validate() }, closeSession: { try await wire.close() })
    }
}

private struct BaselineFixture {
    let directory: URL
    let raw: PreparedRAW
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.RAF")
        try Data(repeating: 0x52, count: 256).write(to: url)
        raw = PreparedRAW(fileURL: url, sha256: try ResourceChecksum.sha256(url), sourceID: "PRIVATE-SOURCE", sourceRevision: "PRIVATE-REVISION", metadata: Self.metadata)
    }
    static let metadata = RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 7872,height: 5196), recordedGeometry: PixelSize(width: 7728,height: 5152), recordedAspect: PixelSize(width: 3,height: 2), cropTop: 21, cropLeft: 12, orientation: 1)
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor BaselineWire: PTPTransport {
    enum Mode { case normal, nonempty, enumerationRejected, enumerationMalformed, uploadRejected, staleAfterUpload, cancelledUpload, wrongMode, emptyBaseline, oversizedBaseline }
    let mode: Mode
    var commands: [PTPCommand] = []
    var outboundLengths: [Int] = []
    var closed = false
    var current = true
    private var enumerations = 0
    init(mode: Mode = .normal) { self.mode = mode }
    func validate() throws { guard current else { throw XT5BankImportIssue.sessionChanged } }
    func close() throws { try validate(); closed = true }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        try Task.checkCancellation(); commands.append(command)
        if let data { outboundLengths.append(data.count) }
        let payload: Data
        let parameters: [UInt32]
        switch (command.opcode, command.parameters) {
        case (0x1001, []):
            payload = ProtocolProbeFixtures.deviceInfo(properties: [0xD16E,0xD185,0xD186,0xD187], operations: [0x1001,0x1015,0x1007,0x1008,0x900C,0x900D], firmware: "4.31"); parameters = []
        case (0x1015, [0xD16E]): payload = Data([mode == .wrongMode ? 5 : 6,0]); parameters = []
        case (0x1015, [0xD186]), (0x1015, [0xD187]): payload = ProtocolProbeFixtures.string("X-T5_0200"); parameters = []
        case (0x1007, [UInt32.max,0,0]):
            enumerations += 1
            if mode == .enumerationRejected { throw PTPError.responseCode(0x2002) }
            if mode == .enumerationMalformed { payload = Data(); parameters = [] }
            else if enumerations > 1 || mode == .nonempty { payload = Data([1,0,0,0,77,0,0,0]); parameters = [] }
            else { payload = Data([0,0,0,0]); parameters = [] }
        case (0x900C, [0,0,0]): payload = Data(); parameters = [0,0,77]
        case (0x900D, []):
            if mode == .cancelledUpload { throw CancellationError() }
            if mode == .uploadRejected { throw PTPError.responseCode(0x2002) }
            if mode == .staleAfterUpload { current = false }
            payload = Data(); parameters = []
        case (0x1015, [0xD185]): payload = Data(repeating: 0x5a, count: mode == .emptyBaseline ? 0 : mode == .oversizedBaseline ? 65_537 : 601); parameters = []
        case (0x1008, [77]): payload = Data("PRIVATE-OBJECT-METADATA".utf8); parameters = []
        default: throw PTPError.invalidParameters
        }
        func word(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        var response = Data(word(UInt32(12 + parameters.count * 4)) + [3,0,1,32] + word(command.transactionID + 9))
        parameters.forEach { response.append(contentsOf: word($0)) }
        return PTPReply(opcode: command.opcode, parameters: parameters, logicalTransactionID: command.transactionID, wireTransactionID: command.transactionID + 9,
                        correlation: .imageCaptureCoreCallback(echoedCommand: command), responseCode: 0x2001, rawResponse: response, data: payload)
    }
}

private actor BaselineCloseBarrier {
    var started = false
    var nextEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func close() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
    func enterNext() { nextEntered = true }
}

struct XT5BaselinePreparationTests {
    @Test func prefersReferenceGeometryOneSourceAtATimeAndKeepsPairTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = BaselineLibrary(ids: ["square","reference"])
        let preparer = RAWBaselineSourcePreparer(reader: library, prepare: Self.prepare)
        let selected = try await preparer.prepareOne(in: directory)
        #expect(selected.raw.metadata.recordedGeometry == PixelSize(width: 7728,height: 5152))
        #expect(selected.source.id == "reference")
        #expect(selected.source.originalResources.jpeg != nil)
        #expect(selected.raw.sourceID == "reference")
        #expect(selected.raw.fileURL.lastPathComponent == "source.RAF")
        #expect(await library.materializedIDs == ["square","reference"])
        #expect(await library.maximumActiveTemporaryFiles == 1)
        #expect(await library.authorizationRequests == 0)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source-manifest.json").path))
    }
    @Test func fallsBackToCompatibleRecordedGeometryWithoutKeepingTwoOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = BaselineLibrary(ids: ["square"])
        let selected = try await RAWBaselineSourcePreparer(reader: library, prepare: Self.prepare).prepareOne(in: directory)
        #expect(selected.raw.metadata.recordedGeometry == PixelSize(width: 5000,height: 5000))
        #expect(await library.maximumActiveTemporaryFiles == 1)
        #expect(await library.materializedIDs == ["square","square"])
    }
    @Test func boundsCandidatesAndNeverPromptsForPhotosAuthorization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = BaselineLibrary(ids: ["old1","old2","old3"])
        let preparer = RAWBaselineSourcePreparer(reader: library, maximumCandidates: 2, prepare: { _ in throw ResourceError.incompatibleCamera("X-E3") })
        await #expect(throws: RAWBaselinePreparationIssue.noCompatibleRAW) { try await preparer.prepareOne(in: directory) }
        #expect(await library.materializedIDs == ["old1","old2"])
        #expect(await library.authorizationRequests == 0)
        #expect(await library.remainingTemporaryFiles == 0)
    }
    private static func prepare(_ local: LocalResource) throws -> PreparedRAW {
        let meta = local.token.assetID == "reference" ? BaselineFixture.metadata
            : RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 7872,height: 5196), recordedGeometry: PixelSize(width: 5000,height: 5000), recordedAspect: PixelSize(width: 1,height: 1), cropTop: 0,cropLeft: 0,orientation: 1)
        return PreparedRAW(fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID, sourceRevision: local.token.sourceRevision, metadata: meta)
    }
}

private actor BaselineLibrary: PhotoLibraryReading {
    let ids: [String]
    var materializedIDs: [String] = []
    var authorizationRequests = 0
    var maximumActiveTemporaryFiles = 0
    private var urls: [URL] = []
    var remainingTemporaryFiles: Int { urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count }
    init(ids: [String]) { self.ids = ids }
    func requestAccess() -> LibraryAccess { authorizationRequests += 1; return .denied }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> {
        AsyncThrowingStream { $0.yield(ids.map(Self.source)); $0.finish() }
    }
    func source(id: SourceID) throws -> PhotoSource { Self.source(id) }
    func resources(assetID: String) -> [ResourceToken] { [] }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        materializedIDs.append(resource.assetID)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1,2,3]).write(to: url); urls.append(url)
        maximumActiveTemporaryFiles = max(maximumActiveTemporaryFiles, remainingTemporaryFiles)
        return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
    private static func source(_ id: String) -> PhotoSource {
        let raw = ResourceToken(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image", format: .raf, originalFilename: "PRIVATE.RAF", discriminator: "raw", sourceRevision: "revision")
        let jpeg = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "PRIVATE.JPG", discriminator: "jpeg", sourceRevision: "revision")
        return PhotoSource(id: id, originalResources: OriginalResources(raf: raw,jpeg: jpeg), captureDate: nil,location: nil,resourceRevision: "revision")
    }
}

@MainActor struct XT5RawBaselineLaunchTests {
    @Test func ordinaryAndConflictingFlagsAreInertForEveryRunner() async {
        let flag = "--xt5-raw-baseline-probe"
        let flags = ["--xt5-read-only-probe","--xt5-direct-values-probe","--xt5-bank-import-probe","--camera-reconnect-probe"]
        let recovery = "--xt5-output-recovery-probe"
        let modes = [flag,"--xt5-unchanged-baseline-probe",recovery,"--xt5-output-quarantine-probe","--xt5-trigger-one-probe"]
        let mixed = modes.enumerated().flatMap { index, first in modes.dropFirst(index + 1).map { [first,$0] } }
        for args in [["FujiStudio"]] + mixed + modes.flatMap({ mode in flags.map { [mode,$0] } }) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let driver = BaselineProbeDriver()
            let transport = ImageCaptureTransport(driver: driver)
            let library = BaselineLibrary(ids: ["reference"])
            await XT5RawBaselineLaunchRunner(transport: transport, directory: directory, preparer: RAWBaselineSourcePreparer(reader: library)).runIfRequested(arguments: args)
            await XT5ProbeLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: args)
            await XT5BankImportLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: args)
            await CameraReconnectLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: args)
            #expect(driver.startCount == 0)
            #expect(await library.materializedIDs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
    @Test func unchangedProbeRequiresRetainedOriginalAndNeverFallsBackToPhotos() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BaselineLibrary(ids: ["reference"])
        let driver = BaselineProbeDriver()
        let runner = XT5RawBaselineLaunchRunner(transport: ImageCaptureTransport(driver: driver),directory: directory,
            preparer: RAWBaselineSourcePreparer(reader: library), retainedSource: { _,_ in throw XT5ConversionProbeIssue.retainedSourceUnavailable })
        await runner.runIfRequested(arguments: ["--xt5-unchanged-baseline-probe"])
        #expect(driver.startCount == 0)
        #expect(await library.materializedIDs.isEmpty)
        #expect(runner.status.contains("retainedSourceUnavailable"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("xt5-unchanged-baseline-status.txt").path))
    }
    @Test func recoveryLaunchRequiresRetainedSourceBeforeOpeningCamera() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BaselineLibrary(ids: ["reference"])
        let driver = BaselineProbeDriver()
        let runner = XT5RawBaselineLaunchRunner(transport: ImageCaptureTransport(driver: driver),directory: directory,
            preparer: RAWBaselineSourcePreparer(reader: library),retainedSource: { _,_ in throw XT5ConversionProbeIssue.retainedSourceUnavailable })
        await runner.runIfRequested(arguments: ["--xt5-output-recovery-probe"])
        #expect(driver.startCount == 0)
        #expect(await library.materializedIDs.isEmpty)
        #expect(runner.status.contains("retainedSourceUnavailable"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("xt5-output-recovery-status.txt").path))
    }
    @Test func recoveryLaunchCannotFallBackToUploadWhenReadCapabilitiesAreMissing() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let driver = BaselineProbeDriver() // Advertises upload support, but no GetObject download.
        let runner = XT5RawBaselineLaunchRunner(transport: ImageCaptureTransport(driver: driver),directory: fixture.directory,
                                               retainedSource: { _,_ in fixture.raw })
        await runner.runIfRequested(arguments: ["--xt5-output-recovery-probe"])
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("xt5-output-recovery-evidence.json"))) as? [String:Any])
        #expect(report["readOnlyRecovery"] as? Bool == true)
        #expect(report["rawUploadSucceeded"] as? Bool == false)
        #expect(report["sessionClosure"] as? String == "confirmed")
        #expect(await driver.wire.commands.allSatisfy { [0x1001,0x1015].contains($0.opcode) })
    }
    @Test func quarantineLaunchIsExplicitReadOnlyAndUsesSeparateEvidence() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let driver = BaselineProbeDriver()
        let library = BaselineLibrary(ids: ["reference"])
        let runner = XT5RawBaselineLaunchRunner(transport: ImageCaptureTransport(driver: driver),directory: fixture.directory,
            preparer: RAWBaselineSourcePreparer(reader: library),retainedSource: { _,_ in fixture.raw })
        await runner.runIfRequested(arguments: ["--xt5-output-quarantine-probe"])
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("xt5-output-quarantine-evidence.json"))) as? [String:Any])
        #expect(report["readOnlyRecovery"] as? Bool == true)
        #expect(report["quarantineRequested"] as? Bool == true)
        #expect(report["rawUploadSucceeded"] as? Bool == false)
        #expect(report["sessionClosure"] as? String == "confirmed")
        #expect(await library.materializedIDs.isEmpty)
        #expect(await driver.wire.commands.allSatisfy { [0x1001,0x1015].contains($0.opcode) })
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("xt5-output-recovery-evidence.json").path))
    }
    @Test func triggerOneRequiresPreservedCleanupProofBeforeOpeningCamera() async throws {
        let fixture = try BaselineFixture(); defer { fixture.remove() }
        let driver = BaselineProbeDriver()
        let library = BaselineLibrary(ids: ["reference"])
        let runner = XT5RawBaselineLaunchRunner(transport: ImageCaptureTransport(driver: driver),directory: fixture.directory,
            preparer: RAWBaselineSourcePreparer(reader: library),retainedSource: { _,_ in fixture.raw })
        await runner.runIfRequested(arguments: ["--xt5-trigger-one-probe"])
        #expect(driver.startCount == 0)
        #expect(await library.materializedIDs.isEmpty)
        #expect(runner.status.contains("invalidPreservedProof"))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("xt5-trigger-one-status.txt").path))
    }
    @Test func retainedSelectionRejectsMissingAndAmbiguousRunsWithoutGuessingLatest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await RetainedRAWProbeSource.prepare(documents: directory,destination: output) }
        for _ in 0..<2 {
            let run = directory.appendingPathComponent("xt5-raw-baseline-private").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: run,withIntermediateDirectories: true)
            try Data().write(to: run.appendingPathComponent("source.RAF"))
            try Data().write(to: run.appendingPathComponent("source-manifest.json"))
        }
        await #expect(throws: (any Error).self) { try await RetainedRAWProbeSource.prepare(documents: directory,destination: output) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
    @Test func explicitCaptureKeepsOriginalPrivateAndAwaitsNativeClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = BaselineProbeDriver(); driver.holdClose = true
        let transport = ImageCaptureTransport(driver: driver)
        let library = BaselineLibrary(ids: ["reference"])
        let preparer = RAWBaselineSourcePreparer(reader: library, prepare: { local in
            PreparedRAW(fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID, sourceRevision: "PRIVATE", metadata: BaselineFixture.metadata)
        })
        let runner = XT5RawBaselineLaunchRunner(transport: transport, directory: directory, preparer: preparer)
        let task = Task { await runner.runIfRequested(arguments: ["--xt5-raw-baseline-probe"]) }
        for _ in 0..<1000 { if driver.closeCompletion != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(driver.closeCompletion != nil)
        let evidenceURL = directory.appendingPathComponent("xt5-raw-baseline-evidence.json")
        let partial = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL)) as? [String:Any])
        #expect(partial["probeFinished"] as? Bool == false)
        #expect(partial["sessionClosure"] as? String != "confirmed")
        driver.finishClose()
        await task.value
        let publicData = try Data(contentsOf: evidenceURL)
        let result = try #require(JSONSerialization.jsonObject(with: publicData) as? [String:Any])
        #expect(result["probeFinished"] as? Bool == true)
        #expect(result["sessionClosure"] as? String == "confirmed")
        #expect(result["bufferCleanup"] as? String == "unconfirmed")
        #expect(!String(decoding: publicData, as: UTF8.self).contains("PRIVATE"))
        let runs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("xt5-raw-baseline-private"), includingPropertiesForKeys: nil)
        #expect(runs.count == 1)
        for name in ["source.RAF","source-manifest.json","protocol-manifest.json","baseline.bin"] {
            #expect(FileManager.default.fileExists(atPath: runs[0].appendingPathComponent(name).path))
        }
        #expect(await library.authorizationRequests == 0)
        #expect(throws: PTPError.notConnected) { try transport.currentSession() }
    }
}

@MainActor private final class BaselineProbeDriver: CameraSessionDriver {
    let wire = BaselineWire()
    var startCount = 0
    var holdClose = false
    var closeCompletion: (@MainActor @Sendable () -> Void)?
    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void) {
        startCount += 1
        events(.discoveryStarted)
        events(.opened(CameraConnection(name: "Synthetic X-T5", usbVendorID: 0x04cb, usbProductID: 0x02fc)))
    }
    func close(completion: @escaping @MainActor @Sendable () -> Void) {
        closeCompletion = completion
        if !holdClose { finishClose() }
    }
    func finishClose() { let callback = closeCompletion; closeCompletion = nil; callback?() }
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void) {
        Task {
            do {
                let logical = try PTPCodec.decodeCommand(command)
                let reply = try await wire.execute(logical, data: data)
                completion(.success(PTPWireReply(correlation: .imageCaptureCoreCallback(echoedCommand: logical), response: reply.rawResponse, data: reply.data)))
            } catch let error as PTPError { completion(.failure(error)) }
              catch { completion(.failure(.sessionFailure("synthetic failure"))) }
        }
    }
}
