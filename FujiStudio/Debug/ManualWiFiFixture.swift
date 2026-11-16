#if DEBUG && targetEnvironment(simulator)
import CoreBluetooth
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
  let finder = SavedFinder()
  private let lease: Lease
  let probe: ManualWiFiProbe

  init() {
    let cameras = [camera, otherCamera]
    let lease = Lease()
    self.lease = lease
    let transfer = self.transfer
    let finder = self.finder
    probe = ManualWiFiProbe(
      bluetooth: bluetooth, loadSaved: { cameras },
      findPaired: { try await finder.find($0) },
      password: { _ in "fixture-password" },
      authorizeLaunch: { _, _ in },
      makeSession: { identity, _ in await transfer.setIdentity(identity); return transfer },
      startLease: { expire in lease.expiration = expire; return { lease.expiration = nil } },
      record: { lease.events.append($0) })
    probe.sceneChanged(.active)
  }

  var leaseHeld: Bool { lease.expiration != nil }
  var events: [ManualWiFiEvent] { lease.events }
  func expireLease(_ reason: ManualWiFiProbe.LeaseExpiration) { lease.expiration?(reason) }

  @MainActor
  final class SavedFinder {
    var beforeReturn: FixtureBarrier?

    func find(_ saved: [SavedCamera]) async throws -> ManualPairedCameraMatches {
      await beforeReturn?.wait()
      var results = ManualPairedCameraMatches(saved: saved)
      if let camera = saved.first {
        results.receive(peripheralID: camera.peripheralID, advertisement: [
          CBAdvertisementDataServiceUUIDsKey: [ManualPairedCameraMatches.service],
          CBAdvertisementDataManufacturerDataKey: Data([0xd8, 0x04, 0, 0, 0, 0, 0, 0]),
          CBAdvertisementDataIsConnectable: true
        ])
      }
      return results
    }
  }

  actor Bluetooth: BluetoothGateway {
    private var selected: SavedCamera?
    private var activationBarrier: FixtureBarrier?
    private var activationFailure: WirelessFailure?
    private var disconnectBarrier: FixtureBarrier?
    private(set) var disconnectCount = 0
    private(set) var activationCount = 0
    private(set) var discoverCount = 0
    private(set) var reconnectCount = 0

    func holdActivation(_ barrier: FixtureBarrier, thenThrow failure: WirelessFailure? = nil) {
      activationBarrier = barrier
      activationFailure = failure
    }

    func holdDisconnect(_ barrier: FixtureBarrier) { disconnectBarrier = barrier }

    func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
      discoverCount += 1
      let camera = DiscoveredCamera(peripheralID: UUID(), advertisedModelHint: .xt5, displayName: "New fixture X-T5")
      return AsyncThrowingStream {
        $0.yield([camera])
        $0.finish()
      }
    }

    func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
      let paired = SavedCamera(id: WirelessCameraID(), peripheralID: camera.peripheralID,
        model: .xt5, displayName: camera.displayName)
      selected = paired
      return paired
    }

    func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws {
      reconnectCount += 1
      selected = camera
    }

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
