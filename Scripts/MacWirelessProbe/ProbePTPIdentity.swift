import Foundation
import FujiCameraCore

enum ProbeWiFiRestoration: String {
  case notAttempted, previousAssociationObserved, unverified
}

struct ProbePTPIdentityReport {
  var launch: ProbeWiFiLaunch?
  var outcome = "notRun"
  var associated = false
  var verified = false
  var firmware = "unavailable"
  var restoration = ProbeWiFiRestoration.notAttempted
}

@MainActor
enum ProbePTPIdentity {
  static func preflight(association: any ProbeWiFiAssociating, wiredRoute: () async -> String?) async throws {
    try Task.checkCancellation()
    guard await wiredRoute() != nil else { throw ProbeWiFiWorkerFailure.wiredRouteUnavailable }
    try Task.checkCancellation()
    _ = try await association.snapshot()
    try Task.checkCancellation()
  }

  static func run(
    _ receipt: ProbeReadyCameraNetwork,
    currentIdentity: WirelessIdentity,
    credentials: any CameraNetworkCredentialProvider,
    association: any ProbeWiFiAssociating,
    wiredRoute: () async -> String?,
    isCurrent: () -> Bool,
    ptpTimeout: Duration = .seconds(20),
    makeSession: @escaping @Sendable (WirelessIdentity) async throws -> any WirelessTransferSession
  ) async -> ProbePTPIdentityReport {
    var report = ProbePTPIdentityReport(launch: receipt.launch)
    let cameraSSID = Data(receipt.network.ssid.utf8)
    var recovery: ProbeWiFiSnapshot?
    do {
      try checkAttempt(isCurrent)
      guard currentIdentity == receipt.identity, currentIdentity.model == .xt5,
        receipt.network.credential.cameraID == currentIdentity.cameraID,
        receipt.network.security == .wpaPersonal,
        (1...32).contains(cameraSSID.count)
      else { throw WirelessFailure.peerMismatch }
      try checkFirmware(currentIdentity)

      guard await wiredRoute() != nil else { throw ProbeWiFiWorkerFailure.wiredRouteUnavailable }
      let original = try await association.snapshot()
      try checkAttempt(isCurrent)
      guard original.ssid != cameraSSID else { throw ProbeWiFiWorkerFailure.associationChanged }
      try await association.scan(from: original, cameraSSID: cameraSSID)
      try checkAttempt(isCurrent)
      let password = try await credentials.password(for: receipt.network.credential)
      guard let wiredInterface = await wiredRoute() else { throw ProbeWiFiWorkerFailure.wiredRouteUnavailable }
      try checkAttempt(isCurrent)

      recovery = original
      do {
        try await association.join(from: original, cameraSSID: cameraSSID, password: password, wiredInterface: wiredInterface)
      } catch let failure as ProbeWiFiWorkerFailure where failure.stoppedBeforeAssociation {
        recovery = nil
        throw failure
      }
      try checkAttempt(isCurrent)
      try await association.verify(original, cameraSSID: cameraSSID)
      report.associated = true
      try checkAttempt(isCurrent)

      let identity = try await readIdentity(expected: currentIdentity, timeout: ptpTimeout, makeSession: makeSession)
      try checkAttempt(isCurrent)
      try await association.verify(original, cameraSSID: cameraSSID)
      try checkAttempt(isCurrent)
      guard identity.cameraID == currentIdentity.cameraID, identity.model == currentIdentity.model else {
        throw WirelessFailure.peerMismatch
      }
      report.firmware = ProbeFirmwareObservation.label(identity.firmware)
      try checkFirmware(identity)
      report.verified = true
      report.outcome = "ptpIdentityVerified"
    } catch {
      report.outcome = failureLabel(error)
    }

    if let recovery {
      // The enclosing task may have been cancelled after association changed.
      // The independent cleanup must still run after the failed operation retired.
      let restore = Task { try await association.restore(recovery, cameraSSID: cameraSSID) }
      do {
        try await restore.value
        report.restoration = .previousAssociationObserved
      } catch {
        report.restoration = .unverified
      }
    }
    if report.verified {
      do {
        try checkAttempt(isCurrent)
      } catch {
        report.verified = false
        report.outcome = failureLabel(error)
      }
    }
    return report
  }

  private static func checkAttempt(_ isCurrent: () -> Bool) throws {
    try Task.checkCancellation()
    guard isCurrent() else { throw WirelessFailure.peerMismatch }
  }

  private static func checkFirmware(_ identity: WirelessIdentity) throws {
    guard WirelessSupportPolicy().assess(model: identity.model.rawValue, firmware: identity.firmware)
      == .supported(identity.model)
    else { throw WirelessFailure.unsupportedFirmware }
  }

  private static func readIdentity(
    expected: WirelessIdentity, timeout: Duration,
    makeSession: @escaping @Sendable (WirelessIdentity) async throws -> any WirelessTransferSession
  ) async throws -> WirelessIdentity {
    try await withThrowingTaskGroup(of: WirelessIdentity.self) { group in
      group.addTask {
        let session = try await makeSession(expected)
        let observed: WirelessIdentity
        do {
          try Task.checkCancellation()
          observed = try await session.open()
        } catch {
          try? await session.close()
          throw error
        }
        try await session.close()
        return observed
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WirelessFailure.timeout(.transactionInactivity)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw WirelessFailure.connectionLost }
      return result
    }
  }

  static func failureLabel(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    if let failure = error as? ProbeWiFiWorkerFailure { return failure.rawValue }
    if let failure = error as? WirelessFailure {
      if case .timeout(let stage) = failure { return "timeout(\(stage))" }
      if case .permissionDenied(let permission) = failure { return "permissionDenied(\(permission))" }
      return String(describing: failure)
    }
    if error is PTPError { return "ptpProtocolFailure" }
    return "unclassifiedError"
  }
}
