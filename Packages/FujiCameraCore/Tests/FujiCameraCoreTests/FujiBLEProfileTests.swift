import Foundation
import XCTest

@testable import FujiCameraCore

final class FujiBLEProfileTests: XCTestCase {
  private let secureStatus = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "f557d96b-8284-4667-8793-b971c1deca2a")
  private let secureName = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
  private let legacyToken = BLEGATTCharacteristic(
    service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
    characteristic: "aba356eb-9633-4e60-b73f-f52516dbd671")
  private let legacyName = BLEGATTCharacteristic(
    service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
  private let readiness = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
  private let secondIndication = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
  private let firmware = BLEGATTCharacteristic(service: "180A", characteristic: "2A26")
  private let ssid = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
  private let password = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "e809256a-915c-4967-92e8-53b7d4cad213")
  private let launch = BLEGATTCharacteristic(
    service: "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    characteristic: "600655e6-3637-42f1-8fb2-44efc5c63b13")

  func testSecureAuthenticationAcknowledgesFourByteStatusThenSubscribesInOrder() throws {
    var profile = XT5BLEProfile()
    XCTAssertEqual(
      try profile.receive(.services([secureStatus, secureName, readiness, secondIndication, firmware])),
      [.read(secureStatus)])
    XCTAssertEqual(
      try profile.receive(.read(secureStatus, Data([0x07, 0x96, 0x00, 0x00]))),
      [.write(secureStatus, Data([0x07, 0x96, 0x00, 0x20]), .authenticate)])
    XCTAssertEqual(
      try profile.receive(.wrote(secureStatus)),
      [.write(secureName, Data("Fuji Studio".utf8), .identify)])
    XCTAssertEqual(try profile.receive(.wrote(secureName)), [.subscribe(readiness)])
    XCTAssertEqual(try profile.receive(.subscribed(readiness)), [.subscribe(secondIndication)])
    XCTAssertEqual(try profile.receive(.subscribed(secondIndication)), [.read(firmware)])
    XCTAssertEqual(
      try profile.receive(.read(firmware, Data("4.32".utf8))),
      [.authenticated(firmware: "4.32")])
  }

  func testLegacyTokenExchangeDistinguishesFirstPairFromSavedAuthentication() throws {
    let token = WirelessProtocolPeerKey(bytes: Data([0xfa, 0x26, 0x9e, 0x45]))
    for (intent, purpose): (XE3BLEProfile.Intent, BLEWritePurpose) in [
      (.pair(token), .pair), (.reconnect(token), .authenticate),
    ] {
      var profile = XE3BLEProfile(intent: intent)
      XCTAssertEqual(
        try profile.receive(.services([legacyName, legacyToken, readiness])),
        [.write(legacyToken, token.bytes, purpose)])
      XCTAssertEqual(
        try profile.receive(.wrote(legacyToken)),
        [.write(legacyName, Data("Fuji Studio".utf8), .identify)])
      XCTAssertEqual(try profile.receive(.wrote(legacyName)), [.subscribe(readiness)])
      XCTAssertEqual(try profile.receive(.subscribed(readiness)), [.authenticated(firmware: nil)])
    }
  }

  func testSecureProfileRequiresCharacteristicsInTheirOwnServicesBeforeWriting() throws {
    let misplacedName = BLEGATTCharacteristic(
      service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
      characteristic: secureName.characteristic)
    var profile = XT5BLEProfile()
    XCTAssertThrowsError(try profile.receive(.services([secureStatus, misplacedName, readiness]))) {
      XCTAssertEqual($0 as? WirelessFailure, .unsupportedProtocol)
    }
  }

  func testSecureRejectsMalformedStatusWithoutAnAcknowledgement() throws {
    for status in [Data(), Data([0, 1, 2]), Data([0, 1, 2, 3, 4])] {
      var profile = XT5BLEProfile()
      _ = try profile.receive(.services([secureStatus, secureName, readiness]))
      XCTAssertThrowsError(try profile.receive(.read(secureStatus, status))) {
        XCTAssertEqual($0 as? WirelessFailure, .malformedData)
      }
    }
  }

  func testLegacyAuthenticationRejectionRequiresRepair() throws {
    let token = WirelessProtocolPeerKey(bytes: Data([0xfa, 0x26, 0x9e, 0x45]))
    var profile = XE3BLEProfile(intent: .reconnect(token))
    _ = try profile.receive(.services([legacyName, legacyToken, readiness]))
    XCTAssertThrowsError(try profile.receive(.failed(legacyToken, .authentication))) {
      XCTAssertEqual($0 as? WirelessFailure, .authentication)
    }
    XCTAssertEqual(try profile.receive(.wrote(legacyToken)), [])
  }

  func testWiFiNeedsFreshRecognizedIndicationAndCredentials() throws {
    var profile = XT5BLEProfile()
    _ = try profile.receive(.services([secureStatus, secureName, readiness, ssid, password, launch]))
    _ = try profile.receive(.read(secureStatus, Data([0, 0, 0, 0])))
    _ = try profile.receive(.wrote(secureStatus))
    XCTAssertEqual(try profile.receive(.wrote(secureName)), [.read(ssid)])
    XCTAssertEqual(
      try profile.receive(.read(ssid, Data("initial-network".utf8))), [.subscribe(readiness)])
    _ = try profile.receive(.subscribed(readiness))
    _ = try profile.receive(.subscribed(ssid))
    XCTAssertEqual(try profile.receive(.notification(readiness, Data([1]))), [])
    XCTAssertEqual(try profile.receive(.notification(ssid, Data("test-network".utf8))), [])
    XCTAssertEqual(try profile.receive(.activateWiFi), [.read(password)])
    XCTAssertEqual(try profile.receive(.notification(ssid, Data("joined-network".utf8))), [])
    XCTAssertEqual(
      try profile.receive(.read(password, Data("example-secret".utf8))),
      [.write(launch, Data([4, 0]), .activateWiFi)])
    XCTAssertEqual(try profile.receive(.wrote(launch)), [])
    XCTAssertEqual(try profile.receive(.notification(readiness, Data([0xff, 0xff]))), [])
    XCTAssertEqual(
      try profile.receive(.notification(readiness, Data([1, 0]))),
      [.wifiReady(BLEWiFiCredentials(ssid: "joined-network", password: "example-secret"))])
  }

  func testMissingPasswordCannotLaunchAnOpenNetwork() throws {
    var profile = XT5BLEProfile()
    _ = try profile.receive(.services([secureStatus, secureName, readiness, ssid, launch]))
    _ = try profile.receive(.read(secureStatus, Data([0, 0, 0, 0])))
    _ = try profile.receive(.wrote(secureStatus))
    _ = try profile.receive(.wrote(secureName))
    _ = try profile.receive(.read(ssid, Data("test-network".utf8)))
    _ = try profile.receive(.subscribed(readiness))
    _ = try profile.receive(.subscribed(ssid))
    XCTAssertThrowsError(try profile.receive(.activateWiFi)) {
      XCTAssertEqual($0 as? WirelessFailure, .unsupportedProtocol)
    }
  }

  func testOptionalSubscriptionWithoutNotifyPermissionCanBeSkipped() throws {
    var profile = XT5BLEProfile()
    _ = try profile.receive(.services([secureStatus, secureName, readiness, secondIndication]))
    _ = try profile.receive(.read(secureStatus, Data([0, 0, 0, 0])))
    _ = try profile.receive(.wrote(secureStatus))
    _ = try profile.receive(.wrote(secureName))
    _ = try profile.receive(.subscribed(readiness))
    XCTAssertEqual(
      try profile.receive(.subscriptionUnavailable(secondIndication)), [.authenticated(firmware: nil)])
  }

  func testUnavailableReadinessSubscriptionFailsAuthenticationFlow() throws {
    var profile = XT5BLEProfile()
    _ = try profile.receive(.services([secureStatus, secureName, readiness]))
    _ = try profile.receive(.read(secureStatus, Data([0, 0, 0, 0])))
    _ = try profile.receive(.wrote(secureStatus))
    _ = try profile.receive(.wrote(secureName))
    XCTAssertThrowsError(try profile.receive(.subscriptionUnavailable(readiness))) {
      XCTAssertEqual($0 as? WirelessFailure, .unsupportedProtocol)
    }
  }

  func testBusyWiFiResponseFailsEvenIfItArrivesBeforeWriteAcknowledgement() throws {
    let key = WirelessProtocolPeerKey(bytes: Data([1, 2, 3, 4]))
    var profile = XE3BLEProfile(intent: .pair(key))
    _ = try profile.receive(.services([legacyToken, legacyName, readiness, ssid, password, launch]))
    _ = try profile.receive(.wrote(legacyToken))
    _ = try profile.receive(.wrote(legacyName))
    _ = try profile.receive(.read(ssid, Data("test-network".utf8)))
    _ = try profile.receive(.subscribed(ssid))
    _ = try profile.receive(.subscribed(readiness))
    _ = try profile.receive(.activateWiFi)
    _ = try profile.receive(.read(password, Data("example-secret".utf8)))
    XCTAssertEqual(try profile.receive(.notification(readiness, Data([0, 0]))), [])
    XCTAssertThrowsError(try profile.receive(.wrote(launch))) {
      XCTAssertEqual($0 as? WirelessFailure, .cameraBusy)
    }
  }
}
