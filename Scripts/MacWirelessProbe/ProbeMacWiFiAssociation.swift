import CoreWLAN
import CoreFoundation
import Darwin
import Foundation
import Network
import SystemConfiguration

enum ProbeWiFiLinkObservation {
  static func active(_ value: Any?) -> Bool? {
    guard let active = value as? NSNumber,
      CFGetTypeID(active) == CFBooleanGetTypeID()
    else { return nil }
    return active.boolValue
  }

  static func isExplicitlyUnassociated(ssid: Data?, activeValue: Any?) -> Bool {
    ssid == nil && active(activeValue) == false
  }
}

struct ProbeWiFiSnapshot: Codable, Equatable, Sendable {
  let interface: String
  let ssid: Data
  let primaryRouter: String?

  init(interface: String, ssid: Data, primaryRouter: String? = nil) {
    self.interface = interface
    self.ssid = ssid
    self.primaryRouter = primaryRouter
  }

  var savedNetworkName: String? {
    guard (1...32).contains(ssid.count), let name = String(data: ssid, encoding: .utf8),
      !name.utf8.contains(0)
    else { return nil }
    return name
  }
}

enum ProbeWiFiWorkerFailure: String, Codable, Error {
  case invalidWorkerRequest, workerUnavailable, workerTimedOut, invalidWorkerResponse
  case currentWiFiUnavailable, currentWiFiNotRemembered, wiredRouteUnavailable
  case associationChanged, cameraNetworkUnavailable, cameraAssociationFailed, restoreUnverified
  case wifiRouteUnavailable, internetCheckFailed, restoreRehearsalRequired, associationGapUnobserved
  case parentWiFiReadBusy, parentWiFiReadTimedOut

  /// These join-worker results arise before calling the native association API.
  var stoppedBeforeAssociation: Bool {
    switch self {
    case .invalidWorkerRequest, .workerUnavailable, .currentWiFiUnavailable,
      .wiredRouteUnavailable, .wifiRouteUnavailable, .associationChanged, .cameraNetworkUnavailable:
      true
    default:
      false
    }
  }
}

enum ProbeCameraWiFiRoute: Codable {
  case wired(String), wifiOnly
}

enum ProbeWiFiWorkerRequest: Codable {
  case snapshot
  case inspect
  case inspectLocation
  case scan(ProbeWiFiSnapshot, cameraSSID: Data)
  case join(ProbeWiFiSnapshot, cameraSSID: Data, password: String, route: ProbeCameraWiFiRoute)
  case verify(ProbeWiFiSnapshot, cameraSSID: Data)
  case restore(ProbeWiFiSnapshot, cameraSSID: Data)
  case rehearsalGap(ProbeWiFiSnapshot)
  case releaseCameraForRestore(ProbeWiFiSnapshot, cameraSSID: Data)
  case verifyPrevious(ProbeWiFiSnapshot)
}

enum ProbeWiFiWorkerReply: Codable {
  case snapshot(ProbeWiFiSnapshot)
  case inspection(ProbeWiFiInterfaceInspection)
  case locationInspection(ProbeWiFiInterfaceInspection, authorization: ProbeWiFiLocationStatus)
  case completed
  case failure(ProbeWiFiWorkerFailure)
}

@MainActor
protocol ProbeWiFiAssociating {
  func snapshot() async throws -> ProbeWiFiSnapshot
  func scan(from original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
  func join(
    from original: ProbeWiFiSnapshot, cameraSSID: Data, password: String, route: ProbeCameraWiFiRoute
  ) async throws
  func verify(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
  func restore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
}

@MainActor
struct ProbeMacWiFiAssociation: ProbeWiFiOnlyAssociating {
  func snapshot() async throws -> ProbeWiFiSnapshot {
    let reply = try await call(.snapshot, timeout: .seconds(4))
    guard case .snapshot(let original) = reply else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
    return original
  }

  func inspect() async throws -> ProbeWiFiInterfaceInspection {
    let reply = try await call(.inspect, timeout: .seconds(4))
    guard case .inspection(let observation) = reply else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
    return observation
  }

  func inspectLocation() async throws -> (ProbeWiFiInterfaceInspection, ProbeWiFiLocationStatus) {
    let reply = try await call(.inspectLocation, timeout: .seconds(4))
    guard case .locationInspection(let observation, let authorization) = reply
    else { throw ProbeWiFiWorkerFailure.invalidWorkerResponse }
    return (observation, authorization)
  }

  func scan(from original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.scan(original, cameraSSID: cameraSSID), timeout: .seconds(8))
  }

  func join(
    from original: ProbeWiFiSnapshot, cameraSSID: Data, password: String, route: ProbeCameraWiFiRoute
  ) async throws {
    try await complete(.join(original, cameraSSID: cameraSSID, password: password,
      route: route), timeout: .seconds(15))
  }

  func verify(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.verify(original, cameraSSID: cameraSSID), timeout: .seconds(4))
  }

  func restore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.restore(original, cameraSSID: cameraSSID), timeout: .seconds(12))
  }

  func checkInternet(_ original: ProbeWiFiSnapshot) async throws {
    guard ProbeWiredRoute.isPrimaryWiFi(original) else {
      throw ProbeWiFiWorkerFailure.wifiRouteUnavailable
    }
    let output = try await ProbeWiFiWorkerProcess().run(
      executable: URL(filePath: "/usr/bin/curl"), arguments: [
        "-q", "--noproxy", "*", "--proto", "=https", "--ipv4", "--interface", original.interface,
        "--connect-timeout", "2", "--max-time", "4", "--retry", "0", "--fail", "--silent",
        "--output", "/dev/null", "--write-out", "%{http_code}", "https://www.apple.com/",
      ], input: Data(), timeout: .seconds(5))
    guard output.count == 3, let status = Int(String(decoding: output, as: UTF8.self)),
      (200..<300).contains(status)
    else { throw ProbeWiFiWorkerFailure.internetCheckFailed }
    guard ProbeWiredRoute.isPrimaryWiFi(original) else {
      throw ProbeWiFiWorkerFailure.wifiRouteUnavailable
    }
  }

  func rehearsalGap(_ original: ProbeWiFiSnapshot) async throws {
    try await complete(.rehearsalGap(original), timeout: .seconds(5))
  }

  func releaseCameraForRestore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    try await complete(.releaseCameraForRestore(original, cameraSSID: cameraSSID), timeout: .seconds(5))
  }

  func reassociateSaved(_ original: ProbeWiFiSnapshot) async throws {
    guard let executable = Bundle.main.executableURL, let input = try? JSONEncoder().encode(original)
    else { throw ProbeWiFiWorkerFailure.workerUnavailable }
    _ = try await ProbeWiFiWorkerProcess().run(
      executable: executable, arguments: ["--wifi-reassociate"], input: input,
      timeout: .seconds(10), discardOutput: true)
  }

  func verifyPrevious(_ original: ProbeWiFiSnapshot) async throws {
    try await complete(.verifyPrevious(original), timeout: .seconds(12))
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
  static func primaryIPv4() -> (interface: String, router: String)? {
    guard let route = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString)
      as? [String: Any],
      let router = route[kSCPropNetIPv4Router as String] as? String, IPv4Address(router) != nil,
      let interface = route[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    else { return nil }
    return (interface, router)
  }

  static func primaryIPv4Interface() -> String? { primaryIPv4()?.interface }

  static func isPrimaryWiFi(_ original: ProbeWiFiSnapshot) -> Bool {
    guard let route = primaryIPv4(), let expectedRouter = original.primaryRouter else { return false }
    return route.interface == original.interface && route.router == expectedRouter
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
  private struct InterfaceReading {
    let observation: ProbeWiFiInterfaceInspection
    let interface: CWInterface?
    let name: String?
    let ssid: Data?
  }

  static func inspectCurrentInterface() -> ProbeWiFiInterfaceInspection {
    readCurrentInterface().observation
  }

  private static func readCurrentInterface() -> InterfaceReading {
    let interfaces = CWWiFiClient.shared().interfaces()
    let measured = interfaces?.map { interface in
      (interface: interface, powered: interface.powerOn(), serviceActive: interface.serviceActive())
    } ?? []
    let eligible = measured.filter { $0.powered && $0.serviceActive }
    let selected = eligible.count == 1 ? eligible.first : (measured.count == 1 ? measured.first : nil)
    let interface = selected?.interface
    let name = interface?.interfaceName
    let shouldReadSSID = eligible.count == 1 && name != nil
    let ssid = shouldReadSSID ? interface?.ssidData() : nil
    let observation = ProbeWiFiInterfaceInspection(
      interfaces: interfaces?.count, eligible: interfaces.map { _ in eligible.count },
      named: selected.map { _ in name != nil }, powered: selected?.powered, serviceActive: selected?.serviceActive,
      ssidChecked: shouldReadSSID, ssid: ssid)
    return InterfaceReading(observation: observation, interface: interface, name: name, ssid: ssid)
  }

  // The parent supervises this same PID after exec. The saved SSID is the only
  // private argument passed to Apple's utility, and no password is supplied.
  static func reassociate() -> Int32 {
    guard let input = try? ProbeWiFiWorkerProcess.readBounded(from: .standardInput),
      let original = try? JSONDecoder().decode(ProbeWiFiSnapshot.self, from: input),
      let name = original.savedNetworkName,
      let interface = try? originalInterface(original)
    else { return 2 }
    let executable = "/usr/sbin/networksetup"
    var arguments = [executable, "-setairportnetwork", original.interface, name].map { strdup($0) }
    defer { for argument in arguments { free(argument) } }
    guard arguments.allSatisfy({ $0 != nil }) else { return 2 }
    arguments.append(nil)
    guard isExplicitlyUnassociated(interface) else { return 2 }
    _ = execv(executable, &arguments)
    return 2
  }

  @MainActor
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

  @MainActor
  private static func perform(_ request: ProbeWiFiWorkerRequest) throws -> ProbeWiFiWorkerReply {
    switch request {
    case .inspect:
      return .inspection(inspectCurrentInterface())
    case .inspectLocation:
      let location = ProbeWiFiLocationAuthorization()
      let authorization = location.observeInWorker()
      return withExtendedLifetime(location) {
        .locationInspection(inspectCurrentInterface(), authorization: authorization)
      }
    case .snapshot:
      let reading = readCurrentInterface()
      guard let interface = reading.interface, let name = reading.name,
        let ssid = reading.ssid, reading.observation.ssidLengthValid == true
      else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
      guard let profiles = interface.configuration()?.networkProfiles,
        profiles.contains(where: { ($0 as? CWNetworkProfile)?.ssidData == ssid })
      else { throw ProbeWiFiWorkerFailure.currentWiFiNotRemembered }
      let route = ProbeWiredRoute.primaryIPv4()
      let router = route?.interface == name ? route?.router : nil
      return .snapshot(ProbeWiFiSnapshot(interface: name, ssid: ssid, primaryRouter: router))
    case .scan(let original, let cameraSSID):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      guard interface.ssidData() == original.ssid else { throw ProbeWiFiWorkerFailure.associationChanged }
      _ = try cameraNetwork(interface, cameraSSID: cameraSSID)
      return .completed
    case .join(let original, let cameraSSID, let password, let route):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      guard (8...63).contains(password.utf8.count) else {
        throw ProbeWiFiWorkerFailure.invalidWorkerRequest
      }
      guard interface.ssidData() == original.ssid else { throw ProbeWiFiWorkerFailure.associationChanged }
      let camera = try cameraNetwork(interface, cameraSSID: cameraSSID)
      switch route {
      case .wired(let wiredInterface):
        guard wiredInterface != original.interface, ProbeWiredRoute.primaryIPv4Interface() == wiredInterface
        else { throw ProbeWiFiWorkerFailure.wiredRouteUnavailable }
      case .wifiOnly:
        guard ProbeWiredRoute.isPrimaryWiFi(original)
        else { throw ProbeWiFiWorkerFailure.wifiRouteUnavailable }
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
    case .rehearsalGap(let original):
      let interface = try originalInterface(original)
      guard interface.ssidData() == original.ssid, ProbeWiFiLinkObservation.active(linkActiveValue(interface)) == true
      else { throw ProbeWiFiWorkerFailure.associationChanged }
      guard ProbeWiredRoute.isPrimaryWiFi(original)
      else { throw ProbeWiFiWorkerFailure.wifiRouteUnavailable }
      interface.disassociate()
      let deadline = ContinuousClock.now + .seconds(2)
      repeat {
        if isExplicitlyUnassociated(interface) { return .completed }
        Thread.sleep(forTimeInterval: 0.05)
      } while ContinuousClock.now < deadline
      throw ProbeWiFiWorkerFailure.associationGapUnobserved
    case .releaseCameraForRestore(let original, let cameraSSID):
      let interface = try scopedInterface(original, cameraSSID: cameraSSID)
      let current = interface.ssidData()
      if current == cameraSSID {
        interface.disassociate()
        let deadline = ContinuousClock.now + .seconds(2)
        while interface.ssidData() == cameraSSID {
          guard ContinuousClock.now < deadline else { throw ProbeWiFiWorkerFailure.restoreUnverified }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
      else if current != nil && current != original.ssid { throw ProbeWiFiWorkerFailure.restoreUnverified }
      return .completed
    case .verifyPrevious(let original):
      let interface = try originalInterface(original)
      let deadline = ContinuousClock.now + .seconds(8)
      var firstMatch: ContinuousClock.Instant?
      repeat {
        let current = interface.ssidData()
        if current == original.ssid {
          if let firstMatch, ContinuousClock.now - firstMatch >= .seconds(1) { return .completed }
          if firstMatch == nil { firstMatch = .now }
        } else {
          firstMatch = nil
        }
        Thread.sleep(forTimeInterval: 0.2)
      } while ContinuousClock.now < deadline
      throw ProbeWiFiWorkerFailure.restoreUnverified
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
      cameraSSID != original.ssid
    else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
    return try originalInterface(original)
  }

  private static func originalInterface(_ original: ProbeWiFiSnapshot) throws -> CWInterface {
    guard let interface = CWWiFiClient.shared().interface(withName: original.interface),
      interface.interfaceName == original.interface, interface.powerOn(), interface.serviceActive()
    else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
    return interface
  }

  private static func isExplicitlyUnassociated(_ interface: CWInterface) -> Bool {
    let ssid = interface.ssidData()
    return ProbeWiFiLinkObservation.isExplicitlyUnassociated(ssid: ssid, activeValue: linkActiveValue(interface))
  }

  private static func linkActiveValue(_ interface: CWInterface) -> Any? {
    guard let name = interface.interfaceName else { return nil }
    let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
      nil, kSCDynamicStoreDomainState, name as CFString, kSCEntNetLink)
    let link = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
    return link?[kSCPropNetLinkActive as String]
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
