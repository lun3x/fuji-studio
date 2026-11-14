import Foundation
import FujiCameraCore
@preconcurrency import NetworkExtension

enum HotspotApplyResult: Equatable, Sendable {
  case applied
  case alreadyAssociated
}

/// Keep current network information within the native join boundary.
struct HotspotAssociation: Sendable {
  let ssid: String
  let isSecure: Bool
}

@MainActor
protocol HotspotConfigurationDriver: AnyObject {
  func configuredSSIDs() async -> [String]
  func apply(_ network: CameraNetwork, password: String, joinOnce: Bool) async throws -> HotspotApplyResult
  func currentAssociation() async -> HotspotAssociation?
  func removeConfiguration(forSSID ssid: String)
}

@MainActor
private final class SystemHotspotConfigurationDriver: HotspotConfigurationDriver {
  func configuredSSIDs() async -> [String] {
    await withCheckedContinuation { continuation in
      NEHotspotConfigurationManager.shared.getConfiguredSSIDs { continuation.resume(returning: $0) }
    }
  }

  func apply(_ network: CameraNetwork, password: String, joinOnce: Bool) async throws -> HotspotApplyResult {
    let configuration = NEHotspotConfiguration(ssid: network.ssid, passphrase: password, isWEP: false)
    configuration.joinOnce = joinOnce
    configuration.hidden = network.isHidden
    do {
      try await NEHotspotConfigurationManager.shared.apply(configuration)
      return .applied
    } catch {
      let native = error as NSError
      guard native.domain == NEHotspotConfigurationErrorDomain,
        let code = NEHotspotConfigurationError(rawValue: native.code)
      else { throw WirelessFailure.routeUnavailable }
      switch code {
      case .alreadyAssociated: return .alreadyAssociated
      case .userDenied, .userUnauthorized, .systemDenied: throw WirelessFailure.permissionDenied(.wifiJoin)
      case .invalidSSID, .invalidWPAPassphrase: throw WirelessFailure.malformedData
      default: throw WirelessFailure.routeUnavailable
      }
    }
  }

  func currentAssociation() async -> HotspotAssociation? {
    await withCheckedContinuation { completion in
      NEHotspotNetwork.fetchCurrent { current in
        completion.resume(returning: current.map { .init(ssid: $0.ssid, isSecure: $0.isSecure) })
      }
    }
  }

  func removeConfiguration(forSSID ssid: String) {
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
  }
}

@MainActor
final class NativeWiFiJoinGateway: WiFiJoinGateway {
  private struct Attempt {
    let id: UUID
    var waiter: CheckedContinuation<JoinedCameraNetwork, Error>?
    var operation: Task<Void, Never>?
    var deadline: Task<Void, Never>?
  }

  private let credentials: any CameraNetworkCredentialProvider
  private let driver: any HotspotConfigurationDriver
  private let sleep: @Sendable (Duration) async throws -> Void
  private var pending: Attempt?
  private var joined: JoinedCameraNetwork?

  init(
    credentials: any CameraNetworkCredentialProvider,
    driver: (any HotspotConfigurationDriver)? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.credentials = credentials
    self.driver = driver ?? SystemHotspotConfigurationDriver()
    self.sleep = sleep
  }

  func join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork {
    try Task.checkCancellation()
    guard pending == nil, joined == nil else { throw WirelessFailure.cameraBusy }
    guard (1...32).contains(network.ssid.utf8.count), !network.ssid.utf8.contains(0) else {
      throw WirelessFailure.malformedData
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter in
        pending = Attempt(id: id, waiter: waiter)
        pending?.operation = Task { await performJoin(network, id: id) }
        pending?.deadline = Task {
          do { try await sleep(WirelessLimits.joinResult) } catch { return }
          resolve(id, with: .failure(WirelessFailure.timeout(.joinResult)))
        }
      }
    } onCancel: {
      Task { @MainActor in self.resolve(id, with: .failure(CancellationError())) }
    }
  }

  func verify(_ network: JoinedCameraNetwork) async throws {
    guard joined == network, let association = await driver.currentAssociation(),
      association.ssid == network.ssid, association.isSecure, joined == network
    else { throw WirelessFailure.routeUnavailable }
    try Task.checkCancellation()
  }

  func leave(_ network: JoinedCameraNetwork) {
    guard joined == network else { return }
    joined = nil
    if network.ownsTemporaryConfiguration { driver.removeConfiguration(forSSID: network.ssid) }
  }

  func drainPendingJoin() async { await pending?.operation?.value }

  private func performJoin(_ network: CameraNetwork, id: UUID) async {
    var ownsConfiguration = false
    defer {
      if ownsConfiguration { driver.removeConfiguration(forSSID: network.ssid) }
      if pending?.id == id { pending = nil }
    }
    do {
      let preexisting = await driver.configuredSSIDs().contains(network.ssid)
      guard hasWaiter(id) else { return }
      if preexisting {
        guard let association = await driver.currentAssociation(),
          association.ssid == network.ssid, association.isSecure
        else { throw WirelessFailure.routeUnavailable }
        guard hasWaiter(id) else { return }
        let receipt = JoinedCameraNetwork(id: id, ssid: network.ssid, ownsTemporaryConfiguration: false)
        joined = receipt
        resolve(id, with: .success(receipt))
        return
      }
      let password = try await credentials.password(for: network.credential)
      guard hasWaiter(id) else { return }
      let result = try await driver.apply(network, password: password, joinOnce: true)
      ownsConfiguration = result == .applied
      // Association can be asynchronous even when the apply callback succeeds.
      while hasWaiter(id) {
        let association = await driver.currentAssociation()
        guard hasWaiter(id) else { return }
        if let association, association.ssid == network.ssid, association.isSecure {
          let receipt = JoinedCameraNetwork(
            id: id, ssid: network.ssid, ownsTemporaryConfiguration: ownsConfiguration)
          ownsConfiguration = false
          joined = receipt
          resolve(id, with: .success(receipt))
          return
        }
        if result == .alreadyAssociated { throw WirelessFailure.routeUnavailable }
        try await sleep(.milliseconds(250))
      }
    } catch {
      resolve(id, with: .failure(error))
    }
  }

  private func hasWaiter(_ id: UUID) -> Bool { pending?.id == id && pending?.waiter != nil }

  private func resolve(_ id: UUID, with result: Result<JoinedCameraNetwork, Error>) {
    guard hasWaiter(id), let waiter = pending?.waiter else { return }
    pending?.waiter = nil
    pending?.deadline?.cancel()
    waiter.resume(with: result)
  }
}
