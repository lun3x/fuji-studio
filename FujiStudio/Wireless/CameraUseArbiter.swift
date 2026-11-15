import Foundation
import FujiCameraCore

/// Suspension prevents new BLE work and returns only after native BLE teardown.
protocol USBBluetoothControlling: AnyObject, Sendable {
    func suspendBluetoothForUSB() async throws
    func resumeBluetoothAfterUSB() async
}

actor CameraUseArbiter {
    private enum Ownership {
        case usb, closingUSB, unconfirmedUSB, acquiringWireless
        case wireless(CameraUseLease)
    }

    private let owner = UUID()
    private var ownership = Ownership.usb
    private var usbOperations = 0
    private var usbAdmission: UInt64 = 0
    private var usbDrain: CheckedContinuation<Void, Never>?
    private var usbExport: UUID?

    // App composition installs the live coordinator before either transport starts.
    // The coordinator already holds the ownership gateway, so this reference is weak.
    private weak var bluetooth: (any USBBluetoothControlling)?
    private var bluetoothConfigured = false
    private var bluetoothSuspension: Task<Void, Error>?

    func installBluetoothController(_ bluetooth: any USBBluetoothControlling) throws {
        guard !bluetoothConfigured, case .usb = ownership, usbAdmission == 0, usbExport == nil else {
            throw WirelessFailure.cameraBusy
        }
        self.bluetooth = bluetooth
        bluetoothConfigured = true
    }

    func withUSB<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withUSB(operation, closeIfUnavailable: nil)
    }

    func withUSB<T: Sendable>(
        _ operation: @Sendable () async throws -> T,
        closeIfUnavailable: (@Sendable () async throws -> Void)?
    ) async throws -> T {
        try Task.checkCancellation()
        try checkUSBAdmission()
        usbAdmission &+= 1
        let admission = usbAdmission
        usbOperations += 1

        let result: Result<T, Error>
        var didRun = false
        do {
            try await suspendBluetooth()
            try Task.checkCancellation()
            try checkUSBAdmission()
            didRun = true
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        finishUSBOperation()

        if didRun, case .failure(let error) = result, Self.isUSBUnavailable(error), let closeIfUnavailable,
           bluetoothSuspension != nil, usbAdmission == admission, usbOperations == 0,
           usbExport == nil, case .usb = ownership {
            // An absent camera should give BLE readiness back. Reserve before probing
            // cleanup so a later USB open cannot race the close of this attempt.
            ownership = .closingUSB
            try await confirmUSBClose(closeIfUnavailable)
            ownership = .usb
        }
        return try result.get()
    }

    func beginUSBExport(_ jobID: UUID) async throws {
        try Task.checkCancellation()
        try checkUSBAdmission()
        guard usbExport == nil else { throw WirelessFailure.cameraBusy }
        usbAdmission &+= 1
        usbExport = jobID
        usbOperations += 1
        defer { finishUSBOperation() }
        do {
            try await suspendBluetooth()
            try Task.checkCancellation()
            guard usbExport == jobID else { throw CancellationError() }
        } catch {
            endUSBExport(jobID)
            throw error
        }
    }

    func endUSBExport(_ jobID: UUID) {
        if usbExport == jobID { usbExport = nil }
    }

    func acquireWireless(quiesceUSB: @escaping @Sendable () async throws -> Void) async throws -> CameraUseLease {
        try await acquireWireless(invalidatePreview: {}, quiesceUSB: quiesceUSB)
    }

    func acquireWireless(
        invalidatePreview: @Sendable () async -> Void,
        quiesceUSB: @escaping @Sendable () async throws -> Void
    ) async throws -> CameraUseLease {
        try Task.checkCancellation()
        try checkUSBAdmission()
        guard usbExport == nil else { throw WirelessFailure.cameraBusy }
        ownership = .acquiringWireless
        await invalidatePreview()
        await drainUSB()
        try await confirmUSBClose(quiesceUSB)
        if Task.isCancelled {
            ownership = .usb
            throw CancellationError()
        }
        let lease = CameraUseLease(owner: owner)
        ownership = .wireless(lease)
        return lease
    }

    func releaseWireless(_ lease: CameraUseLease) {
        guard case .wireless(let current) = ownership, current == lease else { return }
        ownership = .usb
    }

    func disconnectUSB(
        explicitly: Bool, closeUSB: @escaping @Sendable () async throws -> Void
    ) async throws {
        if explicitly, case .unconfirmedUSB = ownership {
            ownership = .closingUSB
        } else {
            try checkUSBAdmission()
            guard usbExport == nil else { throw WirelessFailure.cameraBusy }
            ownership = .closingUSB
        }
        // Admitted callers can still be entering the underlying service. Drain before
        // closing so a late USB open cannot run after the close receipt.
        await drainUSB()
        try await confirmUSBClose(closeUSB)
        ownership = .usb
    }

    func recoverUSBIfNeeded(closeUSB: @escaping @Sendable () async throws -> Void) async throws {
        guard case .unconfirmedUSB = ownership else { return }
        try await disconnectUSB(explicitly: true, closeUSB: closeUSB)
    }

    private func checkUSBAdmission() throws {
        switch ownership {
        case .usb: return
        case .unconfirmedUSB: throw WirelessFailure.usbCloseUnconfirmed
        default: throw WirelessFailure.cameraBusy
        }
    }

    private func finishUSBOperation() {
        usbOperations -= 1
        if usbOperations == 0 {
            usbDrain?.resume()
            usbDrain = nil
        }
    }

    private func drainUSB() async {
        if usbOperations != 0 { await withCheckedContinuation { usbDrain = $0 } }
    }

    private func confirmUSBClose(_ closeUSB: @escaping @Sendable () async throws -> Void) async throws {
        // A cancelled waiter cannot stop teardown or substitute for a native receipt.
        do { try await Task.detached(operation: closeUSB).value }
        catch {
            ownership = .unconfirmedUSB
            throw CameraServiceError.closeUnconfirmed
        }
        await resumeBluetooth()
    }

    private static func isUSBUnavailable(_ error: any Error) -> Bool {
        switch error {
        case CameraServiceError.transport(.notConnected), CameraServiceError.transport(.timeout),
             CameraServiceError.transport(.authorizationDenied), CameraServiceError.transport(.wrongMode),
             CameraServiceError.cancelled, is CancellationError:
            return true
        default:
            // Attention states and metadata failures can retain a live USB session.
            return false
        }
    }

    private func suspendBluetooth() async throws {
        guard bluetoothConfigured else { return }
        guard let bluetooth else { throw WirelessFailure.connectionLost }
        if let bluetoothSuspension {
            try await bluetoothSuspension.value
            return
        }
        let suspension = Task.detached { try await bluetooth.suspendBluetoothForUSB() }
        bluetoothSuspension = suspension
        do { try await suspension.value }
        catch {
            bluetoothSuspension = nil
            throw error
        }
    }

    private func resumeBluetooth() async {
        guard bluetoothSuspension != nil else { return }
        await bluetooth?.resumeBluetoothAfterUSB()
        bluetoothSuspension = nil
    }
}
