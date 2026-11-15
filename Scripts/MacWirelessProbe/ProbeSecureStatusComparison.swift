import Foundation
import FujiCameraCore

struct ProbeSecureStatusComparison: CustomReflectable {
  enum Attempt {
    case pairing
    case reconnect
    case registrationReconnect
  }

  struct RegistrationTicket: CustomReflectable {
    fileprivate let peripheralID: UUID
    fileprivate let cameraID: WirelessCameraID
    fileprivate let originalSession: UUID
    fileprivate let failedSession: UUID
    fileprivate let status: Data

    func matches(peripheralID: UUID, cameraID: WirelessCameraID) -> Bool {
      self.peripheralID == peripheralID && self.cameraID == cameraID
    }

    func authorizes(peripheralID: UUID, session: UUID) -> Bool {
      self.peripheralID == peripheralID && session != originalSession && session != failedSession
    }

    func acknowledgement() -> Data {
      var acknowledgement = status
      acknowledgement[acknowledgement.startIndex + 3] |= 0x20
      return acknowledgement
    }

    var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
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
  private var attempt: (kind: Attempt, peripheralID: UUID, cameraID: WirelessCameraID?, verifiedSession: UUID?)?
  private var pendingPairStatus: Data?
  private var baseline: (peripheralID: UUID, cameraID: WirelessCameraID, session: UUID, status: Data)?
  private var registrationTicket: RegistrationTicket?

  mutating func begin(_ kind: Attempt, peripheralID: UUID, cameraID: WirelessCameraID? = nil) {
    resetObservation()
    registrationTicket = nil
    attempt = (kind, peripheralID, cameraID, nil)
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
    case .reconnect, .registrationReconnect:
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
  mutating func commitPairing(peripheralID: UUID, cameraID: WirelessCameraID) -> Bool {
    defer { endAttempt() }
    guard let attempt, attempt.kind == .pairing, attempt.peripheralID == peripheralID,
      let session = attempt.verifiedSession, let pendingPairStatus
    else { return false }
    baseline = (peripheralID, cameraID, session, pendingPairStatus)
    observation.baselineAvailable = true
    return true
  }

  mutating func finishFailedReconnect() {
    defer { endAttempt() }
    guard let attempt, attempt.kind == .reconnect, let failedSession = attempt.verifiedSession,
      let baseline, failedSession != baseline.session,
      baseline.peripheralID == attempt.peripheralID, baseline.cameraID == attempt.cameraID,
      observation.compared, !observation.prefixEqual
    else { return }
    registrationTicket = RegistrationTicket(
      peripheralID: baseline.peripheralID, cameraID: baseline.cameraID, originalSession: baseline.session,
      failedSession: failedSession, status: baseline.status)
  }

  mutating func takeRegistrationTicket() -> RegistrationTicket? {
    defer { registrationTicket = nil }
    return registrationTicket
  }

  mutating func clearRegistrationTicket() {
    registrationTicket = nil
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
