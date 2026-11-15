import CoreLocation
import Foundation

enum ProbeWiFiLocationStatus: String, Codable, Sendable {
  case notDetermined, denied, restricted, authorizedAlways, authorizedWhenInUse, unknown, initialCallbackTimedOut

  var authorized: Bool { self == .authorizedAlways || self == .authorizedWhenInUse }

  init(_ status: CLAuthorizationStatus) {
    self = switch status {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .restricted: .restricted
    case .authorizedAlways: .authorizedAlways
    case .authorizedWhenInUse: .authorizedWhenInUse
    @unknown default: .unknown
    }
  }
}

@MainActor
final class ProbeWiFiLocationReadiness {
  private(set) var current: ProbeWiFiLocationStatus?
  private var waiting: AsyncStream<ProbeWiFiLocationStatus>.Continuation?

  func observe(_ status: ProbeWiFiLocationStatus) {
    current = status
    waiting?.yield(status)
  }

  func waitForInitialCallback(timeout: Duration = .seconds(1)) async -> ProbeWiFiLocationStatus {
    if let current { return current }
    let (updates, continuation) = AsyncStream<ProbeWiFiLocationStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
    waiting = continuation
    let deadline = Task {
      do { try await Task.sleep(for: timeout) } catch { return }
      continuation.finish()
    }
    defer {
      deadline.cancel()
      continuation.finish()
      waiting = nil
    }
    for await _ in updates {
      if let current { return current }
    }
    return current ?? .initialCallbackTimedOut
  }
}

/// Creating this observer does not request permission or start location updates.
@MainActor
final class ProbeWiFiLocationAuthorization: NSObject, @preconcurrency CLLocationManagerDelegate {
  let readiness = ProbeWiFiLocationReadiness()
  private let manager = CLLocationManager()

  override init() {
    super.init()
    manager.delegate = self
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    readiness.observe(ProbeWiFiLocationStatus(manager.authorizationStatus))
  }

  func requestFromExplicitPreflight() {
    guard readiness.current == .notDetermined else { return }
    manager.requestWhenInUseAuthorization()
  }

  /// The diagnostic worker has no application loop. Give its manager's
  /// creating thread a bounded run loop window to receive the initial callback.
  func observeInWorker() -> ProbeWiFiLocationStatus {
    let deadline = ContinuousClock.now + .seconds(1)
    while readiness.current == nil && ContinuousClock.now < deadline {
      if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) {
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    return readiness.current ?? .initialCallbackTimedOut
  }
}
