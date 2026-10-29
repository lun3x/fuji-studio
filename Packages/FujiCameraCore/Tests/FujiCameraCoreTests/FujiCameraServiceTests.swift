@testable import FujiCameraCore
import Foundation
import Testing

struct FujiCameraServiceTests {
    @Test func renderAcceptsBothObservedXT5OutputAssociations() async throws {
        for mode in [ProductionSession.Mode.normal, .outputAssociationSeven] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode)
            let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            let jpeg=try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
            let record=try journal.load(jpeg.operationID)
            let info=try FujiConversionCodec.objectInfo(#require(record.objectInfo))
            #expect(info.associationType == (mode == .normal ? 0x0807 : 0x0007))
            #expect(record.outputValidated && record.emptyViewVerified && record.phase == .completed)
            #expect(await wire.closes == 0);#expect(await wire.deletes == [77])
            await service.disconnect()
        }
    }
    @Test func importFailureReportsRestorationWithoutPretendingStorageFailed() {
        var evidence=XT5BankImportEvidence();evidence.restoration = .unconfirmed
        #expect(XT5Adapter.importFailure(XT5BankImportFailure(evidence:evidence)) == .recipeImportFailed(restorationConfirmed:false))
        evidence.restoration = .verified
        #expect(XT5Adapter.importFailure(XT5BankImportFailure(evidence:evidence)) == .recipeImportFailed(restorationConfirmed:true))
    }
    @Test func renderUsesFrozenRecipeFreshBaselineAndReturnsOnlyAfterOwnedCleanup() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            if mode == .normal { try Data([0]).write(to:f.raw.fileURL) }
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.commands.allSatisfy { ![0x900C,0x900D,0x100B].contains($0.opcode) })
            await service.disconnect()
        }
    }
    @Test func profileRefusalNeverTriggersAndRetainsTheSessionForAttention() async throws {
        for mode in [ProductionSession.Mode.profileRejected,.readbackMismatch] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.triggers == 0);#expect(await wire.deletes.isEmpty)
            #expect(await wire.closes == 0)
            #expect(try journal.unresolved().isEmpty)
            await service.disconnect()
            #expect(await wire.closes == 1)
        }
    }
    @Test func unsafeOutputOrUncertainCleanupPinsJournalAndNeverReplays() async throws {
        for mode in [ProductionSession.Mode.wrongStorage,.replacedHandle,.payloadChanged,.deleteRejected,.nonemptyAfterDelete,.staleAfterTrigger,.triggerRejected] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            let pending=try journal.unresolved();#expect(pending.count == 1)
            let deletes=await wire.deletes
            #expect(deletes.count <= 1)
            if [.wrongStorage,.replacedHandle,.payloadChanged,.staleAfterTrigger,.triggerRejected].contains(mode) { #expect(deletes.isEmpty) }
            let reopened=makeService(wire,try CameraOperationJournal(directory:journal.directory, filePolicy: TestJournalFilePolicy()))
            if mode == .triggerRejected { try await reopened.connect();await reopened.disconnect() }
            else { await #expect(throws:CameraServiceError.self) { try await reopened.connect() } }
            #expect(await wire.deletes == deletes)
            if [.deleteRejected,.nonemptyAfterDelete].contains(mode) {
                #expect(pending.first?.outputValidated == true)
                #expect(FileManager.default.fileExists(atPath:journal.operationDirectory(pending[0].id).appendingPathComponent("output.JPG").path))
            }
        }
    }
    @Test func rejectedMetadataIsRetainedWithoutDownloadingOrDeletingOutput() async throws {
        for mode in [ProductionSession.Mode.wrongOutputFormat, .malformedOutputInfo, .oversizedOutputInfo, .wrongStorage, .unexpectedOutputAssociation] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode)
            let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            let context=try await service.executionContext()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            let record=try #require(journal.unresolved().first)
            #expect(record.phase == .uncertain && record.closure == "notRequested")
            #expect(!record.outputValidated && !record.deleteIntent)
            let object=try #require(record.objectInfo)
            switch mode {
            case .wrongOutputFormat: #expect(try FujiConversionCodec.objectInfo(object).format == 0x3802)
            case .malformedOutputInfo: #expect(object == Data([1,2]))
            case .oversizedOutputInfo: #expect(object == Data(repeating:0,count:4096))
            case .unexpectedOutputAssociation: #expect(try FujiConversionCodec.objectInfo(object).associationType == 9)
            case .wrongStorage:
                let storage=try #require(record.storageInfo)
                #expect(try FujiConversionCodec.storageInfo(storage).storageType == 4)
            default: Issue.record("Unexpected fixture mode")
            }
            #expect(await wire.commands.allSatisfy { ![0x1009,0x100B].contains($0.opcode) })
            #expect(await wire.triggers == 1)
            #expect(await wire.closes == 0)
            #expect(try await service.executionContext() == context)
            let commands=await wire.commands
            await #expect(throws:CameraServiceError.self) { try await service.connect() }
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.commands == commands)
            #expect(await wire.triggers == 1)
            await service.disconnect()
            #expect(await wire.closes == 1)
        }
    }
    @Test func explicitResetDiscardsOnlyOwnedTemporaryOutputAndAllowsAnotherRender() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.wrongOutputFormat)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        let original=try await service.executionContext()
        await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        let failed=try #require(journal.unresolved().first)
        var states=await service.states().makeAsyncIterator()
        guard case .attentionRequired(_, let message) = await states.next() else { Issue.record("Expected connected error");return }
        #expect(message.contains("unexpected image format"))
        await wire.setMode(.normal)
        try await service.resetConnection()
        #expect(try await service.executionContext() != original)
        #expect(await wire.closes == 1);#expect(await wire.connects == 2)
        #expect(await wire.deletes == [77]);#expect(await wire.triggers == 1)
        let discarded=try journal.load(failed.id)
        #expect(discarded.phase == .aborted && discarded.emptyViewVerified && discarded.deleteAcknowledged)
        #expect(!discarded.outputValidated && discarded.result == nil)
        #expect(discarded.objectInfo == failed.objectInfo)
        #expect(discarded.discardObjectInfo != nil && discarded.discardOutputSHA256 != nil)
        #expect(try journal.unresolved().isEmpty)
        _ = try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry)
        #expect(await wire.triggers == 2)
        await service.disconnect()
    }
    @Test func explicitResetRefusesUnsafeObjectsAndNeverReplaysUncertainDeletion() async throws {
        for mode in [ProductionSession.Mode.wrongStorage, .replacedHandle, .payloadChanged, .deleteRejected] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:.wrongOutputFormat)
            let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            let context=try await service.executionContext()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            await wire.setMode(mode)
            await #expect(throws:CameraServiceError.self) { try await service.resetConnection() }
            let deletes=await wire.deletes
            #expect(deletes == (mode == .deleteRejected ? [77] : []))
            #expect(await wire.closes == 1)
            #expect(try await service.executionContext() != context)
            await #expect(throws:CameraServiceError.self) { try await service.resetConnection() }
            #expect(await wire.deletes == deletes);#expect(await wire.triggers == 1)
            await service.disconnect()
        }
    }
    @Test func resetReconcilesMissingOutputWithoutReplayingAnOldTrigger() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.wrongOutputFormat)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        let failed=try #require(journal.unresolved().first)
        await wire.clearOutput()
        try await service.resetConnection()
        #expect(try journal.load(failed.id).phase == .reconciledMissing)
        #expect(await wire.triggers == 1);#expect(await wire.deletes.isEmpty)
        await service.disconnect()
    }
    @Test func resetAttemptsNativeReopenWhenRejectedMetadataPersists() async throws {
        for mode in [ProductionSession.Mode.wrongOutputFormat, .malformedOutputInfo, .oversizedOutputInfo] {
            for clears in [false, true] {
                let f=try ProductionOperationFixture();defer { f.remove() }
                let wire=ProductionSession(fixture:f,mode:mode)
                let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
                let service=makeService(wire,journal);try await service.connect()
                await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
                let failed=try #require(journal.unresolved().first)
                await wire.clearOutputWhenClosed(clears)
                if clears { try await service.resetConnection() }
                else { await #expect(throws:CameraServiceError.self) { try await service.resetConnection() } }
                #expect(await wire.closes == 1);#expect(await wire.connects == 2)
                #expect(await wire.deletes.isEmpty);#expect(await wire.triggers == 1)
                let record=try journal.load(failed.id)
                #expect(record.objectInfo == failed.objectInfo && !record.deleteIntent)
                #expect(record.phase == (clears ? .reconciledMissing : .uncertain))
                var states=await service.states().makeAsyncIterator()
                if clears {
                    guard case .ready = await states.next() else { Issue.record("Fresh empty reset must become ready");return }
                } else {
                    guard case .attentionRequired = await states.next() else { Issue.record("Unresolved reset must remain in error");return }
                }
                await service.disconnect()
            }
        }
    }
    @Test func invalidHandleMetadataRetainsTheSession() async throws {
        for mode in [ProductionSession.Mode.duplicateOutputHandles, .zeroOutputHandle] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f,mode:mode)
            let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
            let service=makeService(wire,journal);try await service.connect()
            let context=try await service.executionContext()
            await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
            #expect(await wire.closes == 0)
            #expect(try await service.executionContext() == context)
            var states=await service.states().makeAsyncIterator()
            guard case .attentionRequired(_, let message) = await states.next() else { Issue.record("Invalid handle metadata must retain a connected error");return }
            #expect(message.contains("list"))
            await service.disconnect()
        }
    }
    @Test func cancelledResetCannotStrandAReadySession() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let gate=SerialCameraGate(),service=makeService(wire,journal,gate:gate)
        try await service.connect();let original=try await service.executionContext()
        let cancelled=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws:CameraServiceError.cancelled) { try await service.resetConnection() }
        }
        await cancelled.value
        #expect(try await service.executionContext() == original)
        #expect(await wire.closes == 0)
        let barrier=FixtureBarrier()
        let holder=Task { try await gate.withExclusiveAccess { await barrier.wait() } }
        await barrier.entered()
        let reset=Task { try await service.resetConnection() }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        reset.cancel()
        await barrier.release();_ = try await holder.value
        try await reset.value
        #expect(try await service.executionContext() != original)
        #expect(await wire.closes == 1);#expect(await wire.connects == 2)
        await service.disconnect()
    }
    @Test func resetNeverReportsReadyWhileUnknownObjectsRemain() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.preexisting)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        #expect(try journal.unresolved().isEmpty)
        await #expect(throws:CameraServiceError.self) { try await service.resetConnection() }
        #expect(await wire.closes == 1);#expect(await wire.connects == 2)
        #expect(await wire.deletes.isEmpty);#expect(await wire.triggers == 0)
        var states=await service.states().makeAsyncIterator()
        guard case .attentionRequired = await states.next() else { Issue.record("Unknown output must remain blocked");return }
        await service.disconnect()
    }
    @Test func resetCanSettleAPreviouslyUnconfirmedNativeClose() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f,mode:.wrongOutputFormat)
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let service=makeService(wire,journal);try await service.connect()
        await #expect(throws:CameraServiceError.self) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        await wire.setMode(.closeFails)
        await #expect(throws:CameraServiceError.closeUnconfirmed) { try await service.resetConnection() }
        await wire.setMode(.normal)
        try await service.resetConnection()
        #expect(await wire.connects == 2);#expect(await wire.closes == 2)
        #expect(await wire.deletes == [77]);#expect(await wire.triggers == 1)
        await service.disconnect()
    }
    @Test func invalidFineOrMissingLMOCannotProduceCameraJPEGOrDelete() async throws {
        for missing in [false,true] {
            let f=try ProductionOperationFixture();defer { f.remove() }
            let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
        let journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
        let wire=ProductionSession(fixture:f,holdOpcode:0x900D),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
        let wire=ProductionSession(fixture:f,mode:.closeFails,holdOpcode:0x900D),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
        let wire=ProductionSession(fixture:f,mode:.deleteRejected),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let first=makeService(wire,journal);try await first.connect()
        await #expect(throws:CameraServiceError.self) { try await first.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        let old=try #require(journal.unresolved().first)
        await wire.simulatePhysicalReconnect(empty:true)
        let resumed=makeService(wire,try CameraOperationJournal(directory:journal.directory, filePolicy: TestJournalFilePolicy()))
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
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
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
    enum Mode { case normal,preexisting,profileRejected,readbackMismatch,wrongStorage,replacedHandle,payloadChanged,deleteRejected,nonemptyAfterDelete,staleAfterTrigger,triggerRejected,closeFails,wrongOutputFormat,malformedOutputInfo,oversizedOutputInfo,duplicateOutputHandles,zeroOutputHandle,outputAssociationSeven,unexpectedOutputAssociation }
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
    private var clearsOutputOnClose = false
    private(set) var closeEntered = false
    func holdClose(_ barrier: FixtureBarrier) { closeBarrier = barrier }
    func close() async throws { closeEntered = true;if let closeBarrier { await closeBarrier.wait() };closes += 1;connected=false;if clearsOutputOnClose { outputPresent=false };emit(.disconnected);if mode == .closeFails { throw PTPError.timeout } }
    func clearOutputWhenClosed(_ clears: Bool) { clearsOutputOnClose=clears }
    func snapshot()->CameraSession { .init(generation:generation,connection:.init(name:"Synthetic",usbVendorID:0x04cb,usbProductID:0x2fc)) }
    func emit(_ state:CameraState) { subscribers.forEach { $0.yield(state) } }
    func simulatePhysicalReconnect(empty:Bool) { connected=false;generation += 1;outputPresent = !empty;mode = .normal }
    func simulateUnplug() { connected=false;emit(.disconnected) }
    func waitUntilHeld() async { if held != nil { return };await withCheckedContinuation { heldWaiters.append($0) } }
    func release() { held?.resume();held=nil }
    func setMode(_ next: Mode) { mode=next;downloadCount=0 }
    func clearOutput() { outputPresent=false;mode = .normal }
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
            let handles:[UInt32]=mode == .preexisting ? [99] : !outputPresent ? [] : mode == .duplicateOutputHandles ? [77,77] : mode == .zeroOutputHandle ? [0] : [mode == .replacedHandle && views > 3 ? 88 : 77]
            bytes=ObjectObservationFixture.word(UInt32(handles.count))+handles.reduce(Data()) { $0+ObjectObservationFixture.word($1) }
        case (0x1008,[77]):
            var info=ObjectObservationFixture.info(byteCount:4);info.replaceSubrange(26..<34,with:Data(repeating:0,count:8));info.replaceSubrange(42..<44,with:ProtocolProbeFixtures.word(2055))
            if mode == .wrongOutputFormat { info[4]=2 }
            if mode == .malformedOutputInfo { info=Data([1,2]) }
            if mode == .oversizedOutputInfo { info=Data(repeating:0,count:4097) }
            if mode == .outputAssociationSeven { info.replaceSubrange(42..<44,with:Data([7,0])) }
            if mode == .unexpectedOutputAssociation { info.replaceSubrange(42..<44,with:Data([9,0])) }
            bytes=info
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

extension FujiCameraServiceTests {
    @Test(arguments: [true, false])
    func xt5LensOptimizerAdjustmentCompletesWithoutDisconnecting(_ effective: Bool) async throws {
        let f = try ProductionOperationFixture(); defer { f.remove() }
        let wire = ProductionSession(fixture: f)
        let journal = try CameraOperationJournal(directory: f.directory.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
        let adapter = XT5Adapter(validateJPEG: { _, m in
            ValidatedJPEGMetadata(width: m.recordedGeometry.width, height: m.recordedGeometry.height, orientation: m.orientation, make: "FUJIFILM", model: "X-T5", quality: .fine, lensOptimizer: effective)
        })
        let service = FujiCameraService(session: wire, journal: journal, pollWait: {}, registry: FujiCameraRegistry(adapters: [adapter]))
        try await service.connect()
        let context = try await service.executionContext()
        let result = try await service.render(raw: f.raw, recipe: f.profile.bank, policy: .fullSizeFineRecordedGeometry)
        #expect(result.effectiveRecipe.lensOptimizerRequested)
        #expect(result.effectiveRecipe.lensOptimizerEffective == effective)
        #expect(result.effectiveRecipe.lensOptimizerAdjusted == !effective)
        #expect(result.effectiveRecipe.evidenceBySetting?[.lensOptimizer] == .jpegObserved)
        let record = try journal.load(result.operationID)
        #expect(record.phase == .completed && record.emptyViewVerified && record.recipeMismatch == nil)
        #expect(try await service.executionContext() == context)
        var states = await service.states().makeAsyncIterator()
        if case .ready = await states.next() {} else { Issue.record("Successful conversion must keep the camera ready") }
        #expect(await wire.closes == 0)
        #expect(await wire.triggers == 1)
        #expect(await wire.deletes == [77])
        await service.disconnect()
    }
    @Test func expiredImportIOCannotSend() async throws {
        let counter=IOCommandCounter()
        let io=CameraOperationIO(temporarySelector:nil) { opcode,parameters,data in
            await counter.sent()
            return ioReply(Data([6,0]))
        }
        #expect(try await io.readProperty(0xD16E) == Data([6,0]))
        await io.finish()
        await #expect(throws:CameraServiceError.cancelled) { try await io.readProperty(0xD16E) }
        #expect(await counter.count == 1)
    }
    @Test func oldContextCannotReadLiveCapabilities() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"),filePolicy:TestJournalFilePolicy())
        let service=makeService(wire,journal)
        try await service.connect();let old=try await service.executionContext()
        #expect(try await service.support(for:old).model == "X-T5")
        await service.disconnect();try await service.connect()
        await #expect(throws:CameraServiceError.self) { try await service.support(for:old) }
        await service.disconnect()
    }
    @Test func verifiedMismatchCleansOnceWithoutPublishing() async throws {
        let f=try ProductionOperationFixture();defer { f.remove() }
        let wire=ProductionSession(fixture:f),journal=try CameraOperationJournal(directory:f.directory.appendingPathComponent("journal"),filePolicy:TestJournalFilePolicy())
        let adapter=XT5Adapter(validateJPEG:{ _,m in ValidatedJPEGMetadata(width:m.recordedGeometry.width,height:m.recordedGeometry.height,orientation:m.orientation,make:"FUJIFILM",model:"X-T5",quality:.fine,lensOptimizer:false,rendering:[.film:.film(.velvia)]) })
        let service=FujiCameraService(session:wire,journal:journal,pollWait:{},registry:FujiCameraRegistry(adapters:[adapter]))
        try await service.connect()
        await #expect(throws:CameraServiceError.invalidOutput) { try await service.render(raw:f.raw,recipe:f.profile.bank,policy:.fullSizeFineRecordedGeometry) }
        #expect(await wire.deletes == [77])
        #expect(try journal.unresolved().isEmpty)
        #expect(await wire.closes == 0)
        try await service.resetConnection()
        #expect(await wire.triggers == 1)
        #expect(await wire.deletes == [77])
        await service.disconnect()
    }
    @Test func registryNeverGuessesUnknownModelFromManufacturer() throws {
        let info=try PTPDatasets.deviceInfo(ProtocolProbeFixtures.deviceInfo(model:"X-UNKNOWN"))
        #expect(throws:CameraServiceError.unsupportedContext) { try FujiCameraRegistry().adapter(for:info) }
    }
}
actor IOCommandCounter {
    var count=0
    func sent() { count += 1 }
}

extension FujiCameraServiceTests {
    @Test func borrowedIOCanWriteOnlyDeclaredTemporarySelector() async throws {
        let counter=IOCommandCounter()
        let io=CameraOperationIO(temporarySelector:.init(property:0xD18C,slots:[2])) { _,_,_ in await counter.sent();return ioReply(Data()) }
        let bridge=try await io.temporarySelectorTransport()
        for (opcode,parameters,data):(UInt16,[UInt32],Data?) in [(0x1016,[0xD18C],Data([1,0])),(0x1016,[0xD16E],Data([6,0])),(0x100B,[77,0],nil)] {
            await #expect(throws:CameraServiceError.unsupportedContext) { try await bridge.execute(PTPCommand(opcode:opcode,parameters:parameters,transactionID:1),data:data) }
        }
        #expect(await counter.count == 0)
        _ = try await bridge.execute(PTPCommand(opcode:0x1016,parameters:[0xD18C],transactionID:2),data:Data([2,0]))
        #expect(await counter.count == 1)
        await io.finish()
    }
}

extension FujiCameraServiceTests {
    @Test func importerBridgePreservesNativeCorrelationEvidence() async throws {
        let raw=Data([12,0,0,0,3,0,1,32,99,0,0,0])
        let command=PTPCommand(opcode:0x1015,parameters:[0xD18C],transactionID:7)
        let reply=try PTPCodec.decodeFrameworkManaged(response:raw,data:Data([2,0]),for:command,echoedCommand:command)
        let io=CameraOperationIO(temporarySelector:.init(property:0xD18C,slots:[2])) { _,_,_ in reply }
        let bridge=try await io.temporarySelectorTransport()
        let observed=try await bridge.execute(command,data:nil)
        #expect(observed.rawResponse == raw)
        #expect(observed.wireTransactionID == 99 && observed.logicalTransactionID == 7)
        #expect(observed.correlation == .imageCaptureCoreCallback(echoedCommand:command))
        await io.finish()
    }
}

private func ioReply(_ data:Data) -> PTPReply {
    .init(opcode:0x1015,parameters:[],logicalTransactionID:1,wireTransactionID:1,correlation:.directWireTransaction,responseCode:0x2001,rawResponse:Data([12,0,0,0,3,0,1,32,1,0,0,0]),data:data)
}
