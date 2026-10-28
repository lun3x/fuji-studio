@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct XT5ProductionCameraServiceTests {
    @Test func importFailureReportsRestorationWithoutPretendingStorageFailed() {
        var evidence=XT5BankImportEvidence();evidence.restoration = .unconfirmed
        #expect(XT5Adapter.importFailure(XT5BankImportFailure(evidence:evidence)) == .recipeImportFailed(restorationConfirmed:false))
        evidence.restoration = .verified
        #expect(XT5Adapter.importFailure(XT5BankImportFailure(evidence:evidence)) == .recipeImportFailed(restorationConfirmed:true))
    }
    @Test func renderUsesFrozenRecipeFreshBaselineAndReturnsOnlyAfterOwnedCleanup() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let service=makeService(wire,journal)
        try await service.connect()
        let result=try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
        #expect(result.recipeSnapshotID == f.profile.bank.id && result.settingsDigest == f.profile.bank.settingsDigest)
        #expect(result.cameraContext.sessionIdentity != f.profile.bank.cameraContext.sessionIdentity)
        #expect(result.quality == .fullResolutionFine && !result.effectiveRecipe.lensOptimizerAdjusted)
        #expect(result.fileURL == journal.operationDirectory(result.operationID).appendingPathComponent("output.JPG"))
        #expect(try Data(contentsOf:result.fileURL) == Data([1,2,3,4]))
        #expect(try journal.load(result.operationID).phase == .completed)
        #expect(try journal.unresolved().isEmpty)
        #expect(await wire.deletes == [77]);#expect(await wire.closes == 0)
        let commands=await wire.commands
        #expect(commands.filter { $0.opcode == 0x1016 }.map(\.parameters) == [[0xD185],[0xD183]])
        #expect(commands.firstIndex { $0.opcode == 0x900D }! < commands.firstIndex { $0.parameters == [0xD185] }!)
        #expect(commands.allSatisfy { ![0xD18C,0xD16E].contains($0.parameters.first ?? 0) || $0.opcode != 0x1016 })
        var states=await service.states().makeAsyncIterator()
        if case .ready = await states.next() {} else { Issue.record("Expected verified ready after whole operation") }
        await service.disconnect();#expect(await wire.closes == 1)
    }
    @Test func changedSourceAndPreexistingObjectsNeverReachUpload() async throws {
        for mode in [ProductionSession.Mode.preexisting,.normal] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            if mode == .normal { try Data([0]).write(to:f.raw.fileURL) }
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.commands.allSatisfy { ![0x900C,0x900D,0x100B].contains($0.opcode) })
            await service.disconnect()
        }
    }
    @Test func profileRefusalNeverTriggersAndCloseIsConfirmed() async throws {
        for mode in [ProductionSession.Mode.profileRejected,.readbackMismatch] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.triggers == 0);#expect(await wire.deletes.isEmpty)
            #expect(await wire.closes == 1)
            #expect(try journal.unresolved().isEmpty)
        }
    }
    @Test func unsafeOutputOrUncertainCleanupPinsJournalAndNeverReplays() async throws {
        for mode in [ProductionSession.Mode.wrongStorage,.replacedHandle,.payloadChanged,.deleteRejected,.nonemptyAfterDelete,.staleAfterTrigger,.triggerRejected] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            let pending=try journal.unresolved();#expect(pending.count == 1)
            let deletes=await wire.deletes
            #expect(deletes.count <= 1)
            if [.wrongStorage,.replacedHandle,.payloadChanged,.staleAfterTrigger,.triggerRejected].contains(mode) { #expect(deletes.isEmpty) }
            let reopened=makeService(wire,try CameraOperationJournal(directory:journal.directory, filePolicy: IOSCameraJournalFilePolicy()))
            if mode == .triggerRejected { try await reopened.connect();await reopened.disconnect() }
            else { await #expect(throws:CameraServiceError.self) { try await reopened.connect() } }
            #expect(await wire.deletes == deletes)
            if [.deleteRejected,.nonemptyAfterDelete].contains(mode) {
                #expect(pending.first?.outputValidated == true)
                #expect(FileManager.default.fileExists(atPath:journal.operationDirectory(pending[0].id).appendingPathComponent("output.JPG").path))
            }
        }
    }
    @Test func invalidFineOrMissingLMOCannotProduceCameraJPEGOrDelete() async throws {
        for missing in [false,true] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
            let service=FujiCameraService(session:wire,journal:journal,pollWait:{},registry:FujiCameraRegistry(adapters:[XT5Adapter(validateJPEG:{ _,m in
                if !missing { throw FujiJPEGValidationError.notFine }
                return ValidatedJPEGMetadata(width:m.recordedGeometry.width,height:m.recordedGeometry.height,orientation:m.orientation,make:"FUJIFILM",model:"X-T5",quality:.fine,lensOptimizer:nil)
            })]))
            try await service.connect()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.deletes.isEmpty)
            #expect(try journal.unresolved().count == 1)
        }
    }
    @Test func disconnectDuringStateSubscriptionPreventsNativeOpen() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,holdStates:true)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let gate=SerialCameraGate(),service=makeService(wire,journal,gate:gate)
        let connecting=Task { try await service.connect() }
        await wire.waitUntilHeld()
        let disconnecting=Task { await service.disconnect() }
        // Queuing proves disconnect has set its stop flag and advanced the admission epoch.
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        await wire.release()
        await #expect(throws:CameraServiceError.cancelled) { try await connecting.value }
        await disconnecting.value
        #expect(await wire.connects == 0)
        #expect(await wire.closes == 0)
        #expect(await wire.commands.isEmpty)
        #expect(await gate.queuedOperationCount == 0)
        var states=await service.states().makeAsyncIterator()
        #expect(await states.next() == .disconnected)
    }
    @Test func queuedCancellationDoesNotCloseActiveOwnerAndDisconnectStopsNewCommands() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,holdOpcode:0x900D),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let gate=SerialCameraGate(),service=makeService(wire,journal,gate:gate)
        try await service.connect()
        let first=Task { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        await wire.waitUntilHeld()
        let queued=Task { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        // Gate counter gives an observable ordering point without a wall-clock delay.
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        queued.cancel()
        await #expect(throws:(any Error).self) { try await queued.value }
        #expect(await wire.closes == 0)
        let disconnect=Task { await service.disconnect() }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        await wire.release()
        await #expect(throws:CameraServiceError.self) { try await first.value }
        await disconnect.value
        #expect(await wire.triggers == 0);#expect(await wire.closes == 1)
        #expect(await wire.commands.allSatisfy { $0.parameters != [0xD185] })
    }
    @Test func activeCancellationAndCloseFailureStayDistinctFromQueuedCancellation() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.closeFails,holdOpcode:0x900D),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        let task=Task { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        await wire.waitUntilHeld();task.cancel();await wire.release()
        await #expect(throws:CameraServiceError.self) { try await task.value }
        #expect(await wire.triggers == 0);#expect(await wire.closes == 1)
        #expect(try journal.unresolved().first?.closure == "unconfirmed")
        await #expect(throws:CameraServiceError.self) { try await service.connect() }
    }
    @Test func freshEmptyViewReconcilesMissingWithoutReplayingOldOutput() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.deleteRejected),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let first=makeService(wire,journal);try await first.connect()
        await #expect(throws:CameraServiceError.self) { try await first.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        let old=try #require(journal.unresolved().first)
        await wire.simulatePhysicalReconnect(empty:true)
        let resumed=makeService(wire,try CameraOperationJournal(directory:journal.directory, filePolicy: IOSCameraJournalFilePolicy()))
        try await resumed.connect()
        #expect(try journal.load(old.id).phase == .reconciledMissing)
        #expect(try journal.load(old.id).deleteAcknowledged == false)
        #expect(await wire.triggers == 1);#expect(await wire.deletes == [77])
        let result=try await resumed.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
        #expect(result.operationID != old.id && result.cameraContext != old.context)
        #expect(FileManager.default.fileExists(atPath:journal.operationDirectory(old.id).appendingPathComponent("output.JPG").path))
        await resumed.disconnect()
    }
    @Test func refreshedCurrentSlotDoesNotReplaceFrozenRequestOrItsProvenance() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        let refreshed=try await service.importRecipes().recipes
        let current=try #require(refreshed.first { $0.slot == 7 })
        #expect(current.settingsDigest != f.profile.bank.settingsDigest)
        #expect(current.renderingIssues.isEmpty)
        try current.requireRenderable(using: RecipeCodecRegistry())
        let rendered=try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
        #expect(rendered.recipeSnapshotID == f.profile.bank.id)
        #expect(rendered.effectiveRecipe.requested.film == .classicChrome)
        #expect(await wire.profile?[541] == 11)
        await service.disconnect()
    }
    @Test func perCommandBusyAndLateTerminalEventsDoNotEraseVerifiedContext() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        await wire.emit(.disconnected) // Stale terminal event while the current session is still valid.
        _ = try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
        var states=await service.states().makeAsyncIterator()
        if case .ready = await states.next() {} else { Issue.record("Wire sessionOpen must not replace verified ready") }
        await wire.simulateUnplug()
        var terminal=false
        while let state=await states.next() { if case .disconnected = state { terminal=true;break } }
        #expect(terminal)
        await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        await service.disconnect()
    }
    private func makeService(_ wire:ProductionSession,_ journal:CameraOperationJournal,gate:SerialCameraGate=SerialCameraGate())->FujiCameraService {
        FujiCameraService(session:wire,journal:journal,gate:gate,pollWait:{},settle:{ _ in },registry:FujiCameraRegistry(adapters:[XT5Adapter(validateJPEG:{ _,m in
            ValidatedJPEGMetadata(width:m.recordedGeometry.width,height:m.recordedGeometry.height,orientation:m.orientation,make:"FUJIFILM",model:"X-T5",quality:.fine,lensOptimizer:true)
        })]))
    }
}

actor ProductionSession: CameraSessionTransport {
    enum Mode { case normal,preexisting,profileRejected,readbackMismatch,wrongStorage,replacedHandle,payloadChanged,deleteRejected,nonemptyAfterDelete,staleAfterTrigger,triggerRejected,closeFails }
    let fixture:ProductionOperationFixture,holdOpcode:UInt16?
    let holdStates:Bool
    var mode:Mode
    var selected:UInt16=1,outputPresent=false
    var commands:[PTPCommand]=[],deletes:[UInt32]=[],uploadHashes:[String]=[]
    var connects=0,closes=0,triggers=0,generation:UInt64=1,connected=false
    var profile:Data?,deleted=false,downloadCount=0,views=0
    var held:CheckedContinuation<Void,Never>?,heldWaiters:[CheckedContinuation<Void,Never>]=[]
    var subscribers:[AsyncStream<CameraState>.Continuation]=[]
    init(fixture:ProductionOperationFixture,mode:Mode = .normal,holdOpcode:UInt16?=nil,holdStates:Bool=false) { self.fixture=fixture;self.mode=mode;self.holdOpcode=holdOpcode;self.holdStates=holdStates }
    func states() async ->AsyncStream<CameraState> {
        if holdStates { await withCheckedContinuation { held=$0;heldWaiters.forEach { $0.resume() };heldWaiters=[] } }
        let pair=AsyncStream<CameraState>.makeStream();subscribers.append(pair.continuation);return pair.stream }
    func connect() throws { connects += 1;if mode == .closeFails && closes > 0 { throw PTPError.sessionClosing };connected=true;emit(.sessionOpen(snapshot())) }
    func currentSession() throws -> CameraSession { guard connected else { throw PTPError.notConnected };return snapshot() }
    private var closeBarrier: FixtureBarrier?
    private(set) var closeEntered = false
    func holdClose(_ barrier: FixtureBarrier) { closeBarrier = barrier }
    func close() async throws { closeEntered = true;if let closeBarrier { await closeBarrier.wait() };closes += 1;connected=false;emit(.disconnected);if mode == .closeFails { throw PTPError.timeout } }
    func snapshot()->CameraSession { .init(generation:generation,connection:.init(name:"Synthetic",usbVendorID:0x04cb,usbProductID:0x2fc)) }
    func emit(_ state:CameraState) { subscribers.forEach { $0.yield(state) } }
    func simulatePhysicalReconnect(empty:Bool) { connected=false;generation += 1;outputPresent = !empty;mode = .normal }
    func simulateUnplug() { connected=false;emit(.disconnected) }
    func waitUntilHeld() async { if held != nil { return };await withCheckedContinuation { heldWaiters.append($0) } }
    func release() { held?.resume();held=nil }
    func execute(_ command:PTPCommand,data:Data?) async throws -> PTPReply {
        commands.append(command);emit(.busy(snapshot()))
        if command.opcode == holdOpcode { await withCheckedContinuation { held=$0;heldWaiters.forEach { $0.resume() };heldWaiters=[] } }
        let bytes:Data
        switch (command.opcode,command.parameters) {
        case (0x1001,[]): bytes=ProtocolProbeFixtures.deviceInfo(properties:[0xD16E,0xD183,0xD185,0xD186,0xD187,0xD18C,0xD18D]+Array(0xD18E...0xD1A4),operations:[0x1001,0x1005,0x1007,0x1008,0x1009,0x100B,0x1015,0x1016,0x900C,0x900D],firmware:"4.31")
        case (0x1015,[0xD16E]): bytes=Data([6,0])
        case (0x1015,[0xD186]),(0x1015,[0xD187]): bytes=ProtocolProbeFixtures.string("X-T5_0200")
        case (0x900C,[0,0,0]): bytes=Data()
        case (0x900D,[]): uploadHashes.append(XT5WorkingProfile.hash(data!));profile=nil;downloadCount=0;bytes=Data()
        case (0x1015,[0xD185]):
            var value=profile ?? fixture.profile.baseline
            if mode == .readbackMismatch && profile != nil { value[541] ^= 1 };bytes=value
        case (0x1016,[0xD185]): if mode == .profileRejected { throw PTPError.responseCode(0x2002) };profile=data;bytes=Data()
        case (0x1016,[0xD183]):
            triggers += 1;if mode == .triggerRejected { throw PTPError.responseCode(0x2002) }
            outputPresent=true;deleted=false
            if mode == .staleAfterTrigger { generation += 1 };bytes=Data()
        case (0x1007,[UInt32.max,0,0]):
            views += 1
            let handles:[UInt32]=mode == .preexisting ? [99] : !outputPresent ? [] : [mode == .replacedHandle && views > 3 ? 88 : 77]
            bytes=ObjectObservationFixture.word(UInt32(handles.count))+handles.reduce(Data()) { $0+ObjectObservationFixture.word($1) }
        case (0x1008,[77]):
            var info=ObjectObservationFixture.info(byteCount:4);info.replaceSubrange(26..<34,with:Data(repeating:0,count:8));info.replaceSubrange(42..<44,with:ProtocolProbeFixtures.word(2055));bytes=info
        case (0x1005,[0x10001]): var storage=ObjectObservationFixture.storage();storage[0]=mode == .wrongStorage ? 4 : 3;storage[4]=2;bytes=storage
        case (0x1009,[77]): downloadCount += 1;bytes=mode == .payloadChanged && downloadCount > 1 ? Data([4,3,2,1]) : Data([1,2,3,4])
        case (0x100B,[77,0]): deletes.append(77);if mode == .deleteRejected { throw PTPError.responseCode(0x2002) };deleted=true;outputPresent = mode == .nonemptyAfterDelete;bytes=Data()
        case (0x1015,[0xD18C]): bytes=ProtocolProbeFixtures.word(selected)
        case (0x1016,[0xD18C]): selected=UInt16(data![0]) | UInt16(data![1])<<8;bytes=Data()
        case (0x1015,[0xD18D]): bytes=ProtocolProbeFixtures.string("Current synthetic bank")
        case (0x1015,let parameters) where parameters.count == 1 && (0xD18E...0xD1A4).contains(parameters[0]):
            let code=UInt16(parameters[0]);bytes=ProtocolProbeFixtures.word(code == 0xD192 ? 1 : fixture.profile.properties[code]!)
        default: throw PTPError.invalidParameters

        }
        emit(.sessionOpen(snapshot()))
        return PTPReply(opcode:command.opcode,parameters:[],logicalTransactionID:command.transactionID,wireTransactionID:command.transactionID+9,correlation:.imageCaptureCoreCallback(echoedCommand:command),responseCode:0x2001,rawResponse:Data(),data:bytes)
    }
}
