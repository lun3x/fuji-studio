import Foundation
import FujiCameraCore

struct ProbeSecureStatusComparison: CustomReflectable {
  enum Attempt {
    case pairing
    case reconnect
  }

  struct Observation {
    var observed = false
    var validLength = false
    var baselineAvailable = false
    var compared = false
    var prefixEqual = false
    var wholeEqual = false

    var statusLines: [String] {
      [
        "secure_status_observed=\(observed)",
        "secure_status_valid_length=\(validLength)",
        "secure_status_baseline_available=\(baselineAvailable)",
        "secure_status_compared=\(compared)",
        "secure_status_prefix_equal=\(prefixEqual)",
        "secure_status_whole_equal=\(wholeEqual)",
      ]
    }
  }

  // The core profile owns the protocol action for this attribute.
  static let characteristic = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "f557d96b-8284-4667-8793-b971c1deca2a")

  private(set) var observation = Observation()
  private var attempt: (kind: Attempt, peripheralID: UUID, verifiedSession: UUID?)?
  private var pendingPairStatus: Data?
  private var baseline: (peripheralID: UUID, status: Data)?

  mutating func begin(_ kind: Attempt, peripheralID: UUID) {
    resetObservation()
    attempt = (kind, peripheralID, nil)
  }

  mutating func verifyXT5(session: UUID) {
    if attempt?.verifiedSession == nil { attempt?.verifiedSession = session }
  }

  /// Capture once, during the callback that passes the read to the native gateway.
  mutating func receive(_ event: BLEProtocolEvent, session: UUID) -> Bool {
    guard let attempt, attempt.verifiedSession == session, !observation.observed,
      case .read(Self.characteristic, let status) = event
    else { return false }

    observation.observed = true
    observation.validLength = status.count == 4
    switch attempt.kind {
    case .pairing:
      if observation.validLength { pendingPairStatus = status }
    case .reconnect:
      if let baseline, baseline.peripheralID == attempt.peripheralID {
        observation.baselineAvailable = true
        if observation.validLength {
          observation.compared = true
          observation.prefixEqual = status.prefix(3).elementsEqual(baseline.status.prefix(3))
          observation.wholeEqual = status == baseline.status
        }
      }
    }
    return true
  }

  /// Called after pairing, selection, and the authenticated identity check.
  mutating func commitPairing(peripheralID: UUID) -> Bool {
    defer { endAttempt() }
    guard let attempt, attempt.kind == .pairing, attempt.peripheralID == peripheralID,
      let pendingPairStatus
    else { return false }
    baseline = (peripheralID, pendingPairStatus)
    observation.baselineAvailable = true
    return true
  }

  mutating func endAttempt() {
    attempt = nil
    pendingPairStatus = nil
  }

  mutating func resetObservation() {
    endAttempt()
    observation = Observation()
  }

  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
