@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct XT5BankImportTests {
    private func importer(_ wire: BankImportWire) -> XT5BankImporter {
        XT5BankImporter(transport: wire, sessionGeneration: 7,
                        validateSession: { try await wire.validateGeneration(7) },
                        settle: { try await wire.settle($0) })
    }
    @Test func readsExactlySevenNamedBanksTwiceWithOnlySelectorWritesAndRestoresOriginal() async throws {
        let wire = BankImportWire()
        let result = try await importer(wire).importRecipesVerified()
        #expect(result.recipes.map(\.slot) == Array(1...7))
        #expect(result.recipes.map(\.name) == (1...7).map { "Synthetic C\($0)" })
        #expect(result.recipes.allSatisfy { $0.importedSettings.count == 23 })
        #expect(result.evidence.comparisons.count == 7)
        #expect(result.evidence.comparisons.allSatisfy { $0.namesMatch && $0.settingsMatch })
        #expect(result.evidence.restoration == .verified)
        #expect(result.evidence.originalSelector == 1)
        #expect(result.evidence.restoredSelector == 1)
        #expect(result.evidence.complete)
        #expect(await wire.writtenSlots == Array(1...7) + Array(1...7) + [1])
        #expect(await wire.invalidWriteCount == 0)
        #expect(await wire.readBeforeSettleCount == 0)
        #expect(await wire.settleDurations == Array(repeating: .milliseconds(100), count: 15))
        #expect(await wire.selected == 1)
        let publicText = String(decoding: try JSONEncoder().encode(result.evidence), as: UTF8.self)
        #expect(!publicText.contains("Synthetic C"))
        #expect(!publicText.contains(result.recipes[0].id.uuidString))
        #expect(!publicText.contains(result.recipes[0].settingsDigest))
    }
    @Test func everyRefreshCreatesNewSnapshotsButKeepsIdenticalSettingsDigest() async throws {
        let wire = BankImportWire(); let reader = importer(wire)
        let first = try await reader.importRecipesVerified()
        let second = try await reader.importRecipesVerified()
        #expect(Set(first.recipes.map(\.id)).isDisjoint(with: Set(second.recipes.map(\.id))))
        #expect(first.recipes.map(\.settingsDigest) == second.recipes.map(\.settingsDigest))
    }
    @Test func rejectedReadRestoresOriginalWithoutPublishingPartialImport() async throws {
        let wire = BankImportWire(failure: .read)
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected read failure") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.restoration == .verified)
            #expect(!failure.evidence.complete)
            #expect(failure.evidence.failure == "PTP response 0x2002")
        }
        #expect(await wire.writtenSlots == [1,2,3,1])
    }
    @Test func changedBankFailsPreservationCheckAndStillRestoresSelector() async throws {
        let wire = BankImportWire(failure: .changed)
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected preservation failure") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.restoration == .verified)
            #expect(failure.evidence.comparisons.last?.slot == 4)
            #expect(failure.evidence.comparisons.last?.namesMatch == false)
            #expect(!failure.evidence.complete)
        }
        #expect(await wire.selected == 1)
    }
    @Test func restoreFailureIsExplicitAndNeverReportedAsSuccessfulImport() async throws {
        let wire = BankImportWire(failure: .restore)
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected restoration failure") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.restoration == .unconfirmed)
            #expect(failure.evidence.restorationFailure == "PTP response 0x201C")
            #expect(!failure.evidence.complete)
        }
    }
    @Test func staleSessionCannotReceiveRestorationWrite() async throws {
        let wire = BankImportWire(failure: .session)
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected stale-session failure") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.restoration == .unconfirmed)
            #expect(failure.evidence.restorationFailure == "sessionChanged")
        }
        #expect(await wire.writtenSlots == [1,2,3])
    }
    @Test func cancellationBetweenCommandsStillRestoresUnderAnUncancelledCleanupTask() async throws {
        let wire = BankImportWire(blockFirstSettle: true)
        let reader = importer(wire)
        let operation = Task { try await reader.importRecipesVerified() }
        await wire.waitForFirstSettle()
        operation.cancel()
        do { _ = try await operation.value; Issue.record("Expected cancellation") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.failure == "cancelled")
            #expect(failure.evidence.restoration == .verified)
        }
        #expect(await wire.writtenSlots == [1,1])
    }
    @Test func wrongSelectorReadbackStopsBeforeReadingWrongBank() async throws {
        let wire = BankImportWire(failure: .selector)
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected selector mismatch") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.beforeSlots == [1])
            #expect(failure.evidence.restoration == .verified)
        }
        #expect(await wire.writtenSlots == [1,2,1])
    }
    @Test func contextMismatchFailsBeforeAnySelectorWrite() async throws {
        let wire = BankImportWire(capability: "X-T5_0100")
        do { _ = try await importer(wire).importRecipesVerified(); Issue.record("Expected context failure") }
        catch let failure as XT5BankImportFailure { #expect(failure.evidence.restoration == .notNeeded) }
        #expect(await wire.writtenSlots.isEmpty)
    }
    @Test func restorationDeadlineReportsUnconfirmedAndCancelsRemainingCleanupReads() async throws {
        let wire = BankImportWire(failure: .restoreTimeout)
        let reader = XT5BankImporter(transport: wire, sessionGeneration: 7,
                                    validateSession: { try await wire.validateGeneration(7) },
                                    settle: { try await wire.settle($0) }, cleanupTimeout: .milliseconds(20))
        do { _ = try await reader.importRecipesVerified(); Issue.record("Expected restoration deadline") }
        catch let failure as XT5BankImportFailure {
            #expect(failure.evidence.restoration == .unconfirmed)
            #expect(failure.evidence.restorationFailure == "restorationTimeout")
            #expect(!failure.evidence.complete)
        }
        #expect(await wire.writtenSlots.count == 15)
    }
    @Test func queuedImportWaitsThroughCancelledImportRestoration() async throws {
        let wire = BankImportWire(blockFirstSettle: true)
        let gate = SerialCameraGate()
        let reader = XT5BankImporter(transport: wire, sessionGeneration: 7,
                                    validateSession: { try await wire.validateGeneration(7) },
                                    settle: { try await wire.settle($0) }, gate: gate)
        let first = Task { try await reader.importRecipesVerified() }
        await wire.waitForFirstSettle()
        let second = Task { try await reader.importRecipesVerified() }
        for _ in 0..<1000 {
            if await gate.queuedOperationCount == 1 { break }
            await Task.yield()
        }
        #expect(await gate.queuedOperationCount == 1)
        first.cancel()
        do { _ = try await first.value; Issue.record("Expected first import cancellation") }
        catch let failure as XT5BankImportFailure { #expect(failure.evidence.restoration == .verified) }
        let result = try await second.value
        #expect(result.evidence.complete)
        #expect(await wire.writtenSlots == [1,1] + Array(1...7) + Array(1...7) + [1])
    }
}

private actor BankImportWire: PTPTransport {
    enum Failure { case none, read, changed, restore, restoreTimeout, session, selector }
    let failure: Failure
    let capability: String
    let blockFirstSettle: Bool
    var selected = 1
    var generation: UInt64 = 7
    var writtenSlots: [Int] = []
    var invalidWriteCount = 0
    var readBeforeSettleCount = 0
    var settleDurations: [Duration] = []
    private var needsSettle = false
    private var failedRead = false
    private var namesRead: [Int:Int] = [:]
    private var settleWaiters: [CheckedContinuation<Void,Never>] = []
    init(failure: Failure = .none, capability: String = "X-T5_0200", blockFirstSettle: Bool = false) {
        self.failure = failure; self.capability = capability; self.blockFirstSettle = blockFirstSettle
    }
    func validateGeneration(_ expected: UInt64) throws {
        guard generation == expected else { throw XT5BankImportIssue.sessionChanged }
    }
    func settle(_ duration: Duration) async throws {
        settleDurations.append(duration)
        for waiter in settleWaiters { waiter.resume() }; settleWaiters = []
        if blockFirstSettle && settleDurations.count == 1 { try await Task.sleep(for: .seconds(30)) }
        if failure == .restoreTimeout && settleDurations.count == 15 { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        needsSettle = false
    }
    func waitForFirstSettle() async {
        if settleDurations.isEmpty { await withCheckedContinuation { settleWaiters.append($0) } }
    }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        try Task.checkCancellation()
        let payload: Data
        if command.opcode == 0x1001 {
            payload = ProtocolProbeFixtures.deviceInfo(properties: [0xD16E,0xD186,0xD187,0xD18C,0xD18D] + Array(0xD18E...0xD1A4), operations: [0x1001,0x1015,0x1016], firmware: "4.31")
        } else if command.opcode == 0x1016 {
            guard command.parameters == [0xD18C], let data, data.count == 2, data[1] == 0, (1...7).contains(data[0]) else {
                invalidWriteCount += 1; throw PTPError.invalidParameters
            }
            let slot = Int(data[0]); writtenSlots.append(slot)
            if failure == .restore && writtenSlots.count == 15 { throw PTPError.responseCode(0x201C) }
            selected = slot; needsSettle = true; payload = Data()
        } else {
            guard command.opcode == 0x1015, command.parameters.count == 1, data == nil,
                  let code = UInt16(exactly: command.parameters[0]) else { throw PTPError.invalidParameters }
            if needsSettle { readBeforeSettleCount += 1; throw PTPError.busy }
            switch code {
            case 0xD16E: payload = Data([6,0])
            case 0xD186,0xD187: payload = ProtocolProbeFixtures.string(capability)
            case 0xD18C:
                payload = Data([UInt8(failure == .selector && selected == 2 ? 1 : selected),0])
            case 0xD18D:
                namesRead[selected,default:0] += 1
                let changed = failure == .changed && selected == 4 && namesRead[4,default:0] >= 2
                payload = ProtocolProbeFixtures.string(changed ? "CHANGED PRIVATE NAME" : "Synthetic C\(selected)")
            case 0xD18E...0xD1A4:
                if selected == 3 && code == 0xD190 && !failedRead && (failure == .read || failure == .session) {
                    failedRead = true
                    if failure == .session { generation = 8; throw PTPError.notConnected }
                    throw PTPError.responseCode(0x2002)
                }
                payload = BankImportFixtures.properties[code]!
            default: throw PTPError.invalidParameters
            }
        }
        var response = Data([12,0,0,0,3,0,1,32])
        let wire = command.transactionID + 8
        response.append(contentsOf: [UInt8(truncatingIfNeeded: wire),UInt8(truncatingIfNeeded: wire >> 8),UInt8(truncatingIfNeeded: wire >> 16),UInt8(truncatingIfNeeded: wire >> 24)])
        return PTPReply(opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID, wireTransactionID: wire,
                        correlation: .imageCaptureCoreCallback(echoedCommand: command), responseCode: 0x2001, rawResponse: response, data: payload)
    }
}

@MainActor struct XT5BankLaunchTests {
    @Test func liveSessionAccessorRejectsClosedAndQuarantinedTransport() async throws {
        let driver = ControlledCameraDriver()
        let transport = ImageCaptureTransport(driver: driver)
        #expect(throws: PTPError.notConnected) { try transport.currentSession() }
        let opening = Task { try await transport.connect() }
        await driver.waitForStartCount(1)
        driver.emit(.opened(CameraConnection(name: "Synthetic X-T5", usbVendorID: 0x04cb, usbProductID: 0x02fc)))
        try await opening.value
        #expect(try transport.currentSession().generation == 1)
        await transport.disconnect()
        #expect(throws: PTPError.notConnected) { try transport.currentSession() }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.finishClose()
        #expect(throws: PTPError.notConnected) { try transport.currentSession() }
    }
    @Test func explicitBankProbeSeparatesPrivateSnapshotsFromSanitizedEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wire = BankImportWire()
        let transport = ImageCaptureTransport(driver: BankProbeDriver(wire: wire))
        let runner = XT5BankImportLaunchRunner(transport: transport, directory: directory)
        await runner.runIfRequested(arguments: ["--xt5-bank-import-probe"])
        let publicData = try Data(contentsOf: directory.appendingPathComponent("xt5-bank-import-evidence.json"))
        let privateData = try Data(contentsOf: directory.appendingPathComponent("xt5-bank-import-private.json"))
        let publicText = String(decoding: publicData, as: UTF8.self)
        let privateText = String(decoding: privateData, as: UTF8.self)
        let publicObject = try #require(JSONSerialization.jsonObject(with: publicData) as? [String:Any])
        let privateObject = try #require(JSONSerialization.jsonObject(with: privateData) as? [String:Any])
        #expect(publicObject["complete"] as? Bool == true)
        #expect(!publicText.contains("Synthetic C"))
        #expect(privateText.contains("Synthetic C1"))
        #expect(privateText.contains("Synthetic C7"))
        #expect((privateObject["snapshots"] as? [Any])?.count == 7)
        #expect((privateObject["verificationSnapshots"] as? [Any])?.count == 7)
        #expect(await wire.writtenSlots.count == 15)
        #expect(throws: PTPError.notConnected) { try transport.currentSession() }
    }
    @Test func ordinaryAndMixedEngineeringFlagsDoNotStartBankOrOtherProbes() async {
        for arguments in [["FujiStudio"], ["--xt5-bank-import-probe","--xt5-read-only-probe"],
                          ["--xt5-bank-import-probe","--xt5-direct-values-probe"], ["--xt5-bank-import-probe","--camera-reconnect-probe"]] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let driver = BankProbeDriver(wire: BankImportWire())
            let transport = ImageCaptureTransport(driver: driver)
            await XT5BankImportLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: arguments)
            await XT5ProbeLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: arguments)
            await CameraReconnectLaunchRunner(transport: transport, directory: directory).runIfRequested(arguments: arguments)
            #expect(driver.startCount == 0)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}

@MainActor private final class BankProbeDriver: CameraSessionDriver {
    let wire: BankImportWire
    var startCount = 0
    init(wire: BankImportWire) { self.wire = wire }
    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void) {
        startCount += 1
        events(.discoveryStarted)
        events(.opened(CameraConnection(name: "Synthetic X-T5", usbVendorID: 0x04cb, usbProductID: 0x02fc)))
    }
    func close(completion: @escaping @MainActor @Sendable () -> Void) { completion() }
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void) {
        func word(_ offset: Int) -> UInt32 {
            command[offset..<(offset+4)].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        let opcode = UInt16(command[6]) | UInt16(command[7]) << 8
        let logical = PTPCommand(opcode: opcode, parameters: command.count == 16 ? [word(12)] : [], transactionID: word(8))
        Task {
            do {
                let reply = try await wire.execute(logical, data: data)
                if opcode == 0x1016 { try await wire.settle(.milliseconds(100)) }
                completion(.success(PTPWireReply(correlation: .imageCaptureCoreCallback(echoedCommand: logical), response: reply.rawResponse, data: reply.data)))
            } catch let error as PTPError { completion(.failure(error)) }
            catch { completion(.failure(.sessionFailure("synthetic boundary failure"))) }
        }
    }
}
