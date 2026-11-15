import Foundation
import FujiCameraCore

@main
private struct SecureStatusComparisonTests {
  static func main() {
    let peer = UUID()
    let cameraID = WirelessCameraID()
    let otherPeer = UUID()
    let session = UUID()
    let otherSession = UUID()
    let status = Data([1, 2, 3, 4])
    let read = BLEProtocolEvent.read(ProbeSecureStatusComparison.characteristic, status)
    var comparison = ProbeSecureStatusComparison()

    comparison.begin(.pairing, peripheralID: peer)
    precondition(!comparison.receive(read, session: session), "Unverified session was observed")
    comparison.verifyXT5(session: session)
    precondition(!comparison.receive(read, session: otherSession), "Wrong session was observed")
    precondition(comparison.receive(read, session: session))
    precondition(!comparison.observation.baselineAvailable, "Unfinished pair committed a baseline")
    comparison.endAttempt()
    precondition(!comparison.commitPairing(peripheralID: peer, cameraID: cameraID), "Failed pair committed a baseline")

    comparison.begin(.reconnect, peripheralID: peer)
    comparison.verifyXT5(session: session)
    precondition(comparison.receive(read, session: session))
    precondition(comparison.observation.validLength && !comparison.observation.baselineAvailable)
    precondition(!comparison.observation.compared)

    comparison.begin(.pairing, peripheralID: peer)
    comparison.verifyXT5(session: session)
    precondition(comparison.receive(read, session: session))
    precondition(comparison.commitPairing(peripheralID: peer, cameraID: cameraID))
    comparison.endAttempt()

    comparison.begin(.pairing, peripheralID: otherPeer)
    comparison.verifyXT5(session: otherSession)
    precondition(comparison.receive(read, session: otherSession))
    comparison.endAttempt()
    precondition(!comparison.commitPairing(peripheralID: otherPeer, cameraID: cameraID), "Cancelled pair committed a baseline")

    comparison.begin(.reconnect, peripheralID: otherPeer)
    comparison.verifyXT5(session: otherSession)
    precondition(comparison.receive(read, session: otherSession))
    precondition(!comparison.observation.baselineAvailable && !comparison.observation.compared)

    comparison.begin(.reconnect, peripheralID: peer)
    precondition(!comparison.observation.observed && !comparison.observation.compared)
    comparison.verifyXT5(session: session)
    let anotherCharacteristic = BLEGATTCharacteristic(
      service: ProbeSecureStatusComparison.characteristic.service, characteristic: "2a26")
    precondition(!comparison.receive(.read(anotherCharacteristic, status), session: session))
    let short = BLEProtocolEvent.read(ProbeSecureStatusComparison.characteristic, Data([1, 2, 3]))
    precondition(comparison.receive(short, session: session))
    precondition(comparison.observation.observed && !comparison.observation.validLength)
    precondition(comparison.observation.baselineAvailable && !comparison.observation.compared)
    precondition(!comparison.receive(read, session: session), "Duplicate read replaced the first observation")

    checkReconnect(&comparison, peer: peer, session: session, data: status, prefix: true, whole: true)
    checkReconnect(&comparison, peer: peer, session: session, data: Data([1, 2, 3, 9]), prefix: true, whole: false)
    checkReconnect(&comparison, peer: peer, session: session, data: Data([1, 2, 9, 4]), prefix: false, whole: false)
    print("Secure status session, baseline, length, and equality checks passed.")
  }

  private static func checkReconnect(
    _ comparison: inout ProbeSecureStatusComparison, peer: UUID, session: UUID, data: Data,
    prefix: Bool, whole: Bool
  ) {
    comparison.begin(.reconnect, peripheralID: peer)
    comparison.verifyXT5(session: session)
    precondition(comparison.receive(.read(ProbeSecureStatusComparison.characteristic, data), session: session))
    precondition(comparison.observation.baselineAvailable && comparison.observation.compared)
    precondition(comparison.observation.prefixEqual == prefix)
    precondition(comparison.observation.wholeEqual == whole)
    comparison.endAttempt()
  }
}
