import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration

struct ProbeWiFiSnapshot: Codable, Sendable {
  let interface: String
  let ssid: Data
}

enum ProbeWiFiWorkerFailure: String, Codable, Error {
  case invalidWorkerRequest, workerUnavailable, workerTimedOut, invalidWorkerResponse
  case currentWiFiUnavailable, currentWiFiNotRemembered, wiredRouteUnavailable
  case associationChanged, cameraNetworkUnavailable, cameraAssociationFailed, restoreUnverified

  /// These join-worker results arise before calling the native association API.
  var stoppedBeforeAssociation: Bool {
    switch self {
    case .invalidWorkerRequest, .workerUnavailable, .currentWiFiUnavailable,
      .wiredRouteUnavailable, .associationChanged, .cameraNetworkUnavailable:
      true
    default:
      false
    }
  }
}

enum ProbeWiFiWorkerRequest: Codable {
  case snapshot
  case scan(ProbeWiFiSnapshot, cameraSSID: Data)
  case join(ProbeWiFiSnapshot, cameraSSID: Data, password: String, wiredInterface: String)
  case verify(ProbeWiFiSnapshot, cameraSSID: Data)
  case restore(ProbeWiFiSnapshot, cameraSSID: Data)
}

enum ProbeWiFiWorkerReply: Codable {
  case snapshot(ProbeWiFiSnapshot)
  case completed
  case failure(ProbeWiFiWorkerFailure)
}

@MainActor
protocol ProbeWiFiAssociating {
  func snapshot() async throws -> ProbeWiFiSnapshot
  func scan(from original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
  func join(
    from original: ProbeWiFiSnapshot, cameraSSID: Data, password: String, wiredInterface: String
  ) async throws
  func verify(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
  func restore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
}

@MainActor
struct ProbeMacWiFiAssociation: ProbeWiFiAssociating {
  func snapshot() async throws -> ProbeWiFiSnapshot {
    let reply = try await call(.snapshot, timeout: .seconds(4))
    guard case .snapshot(let original) = reply else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
    return original
  }

  func scan(from original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.scan(original, cameraSSID: cameraSSID), timeout: .seconds(8))
  }

  func join(
    from original: ProbeWiFiSnapshot, cameraSSID: Data, password: String, wiredInterface: String
  ) async throws {
    try await complete(.join(original, cameraSSID: cameraSSID, password: password,
      wiredInterface: wiredInterface), timeout: .seconds(15))
  }

  func verify(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.verify(original, cameraSSID: cameraSSID), timeout: .seconds(4))
  }

  func restore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.restore(original, cameraSSID: cameraSSID), timeout: .seconds(12))
  }

  private func complete(_ request: ProbeWiFiWorkerRequest, timeout: Duration) async throws {
    let reply = try await call(request, timeout: timeout)
    guard case .completed = reply else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
  }

  private func call(_ request: ProbeWiFiWorkerRequest, timeout: Duration) async throws -> ProbeWiFiWorkerReply {
    guard let executable = Bundle.main.executableURL,
      let input = try? JSONEncoder().encode(request)
    else { throw ProbeWiFiWorkerFailure.workerUnavailable }
    let output = try await ProbeWiFiWorkerProcess().run(
      executable: executable, arguments: ["--wifi-worker"], input: input, timeout: timeout)
    guard let reply = try? JSONDecoder().decode(ProbeWiFiWorkerReply.self, from: output) else {
      throw ProbeWiFiWorkerFailure.invalidWorkerResponse
    }
    if case .failure(let failure) = reply { throw failure }
    return reply
  }
}

enum ProbeWiredRoute {
  static func primaryIPv4Interface() -> String? {
    guard let route = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString)
      as? [String: Any],
      let router = route[kSCPropNetIPv4Router as String] as? String, IPv4Address(router) != nil
    else { return nil }
    return route[kSCDynamicStorePropNetPrimaryInterface as String] as? String
  }

  static func detect() async -> String? {
    guard let primary = primaryIPv4Interface() else { return nil }
    let monitor = NWPathMonitor()
    let (updates, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    monitor.pathUpdateHandler = { path in
      let isWired = path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
        && path.availableInterfaces.contains { $0.type == .wiredEthernet && $0.name == primary }
      continuation.yield(isWired)
    }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(2))
      continuation.finish()
    }
    monitor.start(queue: DispatchQueue(label: "com.lun3x.FujiStudio.MacWirelessProbe.wired"))
    defer {
      monitor.cancel()
      timeout.cancel()
      continuation.finish()
    }
    for await isWired in updates {
      return isWired && primaryIPv4Interface() == primary ? primary : nil
    }
    return nil
  }
}

enum ProbeMacWiFiWorker {
  static func main() -> Int32 {
    let reply: ProbeWiFiWorkerReply
    do {
      let input = try ProbeWiFiWorkerProcess.readBounded(from: .standardInput)
      guard let request = try? JSONDecoder().decode(ProbeWiFiWorkerRequest.self, from: input) else {
        throw ProbeWiFiWorkerFailure.invalidWorkerRequest
      }
      reply = try perform(request)
    } catch let failure as ProbeWiFiWorkerFailure {
      reply = .failure(failure)
    } catch {
      reply = .failure(.invalidWorkerRequest)
    }
    guard let encoded = try? JSONEncoder().encode(reply), encoded.count <= ProbeWiFiWorkerProcess.maximumBytes
    else { return 2 }
    do {
      try FileHandle.standardOutput.write(contentsOf: encoded)
      return 0
    } catch {
      return 2
    }
  }

  private static func perform(_ request: ProbeWiFiWorkerRequest) throws -> ProbeWiFiWorkerReply {
    switch request {
    case .snapshot:
      let interfaces = CWWiFiClient.shared().interfaces()?.filter { $0.powerOn() && $0.serviceActive() } ?? []
      guard interfaces.count == 1, let interface = interfaces.first,
        let name = interface.interfaceName, let ssid = interface.ssidData(), (1...32).contains(ssid.count)
      else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
      guard let profiles = interface.configuration()?.networkProfiles,
        profiles.contains(where: { ($0 as? CWNetworkProfile)?.ssidData == ssid })
      else { throw ProbeWiFiWorkerFailure.currentWiFiNotRemembered }
      return .snapshot(ProbeWiFiSnapshot(interface: name, ssid: ssid))
    case .scan(let original, let cameraSSID):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      guard interface.ssidData() == original.ssid else { throw ProbeWiFiWorkerFailure.associationChanged }
      _ = try cameraNetwork(interface, cameraSSID: cameraSSID)
      return .completed
    case .join(let original, let cameraSSID, let password, let wiredInterface):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      guard (8...63).contains(password.utf8.count), original.interface != wiredInterface else {
        throw ProbeWiFiWorkerFailure.invalidWorkerRequest
      }
      guard interface.ssidData() == original.ssid else { throw ProbeWiFiWorkerFailure.associationChanged }
      let camera = try cameraNetwork(interface, cameraSSID: cameraSSID)
      guard ProbeWiredRoute.primaryIPv4Interface() == wiredInterface else {
        throw ProbeWiFiWorkerFailure.wiredRouteUnavailable
      }
      guard interface.ssidData() == original.ssid else { throw ProbeWiFiWorkerFailure.associationChanged }
      do {
        try interface.associate(to: camera, password: password)
      } catch {
        throw ProbeWiFiWorkerFailure.cameraAssociationFailed
      }
      guard interface.ssidData() == cameraSSID else { throw ProbeWiFiWorkerFailure.cameraAssociationFailed }
      return .completed
    case .verify(let original, let cameraSSID):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      guard interface.ssidData() == cameraSSID else { throw ProbeWiFiWorkerFailure.associationChanged }
      return .completed
    case .restore(let original, let cameraSSID):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      let deadline = ContinuousClock.now + .seconds(8)
      var firstMatch: ContinuousClock.Instant?
      var releasedCamera = false
      repeat {
        let current = interface.ssidData()
        if current == original.ssid {
          if let firstMatch, ContinuousClock.now - firstMatch >= .seconds(1) { return .completed }
          if firstMatch == nil { firstMatch = .now }
        } else if current == cameraSSID {
          firstMatch = nil
          if !releasedCamera {
            interface.disassociate()
            releasedCamera = true
          }
        } else if current == nil {
          firstMatch = nil
        } else {
          // An independent network change is not owned by this attempt.
          throw ProbeWiFiWorkerFailure.restoreUnverified
        }
        Thread.sleep(forTimeInterval: 0.2)
      } while ContinuousClock.now < deadline
      throw ProbeWiFiWorkerFailure.restoreUnverified
    }
  }

  private static func scopedInterface(_ original: ProbeWiFiSnapshot, cameraSSID: Data) throws -> CWInterface {
    guard (1...32).contains(original.ssid.count), (1...32).contains(cameraSSID.count),
      cameraSSID != original.ssid,
      let interface = CWWiFiClient.shared().interface(withName: original.interface),
      interface.powerOn(), interface.serviceActive()
    else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
    return interface
  }

  private static func cameraNetwork(_ interface: CWInterface, cameraSSID: Data) throws -> CWNetwork {
    let candidates = try? interface.scanForNetworks(withSSID: cameraSSID, includeHidden: true)
    let security: [CWSecurity] = [.wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition]
    let matching = candidates?.filter { network in
      network.ssidData == cameraSSID && security.contains(where: network.supportsSecurity)
    }
    guard let matching, matching.count == 1, let camera = matching.first else {
      throw ProbeWiFiWorkerFailure.cameraNetworkUnavailable
    }
    return camera
  }
}
