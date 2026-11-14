import Foundation
import XCTest

@testable import FujiCameraCore

final class AutoSaveCodecTests: XCTestCase {
  // libfuji 3b9932a, docs/autosave.md. The documented X-H1 discovery fields
  // are reused with synthetic addresses and an importer token.
  func testDiscoveryUsesDestinationPortAndMatchingDatagramSource() throws {
    let registration = bytes([
      "DISCOVER * HTTP/1.1", "MX:3", "HOST:192.168.1.255:|",
      "DSCADDR:192.168.1.32", "SERVICE:PCAUTOSAVE/1.0",
    ])
    let transfer = bytes([
      "DISCOVER FujiStudio-test HTTP/1.1", "MX:3", "HOST:192.168.1.255:|",
      "DSCADDR:192.168.1.32", "SERVICE:PCAUTOSAVE/1.0",
    ])
    XCTAssertEqual(AutoSaveCodec.Phase.registration.port, 51542)
    XCTAssertEqual(AutoSaveCodec.Phase.transfer.port, 51541)
    XCTAssertEqual(AutoSaveCodec.notifyPort, 51540)
    XCTAssertEqual(AutoSaveCodec.commandPort, 55740)
    XCTAssertEqual(
      try AutoSaveCodec.discovery(registration, phase: .registration, source: "192.168.1.32"),
      "*")
    XCTAssertEqual(
      try AutoSaveCodec.discovery(transfer, phase: .transfer, source: "192.168.1.32"),
      "FujiStudio-test")
    XCTAssertThrowsError(
      try AutoSaveCodec.discovery(registration, phase: .transfer, source: "192.168.1.32"))
    XCTAssertThrowsError(
      try AutoSaveCodec.discovery(transfer, phase: .transfer, source: "192.168.1.33")) {
      XCTAssertEqual($0 as? WirelessFailure, .peerMismatch)
    }
  }

  func testMalformedDatagramsCannotSupplyAnEndpoint() {
    let fields = [
      "DISCOVER * HTTP/1.1", "MX:3", "HOST:192.168.1.255:|",
      "DSCADDR:192.168.1.32", "SERVICE:PCAUTOSAVE/1.0",
    ]
    let invalid = [
      Data(), Data(repeating: 0x41, count: 1025), Data(bytes(fields).dropLast()),
      bytes(fields + ["dscaddr:192.168.1.33"]),
      bytes(Array(fields.dropLast())),
      bytes(fields + ["Content-Length:3"]) + Data("bad".utf8),
      bytes(fields.map { $0 == "MX:3" ? "MX:99999" : $0 }),
      bytes(fields.map { $0 == "DSCADDR:192.168.1.32" ? "DSCADDR:224.0.0.7" : $0 }),
      bytes(fields) + Data([0]),
    ]
    for datagram in invalid {
      XCTAssertThrowsError(
        try AutoSaveCodec.discovery(datagram, phase: .registration, source: "192.168.1.32"))
    }
  }

  func testNotifyAndRepliesUsePinnedWireBytes() throws {
    XCTAssertEqual(try AutoSaveCodec.notify(address: "192.168.1.32", importer: "FujiStudio-test"),
      bytes(["NOTIFY * HTTP/1.1", "HOST: 192.168.1.32:51540", "IMPORTER: FujiStudio-test"]))
    XCTAssertEqual(AutoSaveCodec.response(to: .registration),
      bytes(["HTTP/1.1 200 OK", "FOLDER: guest", "ServiceName: PCAUTOSAVE/1.0"]))
    XCTAssertEqual(AutoSaveCodec.response(to: .transfer), bytes(["HTTP/1.1 200 OK"]))
    XCTAssertTrue(try AutoSaveCodec.notifyAcknowledged(bytes(["HTTP/1.1 200 OK"])))
    XCTAssertFalse(try AutoSaveCodec.notifyAcknowledged(Data("HTTP/1.1 200 O".utf8)))
    XCTAssertThrowsError(
      try AutoSaveCodec.notifyAcknowledged(bytes(["HTTP/1.1 403 Denied", "HTTP/1.1 200 OK"])))
    XCTAssertThrowsError(
      try AutoSaveCodec.notify(address: "192.168.1.32", importer: "x\r\nHOST: elsewhere"))
  }

  func testInvitationsRequireCompleteIdentityAndCorrectReceiverRole() throws {
    let register = bytes([
      "REGISTER * HTTP/1.1", "HOST:192.168.1.2:51542",
      "DSCNAME:FUJIFILM-X-H1-CA2A", "DSCMODEL:X-H1",
    ])
    for count in 0..<register.count {
      XCTAssertNil(try AutoSaveCodec.invitation(
        Data(register.prefix(count)), phase: .registration, localAddress: "192.168.1.2"))
    }
    let registration = try XCTUnwrap(AutoSaveCodec.invitation(
      register, phase: .registration, localAddress: "192.168.1.2"))
    XCTAssertEqual(registration.cameraName, "FUJIFILM-X-H1-CA2A")
    XCTAssertEqual(registration.cameraModel, "X-H1")

    let transfer = [
      "IMPORT /guest HTTP/1.1", "HOST:192.168.1.2:51541",
      "DSCNAME:FUJIFILM-X-H1-CA2A", "DSCPORT:55740",
    ]
    XCTAssertEqual(
      try AutoSaveCodec.invitation(bytes(transfer), phase: .transfer, localAddress: "192.168.1.2")?.cameraName,
      "FUJIFILM-X-H1-CA2A")
    for replacement in [
      ("HOST:192.168.1.2:51541", "HOST:192.168.1.2:51542"),
      ("HOST:192.168.1.2:51541", "HOST:192.168.1.3:51541"),
      ("IMPORT /guest HTTP/1.1", "IMPORT /elsewhere HTTP/1.1"),
      ("DSCPORT:55740", "DSCPORT:0"),
      ("DSCNAME:FUJIFILM-X-H1-CA2A", "DSCNAME:" + String(repeating: "x", count: 129)),
    ] {
      XCTAssertThrowsError(
        try AutoSaveCodec.invitation(
          bytes(transfer.map { $0 == replacement.0 ? replacement.1 : $0 }),
          phase: .transfer, localAddress: "192.168.1.2"))
    }
  }

  private func bytes(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
  }
}
