import Foundation

@MainActor
protocol ProbeWiFiOnlyAssociating: ProbeWiFiAssociating {
  func checkInternet(_ original: ProbeWiFiSnapshot) async throws
  func rehearsalGap(_ original: ProbeWiFiSnapshot) async throws
  func releaseCameraForRestore(_ original: ProbeWiFiSnapshot, cameraSSID: Data) async throws
  func reassociateSaved(_ original: ProbeWiFiSnapshot) async throws
  func verifyPrevious(_ original: ProbeWiFiSnapshot) async throws
}

struct ProbeWiFiOnlyReceipt {
  let original: ProbeWiFiSnapshot
  let expiresAt: ContinuousClock.Instant

  func validate(_ snapshot: ProbeWiFiSnapshot, now: ContinuousClock.Instant = .now) throws {
    guard now < expiresAt, snapshot == original else { throw ProbeWiFiWorkerFailure.restoreRehearsalRequired }
  }
}

struct ProbeWiFiOnlyRehearsal {
  var outcome = "notRun"
  var gapObserved = false
  var exactRestoreCommandCompleted = false
  var restorationVerified = false
  var receipt: ProbeWiFiOnlyReceipt?

  mutating func takeReceipt(now: ContinuousClock.Instant = .now) -> ProbeWiFiOnlyReceipt? {
    defer { receipt = nil }
    guard let receipt, now < receipt.expiresAt else { return nil }
    return receipt
  }
}

@MainActor
enum ProbeWiFiOnlyRecovery {
  static func preflight(_ association: any ProbeWiFiOnlyAssociating) async throws -> ProbeWiFiSnapshot {
    try Task.checkCancellation()
    let original = try await association.snapshot()
    guard original.savedNetworkName != nil else { throw ProbeWiFiWorkerFailure.currentWiFiUnavailable }
    try await association.checkInternet(original)
    try Task.checkCancellation()
    guard try await association.snapshot() == original else { throw ProbeWiFiWorkerFailure.associationChanged }
    try Task.checkCancellation()
    return original
  }

  static func rehearse(_ association: any ProbeWiFiOnlyAssociating) async -> ProbeWiFiOnlyRehearsal {
    var report = ProbeWiFiOnlyRehearsal()
    let original: ProbeWiFiSnapshot
    do {
      original = try await preflight(association)
      try Task.checkCancellation()
    } catch {
      report.outcome = ProbePTPIdentity.failureLabel(error)
      return report
    }

    do {
      try await association.rehearsalGap(original)
      report.gapObserved = true
    } catch let failure as ProbeWiFiWorkerFailure where failure.stoppedBeforeAssociation {
      report.outcome = failure.rawValue
      return report
    } catch {
      report.outcome = ProbePTPIdentity.failureLabel(error)
    }

    // Do not let cancellation of the initiating task cancel local recovery.
    let cleanup = Task { await restore(association, original: original, cameraSSID: nil) }
    let restoration = await cleanup.value
    report.exactRestoreCommandCompleted = restoration.commandCompleted
    report.restorationVerified = restoration.verified
    if Task.isCancelled {
      report.outcome = "cancelled"
    } else if !restoration.verified {
      report.outcome = "restoreUnverified"
    } else if report.gapObserved {
      if restoration.commandCompleted {
        report.outcome = "restoreRehearsalVerified"
        report.receipt = ProbeWiFiOnlyReceipt(original: original, expiresAt: .now + .seconds(300))
      } else {
        report.outcome = "exactRestoreUnproven"
      }
    }
    return report
  }

  static func restore(
    _ association: any ProbeWiFiOnlyAssociating, original: ProbeWiFiSnapshot, cameraSSID: Data?
  ) async -> (commandCompleted: Bool, verified: Bool) {
    var canAttemptCommand = true
    do {
      if let cameraSSID { try await association.releaseCameraForRestore(original, cameraSSID: cameraSSID) }
    } catch ProbeWiFiWorkerFailure.restoreUnverified {
      canAttemptCommand = false
    } catch {
      // An interrupted release might have succeeded. The restore worker
      // independently requires an unassociated interface before invoking Apple's utility.
    }
    var commandCompleted = false
    if canAttemptCommand {
      commandCompleted = (try? await association.reassociateSaved(original)) != nil
    }
    // The OS may have already auto-joined, or successfully restored despite a command error.
    // In either case only an independently observed result is treated as restored.
    do {
      try await association.verifyPrevious(original)
      try await association.checkInternet(original)
      guard try await association.snapshot() == original else { return (commandCompleted, false) }
      return (commandCompleted, true)
    } catch {
      return (commandCompleted, false)
    }
  }
}
