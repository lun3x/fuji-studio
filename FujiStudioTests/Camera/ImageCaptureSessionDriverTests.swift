import Foundation
import ImageCaptureCore
import Testing
@testable import FujiStudio

@MainActor struct ImageCaptureSessionDriverTests {
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
    var configuredMask: ICDeviceTypeMask?
    override var browsedDeviceTypeMask: ICDeviceTypeMask {
        get { configuredMask ?? .camera }
        set { configuredMask = newValue }
    }
    override var controlAuthorizationStatus: ICAuthorizationStatus { .authorized }
    override var contentsAuthorizationStatus: ICAuthorizationStatus { .authorized }
    override func requestControlAuthorization(completion: @escaping @Sendable (ICAuthorizationStatus) -> Void) { completion(.authorized) }
    override func requestContentsAuthorization(completion: @escaping @Sendable (ICAuthorizationStatus) -> Void) { completion(.authorized) }
    override func start() { didStart = true }
    override func stop() {}
}

private final class SessionTestCamera: ICCameraDevice {
    private var openCompletion: (@Sendable ((any Error)?) -> Void)?
    private var sessionIsOpen = false
    private(set) var pendingOpenCount = 0
    private(set) var closeRequestCount = 0
    override var usbVendorID: Int32 { 0x04cb }
    override var usbProductID: Int32 { 1 }
    override var transportType: String? { ICDeviceTransport.transportTypeUSB.rawValue }
    override var capabilities: [String] { [ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue] }
    override var name: String? { "X-T5 fixture" }
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
