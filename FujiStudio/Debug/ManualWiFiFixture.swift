#if DEBUG && targetEnvironment(simulator)
import Foundation
import FujiCameraCore

@MainActor
final class ManualWiFiFixture {
  @MainActor
  private final class Lease {
    var expiration: (@MainActor (ManualWiFiProbe.LeaseExpiration) -> Void)?
    var events: [ManualWiFiEvent] = []
  }

  let camera = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Fixture X-T5")
  let otherCamera = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Alternate X-T5")
  let bluetooth = Bluetooth()
  let transfer = Transfer()
  private let lease: Lease
  let probe: ManualWiFiProbe

  init() {
    let cameras = [camera, otherCamera]
    let lease = Lease()
    self.lease = lease
    let transfer = self.transfer
    probe = ManualWiFiProbe(
      bluetooth: bluetooth, loadSaved: { cameras }, password: { _ in "fixture-password" },
      authorizeLaunch: { _, _ in },
      makeSession: { identity in await transfer.setIdentity(identity); return transfer },
      startLease: { expire in lease.expiration = expire; return { lease.expiration = nil } },
      record: { lease.events.append($0) })
    probe.sceneChanged(.active)
  }

  var leaseHeld: Bool { lease.expiration != nil }
  var events: [ManualWiFiEvent] { lease.events }
  func expireLease(_ reason: ManualWiFiProbe.LeaseExpiration) { lease.expiration?(reason) }

  actor Bluetooth: BluetoothGateway {
    private var selected: SavedCamera?
    private var activationBarrier: FixtureBarrier?
    private var activationFailure: WirelessFailure?
    private var disconnectBarrier: FixtureBarrier?
    private(set) var disconnectCount = 0
    private(set) var activationCount = 0

    func holdActivation(_ barrier: FixtureBarrier, thenThrow failure: WirelessFailure? = nil) {
      activationBarrier = barrier
      activationFailure = failure
    }

    func holdDisconnect(_ barrier: FixtureBarrier) { disconnectBarrier = barrier }

    func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
      AsyncThrowingStream { $0.finish() }
    }

    func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
      let paired = SavedCamera(id: WirelessCameraID(), peripheralID: camera.peripheralID,
        model: .xt5, displayName: camera.displayName)
      selected = paired
      return paired
    }

    func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws { selected = camera }

    func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
      guard selected?.id == id else { throw WirelessFailure.peerMismatch }
      return WirelessIdentity(cameraID: id, model: .xt5, firmware: "04.31")
    }

    func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
      guard selected?.id == id else { throw WirelessFailure.peerMismatch }
      activationCount += 1
      await activationBarrier?.wait()
      if let activationFailure { throw activationFailure }
      return CameraNetwork(ssid: "fixture-network", security: .wpaPersonal,
        credential: CameraCredentialReference(cameraID: id, version: UUID()), isHidden: true)
    }

    func events() async -> AsyncStream<BluetoothGatewayEvent> { AsyncStream { $0.finish() } }

    func disconnect() async {
      disconnectCount += 1
      await disconnectBarrier?.wait()
      selected = nil
    }
  }

  actor Transfer: WirelessTransferSession {
    enum Action { case open, close, transfer }

    private var identity: WirelessIdentity?
    private(set) var actions: [Action] = []

    func setIdentity(_ identity: WirelessIdentity) { self.identity = identity }

    func open() throws -> WirelessIdentity {
      actions.append(.open)
      guard let identity else { throw WirelessFailure.peerMismatch }
      return identity
    }

    func close() { actions.append(.close) }

    func capabilities() throws -> WirelessCapabilities {
      actions.append(.transfer)
      throw WirelessFailure.unsupportedProtocol
    }

    func enumerate() throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
      actions.append(.transfer)
      throw WirelessFailure.unsupportedProtocol
    }

    func thumbnail(_ object: WirelessObjectDescriptor) throws -> Data {
      actions.append(.transfer)
      throw WirelessFailure.unsupportedProtocol
    }

    func download(_ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void) throws {
      actions.append(.transfer)
      throw WirelessFailure.unsupportedProtocol
    }
  }
}
#endif
