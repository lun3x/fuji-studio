@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct CameraExecutionContextTests {
    @Test func getterRequiresVerifiedCurrentSessionAndInvalidatesOnDisconnect() async throws {
        let f = try ProductionOperationFixture(); defer { f.remove() }
        let wire = ProductionSession(fixture: f), journal = try CameraOperationJournal(directory: f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let service = FujiCameraService(session: wire, journal: journal)
        await #expect(throws: CameraServiceError.notReady) { try await service.executionContext() }
        try await service.connect()
        let context = try await service.executionContext()
        #expect(context.generation == 1 && context.firmware == "4.31")
        #expect(context.sessionIdentity != f.profile.bank.cameraContext.sessionIdentity)
        let commandCount = await wire.commands.count
        #expect(try await service.executionContext() == context)
        #expect(await wire.commands.count == commandCount)
        await service.disconnect()
        await #expect(throws: CameraServiceError.self) { try await service.executionContext() }
        try await service.connect()
        #expect(try await service.executionContext().sessionIdentity != context.sessionIdentity)
        await wire.simulatePhysicalReconnect(empty: true)
        await #expect(throws: CameraServiceError.self) { try await service.executionContext() }
        await service.disconnect()
    }
    @Test func queuedGetterCancellationDoesNotCloseOrDisturbOwner() async throws {
        let f = try ProductionOperationFixture(); defer { f.remove() }
        let wire = ProductionSession(fixture: f), journal = try CameraOperationJournal(directory: f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy()), gate = SerialCameraGate()
        let service = FujiCameraService(session: wire, journal: journal, gate: gate)
        try await service.connect()
        let latch = RenderLatch()
        let holder = Task { try await gate.withExclusiveAccess { await latch.wait() } }
        await latch.entered()
        let getter = Task { try await service.executionContext() }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        getter.cancel()
        await #expect(throws: CameraServiceError.cancelled) { try await getter.value }
        #expect(await wire.closes == 0)
        await latch.release(); try await holder.value
        _ = try await service.executionContext()
        await service.disconnect()
    }
}

extension CameraExecutionContextTests {
    @Test func disconnectDuringNativeReadRevokesCapturedExecutionContext() async throws {
        let f = try ProductionOperationFixture(); defer { f.remove() }
        let wire = SuspendedContextSession(ProductionSession(fixture: f)), gate = SerialCameraGate()
        let service = FujiCameraService(session: wire, journal: try CameraOperationJournal(directory: f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy()), gate: gate)
        try await service.connect()
        let latch = RenderLatch(); await wire.hold(latch)
        let getter = Task { try await service.executionContext() }
        await latch.entered()
        let disconnect = Task { await service.disconnect() }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        await latch.release()
        await #expect(throws: CameraServiceError.cancelled) { try await getter.value }
        await disconnect.value
        await #expect(throws: CameraServiceError.self) { try await service.executionContext() }
    }
}

private actor SuspendedContextSession: CameraSessionTransport {
    let underlying: ProductionSession
    var latch: RenderLatch?
    init(_ underlying: ProductionSession) { self.underlying = underlying }
    func hold(_ latch: RenderLatch) { self.latch = latch }
    func states() async -> AsyncStream<CameraState> { await underlying.states() }
    func connect() async throws { try await underlying.connect() }
    func close() async throws { try await underlying.close() }
    func currentSession() async throws -> CameraSession {
        let captured = try await underlying.currentSession()
        if let latch { self.latch = nil; await latch.wait() }
        return captured
    }
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply { try await underlying.execute(command, data: data) }
}
