import Foundation
import ImageCaptureCore
import Testing
@testable import FujiStudio

@MainActor struct ImageCaptureSessionDriverTests {
    @Test func lifecycleDiagnosticsObserveCachedDeviceAndCloseOrderingWithoutLoggingDeviceIdentity() {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue(); let camera = SessionTestCamera()
        browser.cachedDevices = [camera]
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        driver.start { _ in }; callbacks.drain()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        driver.close {}
        // Completion delivery is deliberately suspended: browser.stop has happened but close
        // acknowledgement has not reached the real driver. The cache still owns the device.
        let waiting = driver.lifecycleDiagnosticMessages().joined(separator: "\n")
        #expect(waiting.contains("browser.stop.after"))
        #expect(waiting.contains("cached=1"))
        #expect(waiting.contains("browsing=false"))
        #expect(waiting.contains("closing=true"))
        #expect(!waiting.contains("close.completion"))
        callbacks.drain()
        let completed = driver.lifecycleDiagnosticMessages().joined(separator: "\n")
        #expect(completed.contains("close.completion current=true errorCode=none"))
        #expect(completed.contains("close.finished"))
        #expect(completed.contains("browser=none"))
        #expect(!completed.contains("PRIVATE_DEVICE_NAME"))
    }

    @Test func lifecycleSnapshotShowsReplacementBrowserCacheEvenWithoutAddedCallback() {
        let first = SessionTestBrowser(); let second = SessionTestBrowser(); var browsers = [first, second]
        let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browsers.removeFirst() }, deliverCompletion: { callbacks.enqueue($0) })
        driver.start { _ in }; callbacks.drain()
        driver.close {}; callbacks.drain()
        driver.start { _ in }; callbacks.drain()
        // Public devices can now be observed separately from delegate delivery. Do not invent
        // a didAdd event: the diagnostic must reveal the difference during the native stall.
        second.cachedDevices = [SessionTestCamera()]
        second.suspensionFlag = true
        let snapshot = driver.lifecycleDiagnosticMessages().last ?? ""
        #expect(snapshot.contains("browser=2"))
        #expect(snapshot.contains("cached=1"))
        #expect(snapshot.contains("usbPTP=1"))
        #expect(snapshot.contains("suspended=true"))
        #expect(snapshot.contains("camera=false"))
        driver.close {}; callbacks.drain()
    }

    @Test func lifecycleDiagnosticsRemainBoundedAcrossRepeatedSnapshots() {
        let fixture = openNativeDriver()
        for _ in 0..<100 { _ = fixture.driver.lifecycleDiagnosticMessages() }
        let messages = fixture.driver.lifecycleDiagnosticMessages()
        #expect(messages.count == 64)
        #expect(messages.allSatisfy { $0.count <= 512 })
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func discoveryConfiguresLocalCamerasAtPublicBrowserBoundary() {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        driver.start { _ in }
        callbacks.drain()
        #expect(browser.didStart)
        // Independently derived SDK bits: camera 0x001 + local USB/FireWire 0x100.
        #expect(browser.configuredMask?.rawValue == 0x101)
        var closed = false
        driver.close { closed = true }
        #expect(closed)
    }

    @Test func removalBeforeOpenCompletionClosesAndReconnectsWithoutThatCompletion() {
        let firstBrowser = SessionTestBrowser(); let secondBrowser = SessionTestBrowser()
        var browsers = [firstBrowser, secondBrowser]
        let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browsers.removeFirst() }, deliverCompletion: { callbacks.enqueue($0) })
        let firstCamera = SessionTestCamera()
        var recorded: [CameraDriverEvent] = []
        var closeCompleted = false
        driver.start { event in
            recorded.append(event)
            if case .removed = event { driver.close { closeCompleted = true } }
        }
        callbacks.drain()
        driver.deviceBrowser(firstBrowser, didAdd: firstCamera, moreComing: false)
        #expect(firstCamera.pendingOpenCount == 1)
        // No open completion has run, and none is needed to retire a confirmed detached run.
        driver.didRemove(firstCamera)
        #expect(closeCompleted)
        #expect(firstCamera.closeRequestCount == 0)
        guard closeCompleted else { return }

        let secondCamera = SessionTestCamera()
        driver.start { recorded.append($0) }
        callbacks.drain()
        #expect(secondBrowser.didStart)
        driver.deviceBrowser(secondBrowser, didAdd: secondCamera, moreComing: false)
        secondCamera.completeOpen(error: nil)
        callbacks.drain()
        #expect(openedCount(recorded) == 1)
        #expect(failedCount(recorded) == 0)
        #expect(secondCamera.hasOpenSession)

        // Reconnection already succeeded without old completion. Now explicitly deliver both a late
        // success and error, and stale removal/delegate events, while the fresh session is alive.
        firstCamera.completeOpen(error: nil)
        firstCamera.completeOpen(error: NSError(domain: "fixture.oldOpen", code: 1))
        driver.didRemove(firstCamera)
        driver.device(firstCamera, didCloseSessionWithError: nil)
        callbacks.drain()
        #expect(openedCount(recorded) == 1)
        #expect(failedCount(recorded) == 0)
        #expect(secondCamera.closeRequestCount == 0)
        #expect(secondCamera.hasOpenSession)
        var replacementClosed = false
        driver.close { replacementClosed = true }
        #expect(!replacementClosed)
        callbacks.drain()
        #expect(replacementClosed)
    }

    @Test func removalWhileCloseWaitsForOpenIsTerminalWithoutOpenCallback() {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        let camera = SessionTestCamera()
        var opened = 0
        driver.start { if case .opened = $0 { opened += 1 } }
        callbacks.drain()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        var closed = false
        driver.close { closed = true }
        #expect(!closed)
        driver.didRemove(camera)
        #expect(closed)
        camera.completeOpen(error: nil)
        callbacks.drain()
        #expect(opened == 0)
        #expect(camera.closeRequestCount == 0)
    }

    @Test func alreadyAuthorizedGrantsNeverRepeatNativeRequests() {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        driver.start { _ in }
        callbacks.drain()
        #expect(browser.controlRequestCount == 0)
        #expect(browser.contentsRequestCount == 0)
        #expect(browser.didStart)
        driver.close {}
    }

    @Test func requestsOnlyMissingAuthorizationGrants() {
        let cases: [(ICAuthorizationStatus, ICAuthorizationStatus, Int, Int)] = [
            (.notDetermined, .authorized, 1, 0),
            (.authorized, .notDetermined, 0, 1),
            (.notDetermined, .notDetermined, 1, 1)
        ]
        for (control, contents, expectedControl, expectedContents) in cases {
            let browser = SessionTestBrowser(control: control, contents: contents); let callbacks = DriverCallbackQueue()
            let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
            driver.start { _ in }
            callbacks.drain()
            #expect(browser.controlRequestCount == expectedControl)
            #expect(browser.contentsRequestCount == expectedContents)
            #expect(browser.didStart)
            driver.close {}
        }
    }

    @Test func deniedOrRestrictedAuthorizationFailsWithoutRequestingOrBrowsing() {
        let cases: [(ICAuthorizationStatus, ICAuthorizationStatus)] = [
            (.denied, .authorized), (.restricted, .authorized),
            (.authorized, .denied), (.authorized, .restricted)
        ]
        for (control, contents) in cases {
            let browser = SessionTestBrowser(control: control, contents: contents); let callbacks = DriverCallbackQueue()
            let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
            var denied = 0
            driver.start { if case .failed(.authorizationDenied) = $0 { denied += 1 } }
            callbacks.drain()
            #expect(denied == 1)
            #expect(browser.controlRequestCount == 0)
            #expect(browser.contentsRequestCount == 0)
            #expect(!browser.didStart)
            driver.close {}
        }
    }

    @Test func permissionWaitDoesNotSpendUSBDeadlineAndSuccessStartsDiscovery() async throws {
        let browser = SessionTestBrowser(control: .notDetermined, contents: .notDetermined, automaticallyAuthorize: false)
        let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let pending = Task { try await transport.connect() }
        await browser.waitForControlRequest()
        #expect(clock.scheduledCount == 0)
        for _ in 0..<100 { clock.fireAll() } // Arbitrary virtual time passes while a person reads the notice.
        #expect(!browser.didStart)
        browser.completeControl(.authorized); callbacks.drain()
        #expect(browser.contentsRequestCount == 1)
        #expect(clock.scheduledCount == 0)
        for _ in 0..<100 { clock.fireAll() }
        browser.completeContents(.authorized); callbacks.drain()
        #expect(browser.didStart)
        #expect(clock.scheduledCount == 1)
        let camera = SessionTestCamera()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        try await pending.value
        #expect(clock.pendingCount == 0)
        await transport.disconnect(); callbacks.drain()
    }

    @Test func delayedDenialIsAuthorizationFailureWithoutUSBTimeout() async {
        for controlPending in [true, false] {
            for status: ICAuthorizationStatus in [.denied, .restricted] {
                let browser = SessionTestBrowser(control: controlPending ? .notDetermined : .authorized,
                                                 contents: controlPending ? .authorized : .notDetermined,
                                                 automaticallyAuthorize: false)
                let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
                let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
                let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
                let pending = Task { try await transport.connect() }
                if controlPending { await browser.waitForControlRequest() }
                else { await browser.waitForContentsRequest() }
                #expect(clock.pendingCount == 0)
                clock.fireAll()
                if controlPending { browser.completeControl(status) }
                else { browser.completeContents(status) }
                callbacks.drain()
                await #expect(throws: PTPError.authorizationDenied) { try await pending.value }
                #expect(!browser.didStart)
                #expect(clock.pendingCount == 0)
            }
        }
    }

    @Test func cancelledContentsPermissionCannotLaterStartDiscovery() async {
        let browser = SessionTestBrowser(contents: .notDetermined, automaticallyAuthorize: false)
        let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let pending = Task { try await transport.connect() }
        await browser.waitForContentsRequest()
        #expect(browser.controlRequestCount == 0)
        #expect(clock.scheduledCount == 0)
        for _ in 0..<100 { clock.fireAll() }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        browser.completeContents(.authorized); callbacks.drain()
        #expect(!browser.didStart)
        #expect(clock.pendingCount == 0)
    }

    @Test func cancelledPermissionWaitRejectsOldAuthorizationAndAllowsFreshConnect() async throws {
        let old = SessionTestBrowser(control: .notDetermined, automaticallyAuthorize: false)
        let fresh = SessionTestBrowser(); var browsers = [old, fresh]
        let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browsers.removeFirst() }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let cancelled = Task { try await transport.connect() }
        await old.waitForControlRequest()
        #expect(clock.scheduledCount == 0)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let replacement = Task { try await transport.connect() }
        await fresh.waitUntilBrowsing()
        old.completeControl(.authorized); callbacks.drain()
        #expect(!old.didStart)
        #expect(old.contentsRequestCount == 0)
        #expect(fresh.controlRequestCount == 0)
        #expect(fresh.contentsRequestCount == 0)
        let camera = SessionTestCamera()
        driver.deviceBrowser(fresh, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        try await replacement.value
        #expect(clock.pendingCount == 0)
        await transport.disconnect(); callbacks.drain()
    }

    @Test func discoveryTimeoutBeginsAfterGrantsAndStaleTimerCannotPoisonFreshSession() async throws {
        let old = SessionTestBrowser(control: .notDetermined, automaticallyAuthorize: false)
        let fresh = SessionTestBrowser(); var browsers = [old, fresh]
        let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browsers.removeFirst() }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let expired = Task { try await transport.connect() }
        await old.waitForControlRequest()
        #expect(clock.scheduledCount == 0)
        old.completeControl(.authorized); callbacks.drain()
        #expect(old.didStart)
        #expect(clock.pendingCount == 1)
        clock.fireAll()
        await #expect(throws: PTPError.timeout) { try await expired.value }
        let replacement = Task { try await transport.connect() }
        await fresh.waitUntilBrowsing()
        #expect(clock.pendingCount == 1)
        old.completeControl(.authorized); callbacks.drain()
        clock.replayScheduled(at: 0) // Even a cancelled/late scheduler callback carries the old attempt ID.
        let camera = SessionTestCamera()
        driver.deviceBrowser(fresh, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        try await replacement.value
        #expect(clock.pendingCount == 0)
        clock.replayScheduled(at: 0)
        await transport.disconnect(); callbacks.drain()
    }

    @Test func openingTimeoutAfterAuthorizationStaysQuarantinedUntilRemoval() async {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue(); let clock = ControlledCameraTimeouts()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: clock)
        let pending = Task { try await transport.connect() }
        await browser.waitUntilBrowsing()
        let camera = SessionTestCamera()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        #expect(camera.pendingOpenCount == 1)
        clock.fireAll()
        await #expect(throws: PTPError.timeout) { try await pending.value }
        await #expect(throws: PTPError.sessionClosing) { try await transport.connect() }
        driver.didRemove(camera)
        camera.completeOpen(error: nil); callbacks.drain()
        await #expect(throws: PTPError.notConnected) {
            try await transport.execute(PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1), data: nil)
        }
        await transport.disconnect(); callbacks.drain()
    }

    @Test func nativeChangedLogicalEchoIDIsRejectedEvenWhenResponseUsesSameID() throws {
        let fixture = openNativeDriver()
        var result: Result<PTPWireReply, PTPError>?
        fixture.driver.send(command: nativeCommand(1), data: nil) { result = $0 }
        #expect(fixture.camera.lastPTPUsedSelector)
        fixture.camera.completePTP(command: nativeCommand(7), response: nativeResponse(7))
        fixture.callbacks.drain()
        let completed = try #require(result)
        #expect(throws: PTPError.wrongTransaction(expected: 1, actual: 7)) { try completed.get() }
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func nativeCallbackOpcodeAndCommandIDMismatchCannotBecomeSuccess() throws {
        for callback in [nativeCommand(1, opcode: 0x04), nativeCommand(7)] {
            let fixture = openNativeDriver()
            var result: Result<PTPWireReply, PTPError>?
            fixture.driver.send(command: nativeCommand(1), data: nil) { result = $0 }
            fixture.camera.completePTP(command: callback, response: nativeResponse(1))
            fixture.callbacks.drain()
            let completed = try #require(result)
            #expect(throws: PTPError.self) { try completed.get() }
            fixture.driver.close {}; fixture.callbacks.drain()
        }
    }

    @Test func nativeCallbackRetainsFrameworkManagedResponseWithoutInventingExpectedWireID() throws {
        let fixture = openNativeDriver()
        var result: Result<PTPWireReply, PTPError>?
        fixture.driver.send(command: nativeCommand(1), data: nil) { result = $0 }
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9), data: Data([42]))
        fixture.callbacks.drain()
        let completed = try #require(result).get()
        #expect(completed.response == nativeResponse(9))
        #expect(completed.data == Data([42]))
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func actualNativeTransportAcceptsContextAssociatedLogical1Wire9() async throws {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue(); let camera = SessionTestCamera()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        let transport = ImageCaptureTransport(driver: driver, timeouts: ControlledCameraTimeouts())
        let opening = Task { try await transport.connect() }
        await browser.waitUntilBrowsing()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        try await opening.value
        let pending = Task { try await transport.execute(PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1), data: nil) }
        await camera.waitForPTPRequest()
        camera.completePTP(command: nativeCommand(1), response: nativeResponse(9), data: Data([42]))
        callbacks.drain()
        let reply = try await pending.value
        #expect(reply.data == Data([42]))
        #expect(reply.logicalTransactionID == 1)
        #expect(reply.wireTransactionID == 9)
        #expect(reply.rawResponse == nativeResponse(9))
        #expect(reply.correlation == .imageCaptureCoreCallback(echoedCommand: PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1)))
        await transport.disconnect(); callbacks.drain()
    }

    @Test func nativeMalformedAndNonSuccessResponsesRemainTypedFailures() throws {
        var length = nativeResponse(9); length[0] = 16
        var kind = nativeResponse(9); kind[4] = 2
        var failed = nativeResponse(9); failed[6] = 2
        let cases: [(Data, PTPError)] = [
            (Data(nativeResponse(9).prefix(11)), .truncatedContainer),
            (Data(repeating: 0, count: 36), .oversizedContainer),
            (length, .invalidContainerLength), (kind, .unexpectedContainerType(2)),
            (failed, .responseCode(0x2002))
        ]
        for (response, expected) in cases {
            let fixture = openNativeDriver(); var result: Result<PTPWireReply, PTPError>?
            fixture.driver.send(command: nativeCommand(1), data: nil) { result = $0 }
            fixture.camera.completePTP(command: nativeCommand(1), response: response)
            fixture.callbacks.drain()
            let completed = try #require(result)
            #expect(throws: expected) { try completed.get() }
            fixture.driver.close {}; fixture.callbacks.drain()
        }
    }

    @Test func nativeChangedParametersRejectBeforeFrameworkCorrelation() throws {
        let fixture = openNativeDriver(); var result: Result<PTPWireReply, PTPError>?
        let submitted = Data([16,0,0,0,1,0,0x15,0x10,1,0,0,0,0x85,0xd1,0,0])
        var changed = submitted; changed[12] = 0x86
        fixture.driver.send(command: submitted, data: nil) { result = $0 }
        fixture.camera.completePTP(command: changed, response: nativeResponse(9))
        fixture.callbacks.drain()
        let completed = try #require(result)
        #expect(throws: PTPError.callbackCommandMismatch) { try completed.get() }
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func wrongMissingAndDuplicateNativeContextsNeverResumeAnotherRequest() throws {
        let fixture = openNativeDriver(); var replies = 0
        fixture.driver.send(command: nativeCommand(1), data: nil) { _ in replies += 1 }
        let oldContext = try #require(fixture.camera.contextValue)
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9), context: .missing)
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9), context: .value(999))
        fixture.callbacks.drain()
        #expect(replies == 0)
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9)); fixture.callbacks.drain()
        #expect(replies == 1)
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9)); fixture.callbacks.drain()
        #expect(replies == 1)
        var fresh: Result<PTPWireReply, PTPError>?
        fixture.driver.send(command: nativeCommand(1), data: nil) { fresh = $0 }
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(9), data: Data([99]), context: .value(oldContext))
        fixture.callbacks.drain()
        #expect(fresh == nil)
        fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(11), data: Data([42]))
        fixture.callbacks.drain()
        #expect(try #require(fresh).get().data == Data([42]))
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func staleNativeContextCannotCompleteReplacementRequest() throws {
        let first = SessionTestBrowser(); let second = SessionTestBrowser(); var browsers = [first, second]
        let callbacks = DriverCallbackQueue()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browsers.removeFirst() }, deliverCompletion: { callbacks.enqueue($0) })
        let oldCamera = SessionTestCamera()
        driver.start { _ in }; callbacks.drain()
        driver.deviceBrowser(first, didAdd: oldCamera, moreComing: false)
        oldCamera.completeOpen(error: nil); callbacks.drain()
        var oldReplies = 0
        driver.send(command: nativeCommand(1), data: nil) { _ in oldReplies += 1 }
        driver.close {}; callbacks.drain()
        let freshCamera = SessionTestCamera()
        driver.start { _ in }; callbacks.drain()
        driver.deviceBrowser(second, didAdd: freshCamera, moreComing: false)
        freshCamera.completeOpen(error: nil); callbacks.drain()
        var freshReplies = 0
        driver.send(command: nativeCommand(1), data: nil) { _ in freshReplies += 1 }
        oldCamera.completePTP(command: nativeCommand(1), response: nativeResponse(1)); callbacks.drain()
        #expect(oldReplies == 0)
        #expect(freshReplies == 0)
        freshCamera.completePTP(command: nativeCommand(1), response: nativeResponse(1)); callbacks.drain()
        #expect(freshReplies == 1)
        driver.close {}; callbacks.drain()
    }

    @Test func getDeviceInfoDiagnosticsKeepIndependentHeadersOnRejection() throws {
        let fixture = openNativeDriver()
        fixture.driver.send(command: nativeCommand(1), data: nil) { _ in }
        fixture.camera.completePTP(command: nativeCommand(7), response: nativeResponse(7), data: Data("PRIVATE_SERIAL_NEVER_LOG".utf8))
        fixture.callbacks.drain()
        let text = fixture.driver.ptpDiagnostics.joined(separator: "\n")
        #expect(text.contains("type=1 code=0x1001 tx=1"))
        #expect(text.contains("type=1 code=0x1001 tx=7"))
        #expect(text.contains("type=3 code=0x2001 tx=7"))
        #expect(text.contains("wrongTransaction"))
        #expect(!text.contains("PRIVATE_SERIAL_NEVER_LOG"))
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    @Test func nativeDiagnosticsAreBoundedAndExcludeOtherOperationsAndPayloads() {
        let fixture = openNativeDriver()
        let secret = Data("PRIVATE_SERIAL_IMAGE_PAYLOAD_NEVER_LOG".utf8)
        for _ in 0..<20 {
            fixture.driver.send(command: nativeCommand(1), data: nil) { _ in }
            fixture.camera.completePTP(command: nativeCommand(1), response: nativeResponse(1), data: secret)
            fixture.callbacks.drain()
        }
        #expect(fixture.driver.ptpDiagnostics.count == 16)
        #expect(fixture.driver.ptpDiagnostics.allSatisfy { $0.count <= 1100 })
        let before = fixture.driver.ptpDiagnostics
        fixture.driver.send(command: nativeCommand(1, opcode: 0x09), data: nil) { _ in }
        fixture.camera.completePTP(command: nativeCommand(1, opcode: 0x09), response: nativeResponse(1), data: secret)
        fixture.callbacks.drain()
        #expect(fixture.driver.ptpDiagnostics == before)
        #expect(!before.joined().contains("PRIVATE_SERIAL_IMAGE_PAYLOAD_NEVER_LOG"))
        fixture.driver.close {}; fixture.callbacks.drain()
    }

    private func openNativeDriver() -> (driver: ImageCaptureSessionDriver, camera: SessionTestCamera, callbacks: DriverCallbackQueue) {
        let browser = SessionTestBrowser(); let callbacks = DriverCallbackQueue(); let camera = SessionTestCamera()
        let driver = ImageCaptureSessionDriver(makeBrowser: { browser }, deliverCompletion: { callbacks.enqueue($0) })
        driver.start { _ in }; callbacks.drain()
        driver.deviceBrowser(browser, didAdd: camera, moreComing: false)
        camera.completeOpen(error: nil); callbacks.drain()
        return (driver, camera, callbacks)
    }
    private func nativeCommand(_ transaction: UInt8, opcode: UInt8 = 0x01) -> Data {
        Data([12,0,0,0,1,0,opcode,0x10,transaction,0,0,0])
    }
    private func nativeResponse(_ transaction: UInt8) -> Data {
        Data([12,0,0,0,3,0,1,0x20,transaction,0,0,0])
    }

    private func openedCount(_ events: [CameraDriverEvent]) -> Int {
        events.filter { if case .opened = $0 { true } else { false } }.count
    }
    private func failedCount(_ events: [CameraDriverEvent]) -> Int {
        events.filter { if case .failed = $0 { true } else { false } }.count
    }
}

/// Public framework boundary doubles: no OS authorization request, browser discovery or physical session.
private final class SessionTestBrowser: ICDeviceBrowser {
    private(set) var didStart = false
    private var browsingNow = false
    var suspensionFlag = false
    var cachedDevices: [ICDevice] = []
    override var isBrowsing: Bool { browsingNow }
    override var isSuspended: Bool { suspensionFlag }
    override var devices: [ICDevice]? { cachedDevices }
    private var controlStatus: ICAuthorizationStatus
    private var contentsStatus: ICAuthorizationStatus
    private(set) var controlRequestCount = 0
    private(set) var contentsRequestCount = 0
    private let automaticallyAuthorize: Bool
    private var controlReply: (@Sendable (ICAuthorizationStatus) -> Void)?
    private var contentsReply: (@Sendable (ICAuthorizationStatus) -> Void)?
    private let controlRequested = AsyncStream<Void>.makeStream()
    private let contentsRequested = AsyncStream<Void>.makeStream()
    private let browsingEvents = AsyncStream<Void>.makeStream()

    init(control: ICAuthorizationStatus = .authorized, contents: ICAuthorizationStatus = .authorized, automaticallyAuthorize: Bool = true) {
        self.automaticallyAuthorize = automaticallyAuthorize
        controlStatus = control; contentsStatus = contents
        super.init()
    }

    var configuredMask: ICDeviceTypeMask?
    override var browsedDeviceTypeMask: ICDeviceTypeMask {
        get { configuredMask ?? .camera }
        set { configuredMask = newValue }
    }
    override var controlAuthorizationStatus: ICAuthorizationStatus { controlStatus }
    override var contentsAuthorizationStatus: ICAuthorizationStatus { contentsStatus }
    override func requestControlAuthorization(completion: @escaping @Sendable (ICAuthorizationStatus) -> Void) {
        controlRequestCount += 1; controlReply = completion; controlRequested.continuation.yield(())
        if automaticallyAuthorize { completeControl(.authorized) }
    }

    override func requestContentsAuthorization(completion: @escaping @Sendable (ICAuthorizationStatus) -> Void) {
        contentsRequestCount += 1; contentsReply = completion; contentsRequested.continuation.yield(())
        if automaticallyAuthorize { completeContents(.authorized) }
    }

    override func start() { didStart = true; browsingNow = true; browsingEvents.continuation.yield(()) }
    override func stop() { browsingNow = false }
    func completeControl(_ status: ICAuthorizationStatus) { controlStatus = status; controlReply?(status) }
    func completeContents(_ status: ICAuthorizationStatus) { contentsStatus = status; contentsReply?(status) }
    @MainActor func waitForControlRequest() async {
        if controlRequestCount > 0 { return }
        for await _ in controlRequested.stream { return }
    }
    @MainActor func waitForContentsRequest() async {
        if contentsRequestCount > 0 { return }
        for await _ in contentsRequested.stream { return }
    }
    @MainActor func waitUntilBrowsing() async {
        if didStart { return }
        for await _ in browsingEvents.stream { return }
    }
}

private final class SessionTestCamera: ICCameraDevice {
    private var ptpBlock: (@Sendable (Data, Data, (any Error)?) -> Void)?
    private var ptpTarget: NSObject?
    private var ptpSelector: Selector?
    private var ptpContext: UnsafeMutableRawPointer?
    private let ptpReceived = AsyncStream<Void>.makeStream()
    private var ptpRequestCount = 0
    var contextValue: UInt? { ptpContext.map { UInt(bitPattern: $0) } }
    @MainActor func waitForPTPRequest() async {
        if ptpRequestCount > 0 { return }
        for await _ in ptpReceived.stream { return }
    }
    private(set) var lastPTPUsedSelector = false
    override func requestSendPTPCommand(_ command: Data, outData: Data?, completion: @escaping @Sendable (Data, Data, (any Error)?) -> Void) {
        ptpRequestCount += 1; ptpReceived.continuation.yield(())
        lastPTPUsedSelector = false; ptpBlock = completion
    }
    override func requestSendPTPCommand(_ command: Data, outData: Data?, sendCommandDelegate: Any, didSendCommand selector: Selector, contextInfo: UnsafeMutableRawPointer?) {
        ptpRequestCount += 1; ptpReceived.continuation.yield(())
        lastPTPUsedSelector = true; ptpTarget = sendCommandDelegate as? NSObject; ptpSelector = selector; ptpContext = contextInfo
    }
    func completePTP(command: Data, response: Data, data: Data = Data(), context: NativeContext = .current) {
        if let target = ptpTarget, let selector = ptpSelector {
            typealias Callback = @convention(c) (AnyObject, Selector, NSData, NSData, NSData, NSError?, UnsafeMutableRawPointer?) -> Void
            let invoke = unsafeBitCast(target.method(for: selector), to: Callback.self)
            let deliveredContext: UnsafeMutableRawPointer?
            switch context {
            case .current: deliveredContext = ptpContext
            case .missing: deliveredContext = nil
            case .value(let value): deliveredContext = UnsafeMutableRawPointer(bitPattern: value)
            }
            invoke(target, selector, command as NSData, data as NSData, response as NSData, nil, deliveredContext)

        } else { ptpBlock?(data, response, nil) }
    }
    private var openCompletion: (@Sendable ((any Error)?) -> Void)?
    private var sessionIsOpen = false
    private(set) var pendingOpenCount = 0
    private(set) var closeRequestCount = 0
    override var usbVendorID: Int32 { 0x04cb }
    override var usbProductID: Int32 { 1 }
    override var transportType: String? { ICDeviceTransport.transportTypeUSB.rawValue }
    override var capabilities: [String] { [ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue] }
    override var name: String? { "PRIVATE_DEVICE_NAME" }
    override var hasOpenSession: Bool { sessionIsOpen }
    override func requestOpenSession(options: [ICSessionOptions: Any]?, completion: @escaping @Sendable ((any Error)?) -> Void) {
        pendingOpenCount += 1; openCompletion = completion
    }
    override func requestCloseSession(options: [ICSessionOptions: Any]?, completion: @escaping @Sendable ((any Error)?) -> Void) {
        closeRequestCount += 1; sessionIsOpen = false; completion(nil)
    }
    func completeOpen(error: (any Error)?) { sessionIsOpen = error == nil; openCompletion?(error) }
}

/// Executes the real driver's framework-completion bodies in a caller-selected order, without Task scheduling or sleeps.
/// Thread-safe enqueue matches arbitrary SDK callback queues; only MainActor drains and runs the bodies.
private final class DriverCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { pending.append(action) } }
    @MainActor func drain() {
        while true {
            let batch = lock.withLock { let batch = pending; pending = []; return batch }
            if batch.isEmpty { return }
            for action in batch { action() }
        }
    }
}

private enum NativeContext { case current, missing, value(UInt) }
