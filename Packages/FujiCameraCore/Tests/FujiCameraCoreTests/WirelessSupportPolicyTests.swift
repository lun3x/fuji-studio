import Foundation
import FujiCameraCore
import XCTest

final class WirelessSupportPolicyTests: XCTestCase {
  private let policy = WirelessSupportPolicy()

  func testOnlyCurrentFirmwareIsAdmitted() {
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.32"), .supported(.xt5))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: "1.32"), .supported(.xe3))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.31"), .updateRequired("4.32"))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: "1.31"), .updateRequired("1.32"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.33"), .unverified("4.33"))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: "1.33"), .unverified("1.33"))
  }

  func testMissingAndMalformedFirmwareAreUnverified() {
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: nil), .unverified(nil))
    for firmware in [
      "", "  ", "garbage", "4", "4..32", "4.32.0", "4.٣٢", "4.32-beta", "Ver. Ver.4.32",
    ] {
      XCTAssertEqual(policy.assess(model: "X-T5", firmware: firmware), .unverified(firmware))
    }
  }

  func testFirmwareOnlyNormalizesSurroundingWhitespaceAndLeadingVersionPrefix() {
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: " \tVer.4.32\n"), .supported(.xt5))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: " Ver. 1.32 "), .supported(.xe3))
    for firmware in ["v4.32", "ver.4.32", "4. 32", "04.32", "4.032"] {
      XCTAssertEqual(policy.assess(model: "X-T5", firmware: firmware), .unverified(firmware))
    }
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: " Ver.4.33 "), .unverified(" Ver.4.33 "))
  }

  func testFirmwareOrderingComparesNumericComponents() {
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.9"), .updateRequired("4.32"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.01"), .updateRequired("4.32"))
    XCTAssertEqual(policy.assess(model: "X-E3", firmware: "1.00"), .updateRequired("1.32"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "4.320"), .unverified("4.320"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "3.999"), .updateRequired("4.32"))
    XCTAssertEqual(policy.assess(model: "X-T5", firmware: "10.1"), .unverified("10.1"))
    XCTAssertEqual(
      policy.assess(model: "X-T5", firmware: "4.92233720368547758080"),
      .unverified("4.92233720368547758080"))
  }

  func testUnsupportedCameraCannotEnterWirelessFirmwarePolicy() {
    XCTAssertEqual(policy.assess(model: "X-E5", firmware: "1.32"), .unsupportedModel)
    XCTAssertEqual(policy.assess(model: "X-Pro3", firmware: nil), .unsupportedModel)
  }

  func testProtocolPeerKeySupportsMatchingAndRedactsDiagnostics() {
    let bytes = Data("fixture-peer-key".utf8)
    let key = WirelessProtocolPeerKey(bytes: bytes)
    XCTAssertEqual(key, WirelessProtocolPeerKey(bytes: bytes))
    XCTAssertNotEqual(key, WirelessProtocolPeerKey(bytes: Data("other-peer-key".utf8)))
    XCTAssertEqual(String(describing: key), "[redacted]")
    XCTAssertEqual(String(reflecting: key), "[redacted]")
    XCTAssertTrue(Mirror(reflecting: key).children.isEmpty)
  }
}
