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

  func testPowerInterruptionClearsDiscoveryWhileRetainingRetiringCallbackOwner() {
    var connections = CoreBluetoothConnections<Manager, Peripheral>()
    let manager = Manager()
    let stale = Peripheral()
    let fresh = Peripheral()
    let id = UUID()
    let active = UUID()
    let next = UUID()
    connections.remember(stale, for: id)
    XCTAssertTrue(connections.begin(session: active, peripheralID: id, manager: manager) { nil } === stale)
    connections.remember(stale, for: id)
    connections.discardDiscoveries()
    XCTAssertEqual(connections.requestCancellation(for: active, canRequest: false), .awaitingTerminal)
    XCTAssertEqual(connections.consumeTerminal(manager: manager, peripheral: stale), active)
    XCTAssertTrue(connections.begin(session: next, peripheralID: id, manager: manager) { fresh } === fresh)
  }

  func testInvalidatedPeripheralCallbackCannotRetireFreshNativeAttempt() {
    var connections = CoreBluetoothConnections<Manager, Peripheral>()
    let manager = Manager()
    let stale = Peripheral()
    let fresh = Peripheral()
    let id = UUID()
    let first = UUID()
    let next = UUID()
    _ = connections.begin(session: first, peripheralID: id, manager: manager) { stale }
    XCTAssertEqual(connections.invalidate(manager: manager), first)
    _ = connections.begin(session: next, peripheralID: id, manager: manager) { fresh }
    XCTAssertNil(connections.consumeTerminal(manager: manager, peripheral: stale))
    XCTAssertEqual(connections.consumeTerminal(manager: manager, peripheral: fresh), next)
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
