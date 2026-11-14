@preconcurrency import CoreBluetooth
import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class CoreBluetoothDriverTests: XCTestCase {
  private final class Manager {}
  private final class Peripheral {}

  func testSamePeripheralCannotStartAgainUntilTheUntaggedNativeTerminalCallback() {
    var connections = CoreBluetoothConnections<Manager, Peripheral>()
    let manager = Manager()
    let peripheral = Peripheral()
    let peripheralID = UUID()
    let firstSession = UUID()
    let nextSession = UUID()
    XCTAssertTrue(connections.installManager(manager))
    let first = connections.begin(session: firstSession, peripheralID: peripheralID, manager: manager) {
      peripheral
    }
    XCTAssertTrue(first === peripheral)
    // A cancellation request does not consume the native terminal callback.
    XCTAssertEqual(connections.requestCancellation(for: firstSession, canRequest: true), .request)
    XCTAssertEqual(
      connections.requestCancellation(for: firstSession, canRequest: true), .awaitingTerminal)
    XCTAssertNil(
      connections.begin(session: nextSession, peripheralID: peripheralID, manager: manager) {
        peripheral
      })
    XCTAssertNil(connections.consumeTerminal(manager: manager, peripheral: Peripheral()))
    XCTAssertEqual(connections.consumeTerminal(manager: manager, peripheral: peripheral), firstSession)
    XCTAssertTrue(
      connections.begin(session: nextSession, peripheralID: peripheralID, manager: manager) {
        peripheral
      } === peripheral)
    XCTAssertEqual(connections.consumeTerminal(manager: manager, peripheral: peripheral), nextSession)
  }

  func testRadioShutdownRetiresIssuedManagerWithoutTerminalAndReplacementCanObservePowerOn() {
    var connections = CoreBluetoothConnections<Manager, Peripheral>()
    let manager = Manager()
    let replacement = Manager()
    let stale = Peripheral()
    let id = UUID()
    let active = UUID()
    let next = UUID()
    XCTAssertTrue(connections.installManager(manager))
    connections.remember(stale, for: id)
    XCTAssertTrue(connections.begin(session: active, peripheralID: id, manager: manager) { nil } === stale)
    connections.remember(stale, for: id)
    XCTAssertEqual(connections.retireManagerWithAttempt(manager), active)
    XCTAssertFalse(connections.isCurrent(manager))
    XCTAssertNil(connections.consumeTerminal(manager: manager, peripheral: stale))

    XCTAssertTrue(connections.installManager(replacement))
    // Identical off reports arrive for the replacement before Bluetooth comes back.
    XCTAssertNil(connections.retireManagerWithAttempt(replacement))
    XCTAssertNil(connections.retireManagerWithAttempt(replacement))
    XCTAssertTrue(connections.isCurrent(replacement))
    XCTAssertFalse(connections.installManager(Manager()))

    // Reuse even the same object to prove the retired manager is fenced independently.
    var retrieves = 0
    XCTAssertTrue(
      connections.begin(session: next, peripheralID: id, manager: replacement) {
        retrieves += 1
        return stale
      } === stale)
    XCTAssertEqual(retrieves, 1)
    XCTAssertNil(connections.consumeTerminal(manager: manager, peripheral: stale))
    XCTAssertEqual(connections.consumeTerminal(manager: replacement, peripheral: stale), next)
  }

  func testRetiredManagerCannotTerminateFreshAttemptWithADifferentPeripheral() {
    var connections = CoreBluetoothConnections<Manager, Peripheral>()
    let manager = Manager()
    let replacement = Manager()
    let stale = Peripheral()
    let fresh = Peripheral()
    let id = UUID()
    let first = UUID()
    let next = UUID()
    XCTAssertTrue(connections.installManager(manager))
    _ = connections.begin(session: first, peripheralID: id, manager: manager) { stale }
    XCTAssertEqual(connections.retireManagerWithAttempt(manager), first)
    XCTAssertTrue(connections.installManager(replacement))
    _ = connections.begin(session: next, peripheralID: id, manager: replacement) { fresh }
    XCTAssertNil(connections.consumeTerminal(manager: manager, peripheral: stale))
    XCTAssertEqual(connections.consumeTerminal(manager: replacement, peripheral: fresh), next)
  }

  func testOptionalModelReadDistinguishesAuthAndTransportFromAbsentModel() {
    let credentialsRejected = NSError(
      domain: CBATTErrorDomain, code: CBATTError.insufficientAuthentication.rawValue)
    let bondRemoved = NSError(
      domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue)
    let disconnected = NSError(domain: CBErrorDomain, code: CBError.peripheralDisconnected.rawValue)
    let absent = NSError(domain: CBATTErrorDomain, code: CBATTError.attributeNotFound.rawValue)
    let misleadingModel = Data("X-E3".utf8)
    XCTAssertEqual(
      CoreBluetoothDriver.modelRead(misleadingModel, error: credentialsRejected),
      .failure(.authentication))
    XCTAssertEqual(
      CoreBluetoothDriver.modelRead(misleadingModel, error: bondRemoved), .failure(.authentication))
    XCTAssertEqual(
      CoreBluetoothDriver.modelRead(misleadingModel, error: disconnected), .failure(.connectionLost))
    XCTAssertEqual(CoreBluetoothDriver.modelRead(nil, error: absent), .success(nil))
    XCTAssertEqual(CoreBluetoothDriver.modelRead(misleadingModel, error: nil), .success("X-E3"))
  }
}
