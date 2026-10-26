import Foundation
import ImageCaptureCore

/// A public ImageCaptureCore session and one bounded wire transaction at a time.
/// Use SerialCameraGate around whole upload/convert/download operations, not around individual commands.
@MainActor final class ImageCaptureTransport: PTPTransport {
    private struct Opening {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        var timeout: UUID?
    }
    private struct Transaction {
        let id: UUID
        let command: PTPCommand
        let continuation: CheckedContinuation<PTPReply, Error>
        let timeout: UUID
    }
    private let driver: any CameraSessionDriver
    private let timeouts: any CameraTimeoutScheduling
    private let timeout: Duration
    private let maximumDataBytes: Int
    private var generation: UInt64 = 0
    private var session: CameraSession?
    private var opening: Opening?
    private var transaction: Transaction?
    private var closing = false
    private var closeID: UUID?
    private var state: CameraState = .disconnected
    private var subscribers: [UUID: AsyncStream<CameraState>.Continuation] = [:]

    init(driver: any CameraSessionDriver = ImageCaptureSessionDriver(),
         timeouts: any CameraTimeoutScheduling = CameraTimeoutScheduler(),
         timeout: Duration = .seconds(30), maximumDataBytes: Int = PTPCodec.maximumDataBytes) {
        self.driver = driver; self.timeouts = timeouts; self.timeout = timeout; self.maximumDataBytes = maximumDataBytes
    }

    func states() async -> AsyncStream<CameraState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CameraState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        return stream
    }

    func connect() async throws {
        try Task.checkCancellation()
        guard !closing else { throw PTPError.sessionClosing }
        if session != nil { return }
        guard opening == nil else { throw PTPError.busy }
        generation += 1
        let current = generation; let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Human authorization has no USB deadline. The driver explicitly reports when
                // permission is resolved and actual discovery begins.
                opening = Opening(id: id, continuation: continuation, timeout: nil)
                driver.start { [weak self] event in self?.receive(event, generation: current) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.opening?.id == id else { return }
                self.invalidate(CancellationError(), state: .disconnected)
            }
        }
    }

    #if DEBUG
    func ptpDiagnosticMessages() -> [String] { (driver as? ImageCaptureSessionDriver)?.ptpDiagnostics ?? [] }
    #endif

    func disconnect() async { invalidate(PTPError.notConnected, state: .disconnected) }

    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        try Task.checkCancellation()
        guard let session, !closing else { throw PTPError.notConnected }
        guard transaction == nil else { throw PTPError.busy }
        guard (data?.count ?? 0) <= maximumDataBytes else { throw PTPError.payloadTooLarge }
        let encoded = try PTPCodec.encode(command)
        let id = UUID(); let current = session.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = timeouts.schedule(after: timeout) { [weak self] in
                    guard let self, self.transaction?.id == id else { return }
                    self.invalidate(PTPError.timeout, state: .recoverableError(.timeout))
                }
                transaction = Transaction(id: id, command: command, continuation: continuation, timeout: deadline)
                publish(.busy(session))
                driver.send(command: encoded, data: data) { [weak self] result in
                    self?.receive(result, id: id, generation: current)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.transaction?.id == id else { return }
                self.invalidate(CancellationError(), state: .disconnected)
            }
        }
    }

    private func receive(_ event: CameraDriverEvent, generation current: UInt64) {
        guard current == generation, !closing else { return }
        switch event {
        case .authorizationRequired: publish(.authorizationRequired)
        case .discoveryStarted:
            guard let pending = opening, pending.timeout == nil else { return }
            let id = pending.id
            let deadline = timeouts.schedule(after: timeout) { [weak self] in
                guard let self, self.opening?.id == id else { return }
                self.invalidate(PTPError.timeout, state: .recoverableError(.timeout))
            }
            guard opening?.id == id else { timeouts.cancel(deadline); return }
            opening?.timeout = deadline
            publish(.discovering)
        case .opening: publish(.opening)
        case .opened(let connection):
            guard let pending = opening else { return }
            opening = nil; if let deadline = pending.timeout { timeouts.cancel(deadline) }
            let opened = CameraSession(generation: current, connection: connection)
            session = opened; publish(.sessionOpen(opened)); pending.continuation.resume()
        case .removed: invalidate(PTPError.notConnected, state: .disconnected)
        case .failed(let error):
            let state: CameraState
            switch error {
            case .authorizationDenied: state = .authorizationDenied
            case .wrongMode(let reason): state = .wrongMode(reason)
            default: state = .recoverableError(error)
            }
            invalidate(error, state: state)
        }
    }

    private func receive(_ result: Result<PTPWireReply, PTPError>, id: UUID, generation current: UInt64) {
        guard current == generation, !closing, let pending = transaction, pending.id == id else { return }
        do {
            let wire = try result.get()
            let reply: PTPReply
            switch wire.correlation {
            case .directWireTransaction:
                reply = try PTPCodec.decode(response: wire.response, data: wire.data, for: pending.command, maximumDataBytes: maximumDataBytes)
            case .imageCaptureCoreCallback(let echoedCommand):
                reply = try PTPCodec.decodeFrameworkManaged(response: wire.response, data: wire.data, for: pending.command,
                                                          echoedCommand: echoedCommand, maximumDataBytes: maximumDataBytes)
            }

            transaction = nil; timeouts.cancel(pending.timeout)
            if let session { publish(.sessionOpen(session)) }
            pending.continuation.resume(returning: reply)
        } catch let error as PTPError {
            // A complete, identified camera rejection does not leave a wire operation active.
            if case .responseCode = error {
                transaction = nil; timeouts.cancel(pending.timeout)
                if let session { publish(.sessionOpen(session)) }
                pending.continuation.resume(throwing: error)
            } else { invalidate(error, state: .recoverableError(error)) }
        } catch { invalidate(PTPError.sessionFailure(String(describing: error)), state: .recoverableError(.sessionFailure(String(describing: error)))) }
    }

    private func invalidate(_ error: any Error, state newState: CameraState) {
        // Invalidate identity BEFORE resuming a caller or asking the framework to close.
        // A resumed operation may release the external gate, but execute remains unavailable.
        generation += 1
        session = nil
        if let pending = opening { opening = nil; if let deadline = pending.timeout { timeouts.cancel(deadline) }; pending.continuation.resume(throwing: error) }
        if let pending = transaction { transaction = nil; timeouts.cancel(pending.timeout); pending.continuation.resume(throwing: error) }
        publish(newState)
        guard !closing else { return }
        closing = true
        let closeID = UUID()
        self.closeID = closeID
        driver.close { [weak self] in
            guard let self else { return }
            // Repeated disconnects do not make an unconfirmed old close available.
            guard self.closeID == closeID else { return }
            self.closeID = nil
            self.closing = false
        }
    }
    private func publish(_ value: CameraState) {
        state = value
        for continuation in subscribers.values { continuation.yield(value) }
    }
}

/// Framework objects stay on MainActor. Completion handlers explicitly hop back; headers permit arbitrary queues.
@MainActor final class ImageCaptureSessionDriver: NSObject, CameraSessionDriver, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    /// Framework completions may arrive on arbitrary queues. The default always hops to MainActor.
    typealias CompletionDelivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private nonisolated let deliverCompletion: CompletionDelivery
    private let makeBrowser: @MainActor () -> ICDeviceBrowser

    private struct NativeRequest {
        let id: UUID
        let run: UUID
        let context: UInt
        let submitted: PTPCommand
        let completion: @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void
    }
    private var nativeRequest: NativeRequest?
    private var nextNativeContext: UInt = 1
    #if DEBUG
    private(set) var ptpDiagnostics: [String] = []
    #endif
    private var browser: ICDeviceBrowser?
    private var camera: ICCameraDevice?
    private var events: (@MainActor @Sendable (CameraDriverEvent) -> Void)?
    private var run = UUID()
    private var opening = false
    private var closing = false
    private var closeCompletion: (@MainActor @Sendable () -> Void)?

    init(makeBrowser: @escaping @MainActor () -> ICDeviceBrowser = { ICDeviceBrowser() },
         deliverCompletion: @escaping CompletionDelivery = { action in Task { @MainActor in action() } }) {
        self.deliverCompletion = deliverCompletion
        self.makeBrowser = makeBrowser
        super.init()
    }

    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void) {
        self.events = events; run = UUID(); let current = run
        let browser = makeBrowser()
        self.browser = browser
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        let statuses = [browser.controlAuthorizationStatus, browser.contentsAuthorizationStatus]
        guard statuses.allSatisfy({ $0 == .authorized || $0 == .notDetermined }) else {
            events(.failed(.authorizationDenied))
            return
        }
        if browser.controlAuthorizationStatus == .authorized {
            authorizeContents(current)
            return
        }
        events(.authorizationRequired)
        let deliver = deliverCompletion
        browser.requestControlAuthorization { [weak self] status in
            deliver {
                guard let self, self.run == current, !self.closing else { return }
                guard status == .authorized else { self.events?(.failed(.authorizationDenied)); return }
                self.authorizeContents(current)
            }
        }
    }
    private func authorizeContents(_ current: UUID) {
        guard run == current, !closing, let browser else { return }
        if browser.contentsAuthorizationStatus == .authorized {
            beginDiscovery(current)
            return
        }
        guard browser.contentsAuthorizationStatus == .notDetermined else {
            events?(.failed(.authorizationDenied))
            return
        }
        events?(.authorizationRequired)
        let deliver = deliverCompletion
        browser.requestContentsAuthorization { [weak self] status in
            deliver {
                guard let self, self.run == current, !self.closing else { return }
                guard status == .authorized else { self.events?(.failed(.authorizationDenied)); return }
                self.beginDiscovery(current)
            }
        }
    }
    private func beginDiscovery(_ current: UUID) {
        guard run == current, !closing, let browser else { return }
        events?(.discoveryStarted)
        // The event can synchronously invalidate this run; never start an already closed browser.
        guard run == current, !closing, self.browser === browser else { return }
        browser.start()
    }
    func close(completion: @escaping @MainActor @Sendable () -> Void) {
        nativeRequest = nil
        closing = true; closeCompletion = completion; events = nil
        browser?.stop()
        // Opening has no public cancellation API. Wait for its terminal callback, then close it.
        if opening { return }
        closeCamera()
    }
    private func closeCamera() {
        guard let camera else { finishClose(); return }
        let current = run
        let deliver = deliverCompletion
        camera.requestCloseSession(options: nil) { [weak self] error in
            deliver {
                guard let self, self.run == current, self.closing else { return }
                // A failed close is uncertain. Keep quarantined until didRemoveDevice observes detachment.
                guard error == nil else { return }
                self.finishClose()
            }
        }
    }
    private func finishClose() {
        camera?.delegate = nil; camera = nil
        browser?.delegate = nil; browser = nil
        nativeRequest = nil
        opening = false; closing = false; run = UUID()
        let completion = closeCompletion; closeCompletion = nil; completion?()
    }
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void) {
        guard let camera, !closing, camera.hasOpenSession else { completion(.failure(.notConnected)); return }
        guard nativeRequest == nil else { completion(.failure(.busy)); return }
        do {
            let submitted = try PTPCodec.decodeCommand(command)
            guard nextNativeContext < UInt.max else { throw PTPError.sessionFailure("Native request context exhausted") }
            let context = nextNativeContext; nextNativeContext += 1
            let pending = NativeRequest(id: UUID(), run: run, context: context, submitted: submitted, completion: completion)
            nativeRequest = pending
            #if DEBUG
            if submitted.opcode == 0x1001, submitted.parameters.isEmpty, data == nil {
                recordPTPDiagnostic("submit request=\(pending.id) run=\(run) context=\(context) \(Self.headerSummary(command)) outBytes=0")
            }
            #endif
            // contextInfo is an opaque, never-dereferenced monotonic token. It is never reused
            // across sessions, so a late callback cannot alias a newly allocated context object.
            camera.requestSendPTPCommand(command, outData: data, sendCommandDelegate: self,
                didSendCommand: #selector(didSendPTPCommand(_:inData:response:error:contextInfo:)),
                contextInfo: UnsafeMutableRawPointer(bitPattern: context))
        } catch let error as PTPError { completion(.failure(error)) }
        catch { completion(.failure(.sessionFailure("Invalid native command"))) }
    }

    @objc nonisolated func didSendPTPCommand(_ command: Data, inData: Data, response: Data, error: NSError?, contextInfo: UnsafeMutableRawPointer?) {
        let context = contextInfo.map { UInt(bitPattern: $0) }
        deliverCompletion { [weak self] in
            self?.receivedPTPCallback(command: command, data: inData, response: response, error: error, context: context)
        }
    }

    private func receivedPTPCallback(command: Data, data: Data, response: Data, error: NSError?, context: UInt?) {
        guard let pending = nativeRequest, pending.run == run, !closing else { return }
        #if DEBUG
        if pending.submitted.opcode == 0x1001, pending.submitted.parameters.isEmpty {
            recordPTPDiagnostic("callback request=\(pending.id) context=\(context.map(String.init) ?? "nil") expectedContext=\(pending.context) command[\(Self.headerSummary(command))] response[\(Self.headerSummary(response))] inBytes=\(data.count); payload bytes omitted; error=\(error.map { String($0.domain.prefix(80)) + ":" + String($0.code) } ?? "none")")
        }
        #endif
        guard context == pending.context else { return }
        nativeRequest = nil
        if let error {
            pending.completion(.failure(.sessionFailure("\(error.domain):\(error.code)")))
            return
        }
        do {
            let callback = try PTPCodec.validateCallbackCommand(command, for: pending.submitted)
            _ = try PTPCodec.decodeFrameworkManaged(response: response, data: data, for: pending.submitted, echoedCommand: callback)
            pending.completion(.success(PTPWireReply(correlation: .imageCaptureCoreCallback(echoedCommand: callback), response: response, data: data)))

        } catch let failure as PTPError {
            #if DEBUG
            if pending.submitted.opcode == 0x1001 { recordPTPDiagnostic("rejected request=\(pending.id): \(failure)") }
            #endif
            pending.completion(.failure(failure))
        } catch { pending.completion(.failure(.sessionFailure("Invalid native callback"))) }
    }

    #if DEBUG
    private func recordPTPDiagnostic(_ message: String) {
        ptpDiagnostics.append(String(message.prefix(1100)))
        if ptpDiagnostics.count > 16 { ptpDiagnostics.removeFirst(ptpDiagnostics.count - 16) }
    }
    private static func headerSummary(_ buffer: Data) -> String {
        let prefix = buffer.prefix(32).map { String(format: "%02x", $0) }.joined()
        let bytes = [UInt8](buffer.prefix(12))
        guard bytes.count == 12 else { return "bytes=\(buffer.count) prefix=\(prefix) truncated" }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24 }
        let kind = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        let code = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
        return "bytes=\(buffer.count) length=\(u32(0)) type=\(kind) code=0x\(String(code, radix: 16)) tx=\(u32(8)) prefix=\(prefix)"
    }
    #endif
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard browser === self.browser, !closing, camera == nil,
              let camera = device as? ICCameraDevice, camera.usbVendorID == 0x04cb else { return }
        guard camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue,
              camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
            events?(.failed(.wrongMode("Visible Fujifilm device lacks USB PTP control. Check USB RAW CONV./BACKUP RESTORE on the camera.")))
            return
        }
        self.camera = camera; camera.delegate = self; opening = true
        events?(.opening)
        let current = run
        let deliver = deliverCompletion
        camera.requestOpenSession(options: nil) { [weak self] error in
            deliver { self?.openFinished(error, run: current) }
        }
    }
    private func openFinished(_ error: (any Error)?, run current: UUID) {
        guard run == current else { return }
        opening = false
        if closing { closeCamera(); return }
        if let error { events?(.failed(.sessionFailure("\((error as NSError).domain):\((error as NSError).code)"))); return }
        guard let camera, camera.hasOpenSession else { events?(.failed(.notConnected)); return }
        events?(.opened(CameraConnection(name: camera.name ?? "Fujifilm camera", usbVendorID: Int(camera.usbVendorID), usbProductID: Int(camera.usbProductID))))
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { didRemove(device) }
    func didRemove(_ device: ICDevice) {
        guard device === camera else { return }
        nativeRequest = nil
        // Observed detachment is terminal even if requestOpenSession never completes. Retire
        // its identity and opening state BEFORE .removed synchronously asks us to close.
        camera?.delegate = nil
        camera = nil
        opening = false
        run = UUID()
        if closing { finishClose() }
        else { events?(.removed) }
    }
    // The camera delegate is required by the public API even though this transport does not consume its card catalog.
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard device === camera, !closing else { return }
        events?(.failed(.authorizationDenied))
    }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        guard camera === self.camera, !closing else { return }
        if !camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) {
            events?(.failed(.wrongMode("USB PTP control capability changed. Check the camera USB mode.")))
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { false }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard device === camera else { return }
        if closing {
            if error == nil { finishClose() }
        } else { events?(.failed(.notConnected)) }
    }
    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        guard device === camera, !closing else { return }
        events?(.failed(.sessionFailure(error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "Unknown device error")))
    }
}
