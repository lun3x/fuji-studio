import FujiCameraCore
import XCTest
@testable import FujiStudio

@MainActor
final class CameraUseArbiterTests: XCTestCase {
    func testCancelledPreviewStillOwnsNativeRenderUntilItReturns() async throws {
        let f = try await FixtureEnvironment.make()
        let photo = try RenderFixture()
        defer { photo.remove() }
        let camera = f.environment.camera
        try await camera.connect()
        let render = FixtureBarrier()
        await f.camera.holdRender(render)
        let preview = Task {
            try await f.scheduler.withPreview {
                try await camera.render(raw: photo.raw, recipe: photo.recipe, policy: .fullSizeFineRecordedGeometry)
            }
        }
        await render.entered()
        preview.cancel()

        let reservation = FixtureBarrier()
        let closed = FixtureBarrier()
        let handoff = Task {
            try await f.environment.cameraUseArbiter.acquireWireless(
                invalidatePreview: { await reservation.wait() },
                quiesceUSB: {
                    let finished = await f.camera.cancelledRenders
                    XCTAssertEqual(finished, 1)
                    try await f.camera.disconnectConfirmed()
                    await closed.wait()
                })
        }
        await reservation.entered()
        await expectBusy { try await camera.connect() }
        await reservation.release()
        let closeCallsBeforeRenderReturns = await f.camera.disconnectCount
        XCTAssertEqual(closeCallsBeforeRenderReturns, 0)
        await render.release()
        do {
            _ = try await preview.value
            XCTFail("Preview should observe cancellation after native work returns")
        } catch is CancellationError {}
        await closed.entered()
        await closed.release()
        let lease = try await handoff.value
        await f.environment.wirelessOwnership.releaseWireless(lease)
    }

    func testCancelledAcquisitionKeepsUSBBlockedUntilCloseConfirms() async throws {
        let f = try await FixtureEnvironment.make()
        let close = FixtureBarrier()
        await f.camera.holdDisconnect(close)
        let handoff = Task { try await f.environment.wirelessOwnership.acquireWireless() }
        await close.entered()
        handoff.cancel()

        await expectBusy { try await f.environment.camera.connect() }
        await close.release()
        do {
            _ = try await handoff.value
            XCTFail("Cancelled acquisition should discard the wireless lease")
        } catch is CancellationError {}
        try await f.environment.camera.connect()
    }

    func testStaleLeaseCannotReleaseNewWirelessOwner() async throws {
        let f = try await FixtureEnvironment.make()
        let ownership = f.environment.wirelessOwnership
        let first = try await ownership.acquireWireless()
        await ownership.releaseWireless(first)
        let second = try await ownership.acquireWireless()
        await ownership.releaseWireless(first)

        await expectBusy { try await f.environment.camera.resetConnection() }
        let resets = await f.camera.resetCount
        XCTAssertEqual(resets, 0)
        await ownership.releaseWireless(second)
        try await f.environment.camera.connect()
        let connects = await f.camera.connectCount
        XCTAssertEqual(connects, 1)
    }

    func testBluetoothRemainsSuspendedAcrossUSBExportUntilConfirmedClose() async throws {
        let f = try await FixtureEnvironment.make()
        let bluetooth = USBTestBluetooth()
        try await f.environment.cameraUseArbiter.installBluetoothController(bluetooth)
        let job = UUID()
        let exporting = Task { try await f.scheduler.beginExport(jobID: job) }
        await bluetooth.suspending.entered()
        await expectBusy { _ = try await f.environment.wirelessOwnership.acquireWireless() }
        await bluetooth.suspending.release()
        try await exporting.value
        try await f.environment.camera.connect()
        await f.scheduler.endExport(jobID: job)
        var transitions = await bluetooth.transitions
        XCTAssertEqual(transitions, ["suspended"])

        try await f.environment.camera.disconnectConfirmed()
        transitions = await bluetooth.transitions
        XCTAssertEqual(transitions, ["suspended", "resumed"])
    }

    func testCancelledProvisionalExportResumesBluetoothAfterNativeDrain() async throws {
        let f = try await FixtureEnvironment.make()
        let bluetooth = USBTestBluetooth()
        try await f.environment.cameraUseArbiter.installBluetoothController(bluetooth)
        let job = UUID()
        let exporting = Task { try await f.scheduler.beginExport(jobID: job) }
        await bluetooth.suspending.entered()
        exporting.cancel()
        await expectBusy { _ = try await f.environment.wirelessOwnership.acquireWireless() }
        let beforeDrain = await bluetooth.transitions
        XCTAssertEqual(beforeDrain, [])
        await bluetooth.suspending.release()
        do {
            try await exporting.value
            XCTFail("The export should not start")
        } catch is CancellationError {}

        let transitions = await bluetooth.transitions
        XCTAssertEqual(transitions, ["suspended", "resumed"])
        let closes = await f.camera.disconnectCount
        XCTAssertEqual(closes, 0)
    }

    func testUnconfirmedFailedUSBDiscoveryKeepsBluetoothSuspendedUntilRecovery() async throws {
        let f = try await FixtureEnvironment.make()
        let bluetooth = USBTestBluetooth()
        await bluetooth.suspending.release()
        try await f.environment.cameraUseArbiter.installBluetoothController(bluetooth)
        await f.camera.setConnectionFailure(.transport(.notConnected))
        await f.camera.setConfirmedCloseFailure(.closeUnconfirmed)

        do {
            try await f.environment.camera.connect()
            XCTFail("The native close was not confirmed")
        } catch CameraServiceError.closeUnconfirmed {}
        let quarantined = await bluetooth.transitions
        XCTAssertEqual(quarantined, ["suspended"])

        await f.camera.setConfirmedCloseFailure(nil)
        try await f.environment.camera.disconnectConfirmed()
        let recovered = await bluetooth.transitions
        XCTAssertEqual(recovered, ["suspended", "resumed"])
    }

    func testFailedUSBDiscoveryResumesBluetoothAfterConfirmedClose() async throws {
        let f = try await FixtureEnvironment.make()
        let bluetooth = USBTestBluetooth()
        await bluetooth.suspending.release()
        try await f.environment.cameraUseArbiter.installBluetoothController(bluetooth)
        await f.camera.setConnectionFailure(.transport(.notConnected))
        let close = FixtureBarrier()
        await f.camera.holdDisconnect(close)
        let connecting = Task { try await f.environment.camera.connect() }
        await close.entered()
        var transitions = await bluetooth.transitions
        XCTAssertEqual(transitions, ["suspended"])
        await close.release()
        do {
            try await connecting.value
            XCTFail("The USB camera is absent")
        } catch CameraServiceError.transport(.notConnected) {}
        transitions = await bluetooth.transitions
        XCTAssertEqual(transitions, ["suspended", "resumed"])
    }

    private func expectBusy(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected camera admission to be blocked")
        } catch {
            XCTAssertEqual(error as? WirelessFailure, .cameraBusy)
        }
    }
}

private actor USBTestBluetooth: USBBluetoothControlling {
    let suspending = FixtureBarrier()
    private(set) var transitions: [String] = []

    func suspendBluetoothForUSB() async throws {
        await suspending.wait()
        transitions.append("suspended")
    }

    func resumeBluetoothAfterUSB() async { transitions.append("resumed") }
}
