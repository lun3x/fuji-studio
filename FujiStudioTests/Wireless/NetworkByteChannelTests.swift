import Foundation
import FujiCameraCore
import Network
import Synchronization
import XCTest

@testable import FujiStudio

final class NetworkByteChannelTests: XCTestCase, @unchecked Sendable {
  #if DEBUG
  func testManualGalleryInitializationUsesTheConnectedIPv4() async throws {
    let cases: [(String, [UInt8], String?)] = [
      ("192.168.0.149", [0x95, 0x00, 0xa8, 0xc0], nil),
      ("10.23.45.67", [0x43, 0x2d, 0x17, 0x0a], "iPhone-0000"),
    ]
    for (ip, addressBytes, capturedName) in cases {
      let address = try XCTUnwrap(IPv4Address(ip))
      let driver = TestConnection(localEndpoint: .hostPort(host: .ipv4(address), port: 49152))
      let channel = try await connected(driver)
      let session = try await ManualWiFiProbe.makeGallerySession(
        channel: channel, expectedIdentity: .init(cameraID: .init(), model: .xt5, firmware: "4.31"),
        trace: nil, capturedClientName: capturedName)
      let listing = Task { try await session.listCameraPhotos() }
      defer { listing.cancel() }
      try await eventually { driver.written != nil }
      let frame = try XCTUnwrap(driver.written)
      XCTAssertEqual(frame.count, 82)
      XCTAssertEqual(Data(frame[12..<28]), Data([
        0xad, 0xa5, 0x48, 0x5d, 0x87, 0xb2, 0x7f, 0x0b, 0xd3, 0xd5, 0xde, 0xd0,
      ] + addressBytes))
      let name = Data((capturedName ?? "Fuji iPhone").utf16.flatMap { [UInt8($0), 0] })
      XCTAssertEqual(Data(frame[28...]), name + Data(repeating: 0, count: 54 - name.count))
      await session.abortGallery()
      _ = await listing.result
    }
  }

  func testManualGalleryMissingOrNonIPv4EndpointClosesBeforeReturning() async throws {
    let ipv6 = try XCTUnwrap(IPv6Address("fe80::1"))
    let endpoints: [NWEndpoint?] = [
      nil, .hostPort(host: .ipv6(ipv6), port: 49152), .service(name: "camera", type: "_ptp._tcp", domain: "local.", interface: nil),
    ]
    for endpoint in endpoints {
      let driver = TestConnection(localEndpoint: endpoint)
      let trace = Mutex([WirelessIdentityTrace.Event]())
      let channel = try await connected(driver, trace: { event in trace.withLock { $0.append(event) } })
      do {
        let session = try await ManualWiFiProbe.makeGallerySession(
          channel: channel, expectedIdentity: .init(cameraID: .init(), model: .xt5, firmware: "4.31"),
          trace: nil)
        XCTAssertTrue(trace.withLock { $0.contains(.init(.socketClose, .completed)) })
        await session.abortGallery()
        XCTFail("Manual gallery accepted a socket without a concrete local IPv4")
      } catch {
        XCTAssertEqual(error as? WirelessFailure, .routeUnavailable)
        XCTAssertTrue(trace.withLock { $0.contains(.init(.socketClose, .completed)) })
      }
      XCTAssertNil(driver.written)
    }
  }
  #endif

  func testAutoSaveRetriesRefusedPortOnlyAfterClosingEachDial() async throws {
    let selected = try XCTUnwrap(IPv4Address("192.168.1.53"))
    let refused = TestConnection(automaticallyAcknowledgesClose: false)
    let available = TestConnection()
    let attempts = Mutex([String]())
    let setup = Task {
      try await NetworkByteChannel.connectAutoSave(to: selected, deadline: .now + .seconds(3)) { endpoint in
        XCTAssertEqual(endpoint.port.rawValue, 55740)
        return attempts.withLock {
          $0.append(endpoint.address.debugDescription)
          return $0.count == 1 ? refused : available
        }
      }
    }
    defer { setup.cancel() }
    try await eventually { refused.started }
    refused.emit(.failed(.autoSavePeerUnreachable))
    try await eventually { refused.cancelCount == 1 }
    XCTAssertFalse(available.started)
    refused.emit(.ready)
    refused.emit(.cancelled)
    try await eventually { available.started }
    available.emit(.ready)
    let channel = try await setup.value
    XCTAssertEqual(attempts.withLock { $0 }, [selected.debugDescription, selected.debugDescription])
    XCTAssertEqual(refused.cancelCount, 1)
    await channel.close()
  }

  func testAutoSaveCancellationClosesCurrentDialWithoutStartingAnother() async throws {
    let selected = try XCTUnwrap(IPv4Address("192.168.1.53"))
    let driver = TestConnection(automaticallyAcknowledgesClose: false)
    let attempts = Mutex(0)
    let setup = Task {
      try await NetworkByteChannel.connectAutoSave(to: selected, deadline: .now + .seconds(3)) { _ in
        attempts.withLock { $0 += 1 }
        return driver
      }
    }
    try await eventually { driver.started }
    setup.cancel()
    try await eventually { driver.cancelCount == 1 }
    driver.emit(.ready)
    driver.emit(.cancelled)
    do {
      _ = try await setup.value
      XCTFail("Cancelled command dial became ready")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(attempts.withLock { $0 }, 1)
  }

  func testAutoSaveExpiredDeadlineDoesNotStartADial() async throws {
    let selected = try XCTUnwrap(IPv4Address("192.168.1.53"))
    do {
      _ = try await NetworkByteChannel.connectAutoSave(to: selected, deadline: .now) { _ in
        XCTFail("An expired invitation opened a command socket")
        return TestConnection()
      }
      XCTFail("An expired invitation became ready")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .timeout(.tcpSetup))
    }
  }

  func testEndpointComesFromRecognizedModeAndRequiresWiFi() throws {
    for mode in [WirelessMode.xApp, .phone] {
      let endpoint = try NetworkByteChannel.Endpoint.cameraHosted(mode: mode)
      XCTAssertEqual(endpoint.mode, mode)
      XCTAssertEqual(endpoint.address, IPv4Address("192.168.0.1"))
      XCTAssertEqual(endpoint.port.rawValue, 55_740)
    }
    XCTAssertThrowsError(try NetworkByteChannel.Endpoint.cameraHosted(mode: .autoSave))
    let selected = try XCTUnwrap(IPv4Address("192.168.1.53"))
    let endpoint = NetworkByteChannel.Endpoint.autoSave(selectedPeer: selected)
    XCTAssertEqual(endpoint.mode, .autoSave)
    XCTAssertEqual(endpoint.address, selected)
    XCTAssertEqual(endpoint.port.rawValue, 55_740)

    let parameters = NetworkByteChannel.connectionParameters()
    XCTAssertEqual(parameters.requiredInterfaceType, .wifi)
    XCTAssertTrue(parameters.prohibitedInterfaceTypes?.contains(.cellular) == true)
  }

  func testLocalNetworkDenialAndUnavailableRouteHaveSeparateFailures() {
    XCTAssertEqual(
      NetworkByteChannel.waitingFailure(.posix(.ENETDOWN), reason: .localNetworkDenied),
      .permissionDenied(.localNetwork))
    XCTAssertEqual(
      NetworkByteChannel.waitingFailure(.posix(.ENETDOWN), reason: .wifiDenied),
      .routeUnavailable)
    XCTAssertEqual(
      NetworkByteChannel.waitingFailure(.posix(.ENETUNREACH), reason: .notAvailable),
      .routeUnavailable)
    XCTAssertNil(NetworkByteChannel.waitingFailure(.posix(.ETIMEDOUT), reason: nil))
    XCTAssertNil(NetworkByteChannel.waitingFailure(.posix(.ECONNREFUSED), reason: nil))
    XCTAssertEqual(
      NetworkByteChannel.waitingFailure(.posix(.ECONNREFUSED), reason: nil, reportRefusal: true),
      .autoSavePeerUnreachable)
    XCTAssertEqual(
      NetworkByteChannel.waitingFailure(.posix(.ECONNREFUSED), reason: .localNetworkDenied, reportRefusal: true),
      .permissionDenied(.localNetwork))
  }

  func testConnectDeadlineClosesAndDiscardsLateReady() async throws {
    let driver = TestConnection()
    let trace = Mutex([WirelessIdentityTrace.Event]())
    let channel = NetworkByteChannel(
      driver: driver, setupTimeout: .milliseconds(25),
      identityTrace: { event in trace.withLock { $0.append(event) } })
    do {
      try await channel.start()
      XCTFail("Inactive connection became ready")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .timeout(.tcpSetup))
    }
    XCTAssertEqual(driver.cancelCount, 1)
    driver.emit(.ready)
    do {
      _ = try await channel.read(maximumBytes: 1)
      XCTFail("Late ready reopened closed channel")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .timeout(.tcpSetup))
    }
    XCTAssertEqual(trace.withLock { $0 }, [
      .init(.tcpConnect, .waiting),
      .init(.tcpConnect, .failed, failure: .tcpSetupTimeout),
      .init(.socketClose, .waiting),
      .init(.socketClose, .completed),
    ])
  }

  func testReadCapsRequestAndDeliversFinalBytesBeforeEOF() async throws {
    let driver = TestConnection()
    let channel = try await connected(driver)
    let pending = Task { try await channel.read(maximumBytes: 400_000) }
    try await eventually { driver.requestedRead != nil }
    XCTAssertEqual(driver.requestedRead, 65_536)
    driver.finishRead(data: Data([1, 2]), isComplete: true)
    let bytes = try await pending.value
    XCTAssertEqual(bytes, Data([1, 2]))
    let eof = try await channel.read(maximumBytes: 5)
    XCTAssertTrue(eof.isEmpty)
    XCTAssertEqual(driver.readCount, 1)
    await channel.close()
  }

  func testCancelledReadAndExplicitCloseIgnoreLateCompletion() async throws {
    let driver = TestConnection(automaticallyAcknowledgesClose: false)
    let channel = try await connected(driver)
    let pending = Task { try await channel.read(maximumBytes: 64) }
    try await eventually { driver.requestedRead != nil }
    pending.cancel()
    try await eventually { driver.cancelCount == 1 }
    let succeeded = Mutex(false)
    let close = Task {
      await channel.close()
      succeeded.withLock { $0 = true }
    }
    driver.finishRead(data: Data([1]), isComplete: false)
    try await Task.sleep(for: .milliseconds(15))
    XCTAssertFalse(succeeded.withLock { $0 })
    driver.emit(.cancelled)
    await close.value
    do {
      _ = try await pending.value
      XCTFail("Canceled read succeeded")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(driver.cancelCount, 1)
    XCTAssertTrue(succeeded.withLock { $0 })
  }

  func testExplicitCloseUnblocksPendingWrite() async throws {
    let driver = TestConnection()
    let channel = try await connected(driver)
    let pending = Task { try await channel.write(Data([0x12])) }
    try await eventually { driver.written != nil }
    await channel.close()
    driver.finishWrite()
    do {
      try await pending.value
      XCTFail("Closed channel finished pending write successfully")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .connectionLost)
    }
    XCTAssertEqual(driver.written, Data([0x12]))
    XCTAssertEqual(driver.cancelCount, 1)
  }

  func testPermissionDenialTerminatesPendingSetupWithSpecificFailure() async throws {
    let driver = TestConnection()
    let channel = NetworkByteChannel(driver: driver)
    let setup = Task { try await channel.start() }
    try await eventually { driver.started }
    driver.emit(.failed(.permissionDenied(.localNetwork)))
    do {
      try await setup.value
      XCTFail("Denied connection became ready")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .permissionDenied(.localNetwork))
    }
    XCTAssertEqual(driver.cancelCount, 1)
  }

  private func connected(
    _ driver: TestConnection, trace: WirelessIdentityTrace.Observer? = nil
  ) async throws -> NetworkByteChannel {
    let channel = NetworkByteChannel(driver: driver, identityTrace: trace)
    let setup = Task { try await channel.start() }
    try await eventually { driver.started }
    driver.emit(.ready)
    try await setup.value
    return channel
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw WirelessFailure.timeout(.tcpSetup) }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

/// Synthetic Network.framework callbacks allow deterministic late/duplicate events with no
/// camera, route, or application permission dependency on the simulator.
private final class TestConnection: NetworkByteChannel.Driver {
  private struct State {
    var handler: (@Sendable (NetworkByteChannel.Event) -> Void)?
    var readCount = 0
    var readCompletion: (@Sendable (Result<NetworkByteChannel.Read, WirelessFailure>) -> Void)?
    var writeCompletion: (@Sendable (Result<Void, WirelessFailure>) -> Void)?
    var requestedRead: Int?
    var written: Data?
    var cancelCount = 0
  }

  private let state = Mutex(State())
  private let automaticallyAcknowledgesClose: Bool
  let localEndpoint: NWEndpoint?
  init(automaticallyAcknowledgesClose: Bool = true, localEndpoint: NWEndpoint? = nil) {
    self.automaticallyAcknowledgesClose = automaticallyAcknowledgesClose
    self.localEndpoint = localEndpoint
  }

  var started: Bool { state.withLock { $0.handler != nil } }
  var readCount: Int { state.withLock { $0.readCount } }
  var requestedRead: Int? { state.withLock { $0.requestedRead } }
  var written: Data? { state.withLock { $0.written } }
  var cancelCount: Int { state.withLock { $0.cancelCount } }

  func start(_ handler: @escaping @Sendable (NetworkByteChannel.Event) -> Void) {
    state.withLock { $0.handler = handler }
  }

  func read(
    maximumBytes: Int,
    completion: @escaping @Sendable (Result<NetworkByteChannel.Read, WirelessFailure>) -> Void
  ) {
    state.withLock {
      $0.readCount += 1
      $0.requestedRead = maximumBytes
      $0.readCompletion = completion
    }
  }

  func write(
    _ data: Data, completion: @escaping @Sendable (Result<Void, WirelessFailure>) -> Void
  ) {
    state.withLock {
      $0.written = data
      $0.writeCompletion = completion
    }
  }

  func finishRead(data: Data, isComplete: Bool) {
    let callback = state.withLock { $0.readCompletion }
    callback?(.success(.init(data: data, isComplete: isComplete)))
  }

  func finishWrite() {
    let callback = state.withLock { $0.writeCompletion }
    callback?(.success(()))
  }

  func cancel() {
    state.withLock { $0.cancelCount += 1 }
    if automaticallyAcknowledgesClose { emit(.cancelled) }
  }

  func emit(_ event: NetworkByteChannel.Event) {
    let handler = state.withLock { $0.handler }
    handler?(event)
  }
}
