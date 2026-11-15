import Foundation
import FujiCameraCore

@main
@MainActor
private struct PTPIdentityTests {
  static func main() async throws {
    let discovery = Scenario()
    try await discovery.preflight()
    precondition(discovery.steps == ["wired", "capture"])
    let cancelledDiscovery = Scenario()
    cancelledDiscovery.cancelAtSnapshot = true
    let preflightCancelled = await Task {
      do {
        try await cancelledDiscovery.preflight()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    precondition(preflightCancelled && cancelledDiscovery.steps == ["wired", "capture"])

    let success = Scenario()
    let result = await success.run()
    precondition(result.launch == .imageViewing && result.outcome == "ptpIdentityVerified")
    precondition(result.associated && result.verified && result.firmware == "04.31")
    precondition(result.restoration == .previousAssociationObserved)
    precondition(success.steps == [
      "wired", "capture", "scan", "credential", "wired", "join", "verify target",
      "session", "open", "close", "verify target", "restore",
    ])

    let routeLost = Scenario()
    routeLost.routes = ["wired", nil]
    let blocked = await routeLost.run()
    precondition(blocked.outcome == "wiredRouteUnavailable" && blocked.restoration == .notAttempted)
    precondition(!routeLost.steps.contains("join"))

    let scanDenied = Scenario()
    scanDenied.scanFails = true
    let noScan = await scanDenied.run()
    precondition(noScan.outcome == "cameraNetworkUnavailable" && noScan.restoration == .notAttempted)
    precondition(scanDenied.steps == ["wired", "capture", "scan"])

    let changedIdentity = Scenario()
    let wrongPeer = await changedIdentity.run(currentIdentity: .init(cameraID: .init(), model: .xt5, firmware: "04.31"))
    precondition(wrongPeer.outcome == "peerMismatch" && changedIdentity.steps.isEmpty)

    let staleSelection = Scenario()
    staleSelection.isCurrent = false
    let stale = await staleSelection.run()
    precondition(stale.outcome == "peerMismatch" && staleSelection.steps.isEmpty)

    let joinTimedOut = Scenario()
    joinTimedOut.joinError = ProbeWiFiWorkerFailure.workerTimedOut
    let timeout = await joinTimedOut.run()
    precondition(timeout.outcome == "workerTimedOut" && !timeout.associated)
    precondition(timeout.restoration == .previousAssociationObserved)
    precondition(joinTimedOut.steps.suffix(2) == ["join", "restore"])

    let preventedJoin = Scenario()
    preventedJoin.joinError = ProbeWiFiWorkerFailure.associationChanged
    let unchanged = await preventedJoin.run()
    precondition(unchanged.outcome == "associationChanged" && unchanged.restoration == .notAttempted)
    precondition(preventedJoin.steps.last == "join")

    let wrongAssociation = Scenario()
    wrongAssociation.failVerification = 1
    let associationFailure = await wrongAssociation.run()
    precondition(associationFailure.outcome == "associationChanged" && !associationFailure.verified)
    precondition(wrongAssociation.steps.suffix(2) == ["verify target", "restore"])
    precondition(!wrongAssociation.steps.contains("session"))

    let drift = Scenario()
    drift.failVerification = 2
    let afterOpen = await drift.run()
    precondition(afterOpen.associated && !afterOpen.verified && afterOpen.outcome == "associationChanged")
    precondition(drift.steps.suffix(3) == ["close", "verify target", "restore"])

    let oldBody = Scenario()
    oldBody.observedFirmware = "4.29"
    let old = await oldBody.run()
    precondition(old.outcome == "unsupportedFirmware" && !old.verified && old.firmware == "4.29")
    precondition(old.restoration == .previousAssociationObserved)

    let wrongBody = Scenario()
    wrongBody.observedModel = .xe3
    let mismatch = await wrongBody.run()
    precondition(mismatch.outcome == "peerMismatch" && !mismatch.verified && mismatch.firmware == "unavailable")

    let transferRefused = Scenario()
    transferRefused.openError = PTPError.authorizationDenied
    let refused = await transferRefused.run()
    precondition(refused.outcome == "ptpProtocolFailure" && !refused.verified)
    precondition(transferRefused.steps.suffix(3) == ["open", "close", "restore"])

    let restoreFails = Scenario()
    restoreFails.restoreFails = true
    let unverifiedRestore = await restoreFails.run()
    precondition(unverifiedRestore.verified && unverifiedRestore.restoration == .unverified)

    let savedChanged = Scenario()
    savedChanged.revokeAtRestore = true
    let revoked = await savedChanged.run()
    precondition(revoked.outcome == "peerMismatch" && !revoked.verified)
    precondition(revoked.restoration == .previousAssociationObserved)

    let lostBLE = Scenario()
    lostBLE.revokeAtOpen = true
    let noLink = await lostBLE.run()
    precondition(noLink.outcome == "peerMismatch" && !noLink.verified)
    precondition(lostBLE.steps.suffix(3) == ["open", "close", "restore"])

    let cancelledJoin = Scenario()
    cancelledJoin.cancelAtJoin = true
    let cancelled = await Task { await cancelledJoin.run() }.value
    precondition(cancelled.outcome == "cancelled" && !cancelled.verified)
    precondition(cancelled.restoration == .previousAssociationObserved)
    precondition(cancelledJoin.steps.suffix(2) == ["join", "restore"])

    let cancelledPTP = Scenario()
    cancelledPTP.holdOpen = true
    let task = Task { await cancelledPTP.run() }
    for _ in 0..<100 where !cancelledPTP.steps.contains("open") {
      try await Task.sleep(for: .milliseconds(2))
    }
    precondition(cancelledPTP.steps.contains("open"))
    task.cancel()
    let aborted = await task.value
    precondition(aborted.outcome == "cancelled" && !aborted.verified)
    precondition(cancelledPTP.steps.suffix(3) == ["open", "close", "restore"])

    let stalledPTP = Scenario()
    stalledPTP.holdOpen = true
    let stalled = await stalledPTP.run(ptpTimeout: .milliseconds(50))
    precondition(stalled.outcome == "timeout(transactionInactivity)" && !stalled.verified, stalled.outcome)
    precondition(stalledPTP.steps.suffix(3) == ["open", "close", "restore"])
    print("PTP identity admission, selected-link loss, timeout, socket close, and restoration checks passed.")

    try await checkWiFiOnlyRecovery()
    try await checkWorkerSupervision()
  }

  private static func checkWiFiOnlyRecovery() async throws {
    let normal = Scenario()
    var rehearsed = await ProbeWiFiOnlyRecovery.rehearse(normal)
    precondition(rehearsed.outcome == "restoreRehearsalVerified" && rehearsed.gapObserved)
    precondition(rehearsed.exactRestoreCommandCompleted && rehearsed.restorationVerified)
    precondition(normal.steps == ["capture", "internet", "capture", "gap", "saved rejoin", "verify previous", "internet", "capture"])
    let receipt = rehearsed.takeReceipt()!
    precondition(rehearsed.takeReceipt() == nil)
    try receipt.validate(normal.original)

    let expired = Scenario()
    let expiredReceipt = ProbeWiFiOnlyReceipt(original: expired.original, expiresAt: .now - .seconds(1))
    let old = await expired.run(wifiOnly: expiredReceipt)
    precondition(old.outcome == "restoreRehearsalRequired" && !expired.steps.contains("join"))

    let changed = Scenario()
    let unrelated = ProbeWiFiSnapshot(interface: changed.original.interface, ssid: changed.original.ssid, primaryRouter: "changed")
    changed.snapshotOverride = unrelated
    let replaced = await changed.run(wifiOnly: receipt)
    precondition(replaced.outcome == "restoreRehearsalRequired" && !changed.steps.contains("join"))

    let noGap = Scenario()
    noGap.gapError = ProbeWiFiWorkerFailure.associationGapUnobserved
    let noOp = await ProbeWiFiOnlyRecovery.rehearse(noGap)
    precondition(noOp.outcome == "associationGapUnobserved" && !noOp.gapObserved && noOp.receipt == nil)
    precondition(noOp.restorationVerified)

    let autoJoin = Scenario()
    autoJoin.savedRejoinFails = true
    let unproven = await ProbeWiFiOnlyRecovery.rehearse(autoJoin)
    precondition(unproven.outcome == "exactRestoreUnproven" && unproven.restorationVerified && unproven.receipt == nil)

    let late = Scenario()
    late.cancelAtGap = true
    let cancelled = await Task { await ProbeWiFiOnlyRecovery.rehearse(late) }.value
    precondition(cancelled.outcome == "cancelled" && cancelled.restorationVerified && cancelled.receipt == nil)
    precondition(late.steps.contains("saved rejoin"))

    let timedOut = Scenario()
    timedOut.gapError = ProbeWiFiWorkerFailure.workerTimedOut
    let recovered = await ProbeWiFiOnlyRecovery.rehearse(timedOut)
    precondition(recovered.outcome == "workerTimedOut" && recovered.restorationVerified && recovered.receipt == nil)

    let restoreFails = Scenario()
    restoreFails.previousVerificationFails = true
    let failed = await ProbeWiFiOnlyRecovery.rehearse(restoreFails)
    precondition(failed.outcome == "restoreUnverified" && failed.receipt == nil)

    let unrelatedAssociation = Scenario()
    unrelatedAssociation.releaseCameraFails = true
    unrelatedAssociation.previousVerificationFails = true
    let unrelatedResult = await unrelatedAssociation.run(wifiOnly: receipt)
    precondition(unrelatedResult.restoration == .unverified && !unrelatedAssociation.steps.contains("saved rejoin"))

    let interruptedRelease = Scenario()
    interruptedRelease.releaseCameraError = ProbeWiFiWorkerFailure.workerTimedOut
    let afterReleaseTimeOut = await interruptedRelease.run(wifiOnly: receipt)
    precondition(afterReleaseTimeOut.restoration == .previousAssociationObserved)
    precondition(interruptedRelease.steps.contains("saved rejoin"))

    let offline = Scenario()
    let result = await offline.run(wifiOnly: receipt)
    precondition(result.verified && result.restoration == .previousAssociationObserved)
    precondition(!offline.steps.contains("wired") && offline.steps.contains("wifi-only join"))
    precondition(offline.steps.suffix(6) == ["verify target", "release camera", "saved rejoin", "verify previous", "internet", "capture"])

    let redacted = Scenario()
    redacted.gapError = NSError(domain: "synthetic-private", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "synthetic-private-SSID"])
    let safe = await ProbeWiFiOnlyRecovery.rehearse(redacted)
    precondition(safe.outcome == "unclassifiedError" && safe.receipt == nil)
    precondition(ProbeWiFiSnapshot(interface: "wireless", ssid: Data([0x41, 0])).savedNetworkName == nil)
    precondition(ProbeWiFiSnapshot(interface: "wireless", ssid: Data([0xff])).savedNetworkName == nil)
    print("Wi-Fi-only rehearsal, one-use restore admission, cancellation, and redaction checks passed.")
  }

  private static func checkWorkerSupervision() async throws {
    let worker = ProbeWiFiWorkerProcess()
    let data = Data("synthetic-target-and-password".utf8)
    let cat = URL(filePath: "/bin/cat")
    let sleep = URL(filePath: "/bin/sleep")
    let echoed = try await worker.run(executable: cat, arguments: [], input: data, timeout: .seconds(2))
    precondition(echoed == data)
    let maximum = Data(repeating: 0, count: 2048)
    let echoedMaximum = try await worker.run(executable: cat, arguments: [], input: maximum, timeout: .seconds(2))
    precondition(echoedMaximum == maximum)

    do {
      _ = try await worker.run(executable: sleep, arguments: ["10"], input: data, timeout: .milliseconds(100))
      preconditionFailure("Blocking child escaped its parent deadline")
    } catch ProbeWiFiWorkerFailure.workerTimedOut {}

    do {
      _ = try await worker.run(executable: cat, arguments: [], input: Data(repeating: 0, count: 2049), timeout: .seconds(2))
      preconditionFailure("Oversized worker input was accepted")
    } catch ProbeWiFiWorkerFailure.invalidWorkerRequest {}

    do {
      _ = try await worker.run(executable: URL(filePath: "/usr/bin/head"), arguments: ["-c", "2049", "/dev/zero"],
        input: Data(), timeout: .seconds(2))
      preconditionFailure("Oversized worker output was accepted")
    } catch ProbeWiFiWorkerFailure.invalidWorkerResponse {}

    let cancelled = Task {
      try await worker.run(executable: sleep, arguments: ["10"], input: Data(), timeout: .seconds(5))
    }
    try await Task.sleep(for: .milliseconds(50))
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      preconditionFailure("Cancelled child reported success")
    } catch is CancellationError {}
    let afterReap = try await worker.run(executable: cat, arguments: [], input: data, timeout: .seconds(2))
    precondition(afterReap == data)
    let discarded = try await worker.run(executable: cat, arguments: [], input: data, timeout: .seconds(2), discardOutput: true)
    precondition(discarded.isEmpty)
    print("Private worker pipe bounds, parent deadline, cancellation, and reap checks passed.")
  }
}

@MainActor
private final class Scenario: ProbeWiFiOnlyAssociating, CameraNetworkCredentialProvider, WirelessTransferSession {
  let camera = WirelessCameraID()
  let original = ProbeWiFiSnapshot(interface: "wireless", ssid: Data("original".utf8))
  let target = Data("synthetic-camera".utf8)
  var routes: [String?] = ["wired", "wired"]
  var steps: [String] = []
  var scanFails = false
  var cancelAtSnapshot = false
  var isCurrent = true
  var joinError: (any Error)?
  var openError: (any Error)?
  var restoreFails = false
  var revokeAtRestore = false
  var cancelAtJoin = false
  var revokeAtOpen = false
  var holdOpen = false
  var failVerification: Int?
  var verifyCount = 0
  var observedFirmware = "04.31"
  var observedModel = WirelessCameraModel.xt5
  var snapshotOverride: ProbeWiFiSnapshot?
  var gapError: (any Error)?
  var cancelAtGap = false
  var savedRejoinFails = false
  var previousVerificationFails = false
  var releaseCameraFails = false
  var releaseCameraError: (any Error)?

  var identity: WirelessIdentity { .init(cameraID: camera, model: .xt5, firmware: "4.31") }

  func preflight() async throws {
    try await ProbePTPIdentity.preflight(association: self, wiredRoute: wiredRoute)
  }

  func run(
    currentIdentity: WirelessIdentity? = nil, ptpTimeout: Duration = .seconds(20), wifiOnly: ProbeWiFiOnlyReceipt? = nil
  ) async -> ProbePTPIdentityReport {
    let receipt = ProbeReadyCameraNetwork(
      network: CameraNetwork(ssid: String(decoding: target, as: UTF8.self), security: .wpaPersonal,
        credential: CameraCredentialReference(cameraID: camera, version: UUID()), isHidden: true),
      identity: identity, launch: .imageViewing)
    return await ProbePTPIdentity.run(
      receipt, currentIdentity: currentIdentity ?? identity, credentials: self, association: self,
      wiredRoute: wiredRoute,
      wifiOnly: wifiOnly.map { (receipt: $0, association: self) },
      isCurrent: { self.isCurrent }, ptpTimeout: ptpTimeout,
      makeSession: { identity in
        await self.makeSession(identity)
      })
  }

  func snapshot() async throws -> ProbeWiFiSnapshot {
    steps.append("capture")
    if cancelAtSnapshot { withUnsafeCurrentTask { $0?.cancel() } }
    return snapshotOverride ?? original
  }

  private func wiredRoute() async -> String? {
    steps.append("wired")
    return routes.removeFirst()
  }

  func scan(from original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    precondition(original.ssid == self.original.ssid && cameraSSID == target)
    steps.append("scan")
    if scanFails { throw ProbeWiFiWorkerFailure.cameraNetworkUnavailable }
  }

  func password(for reference: CameraCredentialReference) async throws -> String {
    precondition(reference.cameraID == camera)
    steps.append("credential")
    return "synthetic-password"
  }

  func join(
    from original: ProbeWiFiSnapshot, cameraSSID: Data, password: String, route: ProbeCameraWiFiRoute
  ) async throws {
    precondition(original.ssid == self.original.ssid && cameraSSID == target)
    precondition(password == "synthetic-password")
    switch route {
    case .wired("wired"): steps.append("join")
    case .wifiOnly: steps.append("wifi-only join")
    default: preconditionFailure("Unexpected route")
    }
    if let joinError { throw joinError }
    if cancelAtJoin {
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
  }

  func verify(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    precondition(original.ssid == self.original.ssid && cameraSSID == target)
    steps.append("verify target")
    verifyCount += 1
    if verifyCount == failVerification { throw ProbeWiFiWorkerFailure.associationChanged }
  }

  func restore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    precondition(original.ssid == self.original.ssid && cameraSSID == target)
    precondition(!Task.isCancelled)
    steps.append("restore")
    if revokeAtRestore { isCurrent = false }
    if restoreFails { throw ProbeWiFiWorkerFailure.restoreUnverified }
  }

  func checkInternet(_ original: ProbeWiFiSnapshot) async throws {
    steps.append("internet")
  }

  func rehearsalGap(_ original: ProbeWiFiSnapshot) async throws {
    steps.append("gap")
    if let gapError { throw gapError }
    if cancelAtGap { withUnsafeCurrentTask { $0?.cancel() } }
  }

  func releaseCameraForRestore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws {
    steps.append("release camera")
    if releaseCameraFails { throw ProbeWiFiWorkerFailure.restoreUnverified }
    if let releaseCameraError { throw releaseCameraError }
  }

  func reassociateSaved(_ original: ProbeWiFiSnapshot) async throws {
    precondition(!Task.isCancelled)
    steps.append("saved rejoin")
    if savedRejoinFails { throw ProbeWiFiWorkerFailure.workerUnavailable }
  }

  func verifyPrevious(_ original: ProbeWiFiSnapshot) async throws {
    steps.append("verify previous")
    if previousVerificationFails { throw ProbeWiFiWorkerFailure.restoreUnverified }
  }

  private func makeSession(_ expected: WirelessIdentity) -> any WirelessTransferSession {
    precondition(expected == identity)
    steps.append("session")
    return self
  }

  func open() async throws -> WirelessIdentity {
    steps.append("open")
    if let openError { throw openError }
    if revokeAtOpen { isCurrent = false }
    if holdOpen { try await Task.sleep(for: .seconds(20)) }
    return .init(cameraID: camera, model: observedModel, firmware: observedFirmware)
  }

  func close() async throws { steps.append("close") }
  func capabilities() async throws -> WirelessCapabilities { preconditionFailure("Capabilities requested") }
  func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, any Error> {
    preconditionFailure("Inventory requested")
  }
  func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data {
    preconditionFailure("Thumbnail requested")
  }
  func download(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    preconditionFailure("Photo bytes requested")
  }
}
