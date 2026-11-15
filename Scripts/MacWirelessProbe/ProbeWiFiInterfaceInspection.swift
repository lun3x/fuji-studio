import Foundation

struct ProbeWiFiInterfaceInspection: Codable, Equatable, Sendable {
  enum Count: String, Codable, Sendable {
    case unavailable, none, one, multiple

    init(_ count: Int?) {
      switch count {
      case nil: self = .unavailable
      case 0: self = .none
      case 1: self = .one
      default: self = .multiple
      }
    }
  }

  let interfaces: Count
  let eligible: Count
  let named: Bool?
  let powered: Bool?
  let serviceActive: Bool?
  let ssidReadable: Bool?
  let ssidLengthValid: Bool?

  init(
    interfaces: Int?, eligible: Int?, named: Bool?, powered: Bool?, serviceActive: Bool?,
    ssidChecked: Bool, ssid: Data?
  ) {
    self.interfaces = Count(interfaces)
    self.eligible = Count(eligible)
    self.named = named
    self.powered = powered
    self.serviceActive = serviceActive
    ssidReadable = ssidChecked ? ssid != nil : nil
    ssidLengthValid = ssidChecked ? ssid.map { (1...32).contains($0.count) } : nil
  }

  var status: String {
    func label(_ value: Bool?) -> String { value.map(String.init) ?? "notChecked" }
    return [
      "interfaces:\(interfaces.rawValue)", "eligible:\(eligible.rawValue)", "named:\(label(named))",
      "powered:\(label(powered))", "serviceActive:\(label(serviceActive))",
      "ssidReadable:\(label(ssidReadable))", "ssidLengthValid:\(label(ssidLengthValid))",
    ].joined(separator: " ")
  }
}

/// A bounded wait for a read-only parent observation. A stalled native read
/// remains fenced off the app's main actor until it returns.
@MainActor
final class ProbeWiFiParentInspection {
  private var reading = false

  func inspect(
    timeout: Duration = .seconds(2),
    read: @escaping @Sendable () -> ProbeWiFiInterfaceInspection
  ) async throws -> ProbeWiFiInterfaceInspection {
    try Task.checkCancellation()
    guard !reading else { throw ProbeWiFiWorkerFailure.parentWiFiReadBusy }
    reading = true
    let (results, continuation) = AsyncStream<ProbeWiFiInterfaceInspection>.makeStream(bufferingPolicy: .bufferingNewest(1))
    Task { [weak self] in
      let result = await Task.detached(operation: read).value
      self?.reading = false
      continuation.yield(result)
      continuation.finish()
    }
    let deadline = Task {
      do { try await Task.sleep(for: timeout) } catch { return }
      continuation.finish()
    }
    defer {
      deadline.cancel()
      continuation.finish()
    }
    for await result in results {
      try Task.checkCancellation()
      return result
    }
    try Task.checkCancellation()
    throw ProbeWiFiWorkerFailure.parentWiFiReadTimedOut
  }
}
