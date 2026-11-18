import CryptoKit
import Foundation
import Synchronization
import XCTest

@testable import FujiCameraCore

final class WirelessTransferSessionTests: XCTestCase, @unchecked Sendable {
  private let mixedXAppEvents = Data([
    0x02, 0x00, 0x1b, 0xd2, 0x0f, 0x00, 0x00, 0x00, 0x2f, 0xd2, 0x01, 0x00, 0x00,
  ])

  func testXAppInitializationWritesTheConfiguredClientNameAndPreservesTheDefault() async throws {
    let camera = identity(.xt5)
    let guid = Data(0..<16)
    let standard = Replay(start(.xt5, "4.31") + [.read(0x1003)])
    let manual = Replay(start(.xt5, "4.31") + [.read(0x1003)])
    let standardSession = XAppTransferAdapter.makeSession(
      transport: .init(channel: standard), expectedIdentity: camera, clientGUID: guid)
    let manualSession = XAppTransferAdapter.makeSession(
      transport: .init(channel: manual), expectedIdentity: camera, clientGUID: guid, clientName: "Fuji iPhone")

    for (session, channel, name) in [
      (standardSession, standard, "Fuji Studio"), (manualSession, manual, "Fuji iPhone"),
    ] {
      _ = try await session.open()
      let frame = await channel.initializationRequest
      let nameBytes = try XCTUnwrap(name.data(using: .utf16LittleEndian))
      let expected = word(82) + word(1) + word(0x8f53e4f2) + guid + nameBytes
        + Data(repeating: 0, count: 54 - nameBytes.count)
      XCTAssertEqual(frame, expected)
      try await session.close()
    }
  }

  func testXAppEventReaderAcceptsOnlyTheCapturedShortFilenameEvent() async throws {
    let filenameEvent = Data([0x01, 0x00, 0x2f, 0xd2, 0x01, 0x00, 0x00])
    let malformed = [
      Data(filenameEvent.dropLast()),
      filenameEvent + Data([0, 0]),
      Data([0x01, 0x00, 0x30, 0xd2, 0x01, 0x00, 0x00]),
    ]
    let numeric = Data([0x01, 0x00, 0x2f, 0xd2, 0x78, 0x56, 0x34, 0x12])
    let replies = [filenameEvent, numeric, Data([0, 0])] + malformed
    let channel = Replay(start(.xt5, "4.31")
      + replies.map { .property(0xd212, $0) } + [.read(0x1003)])
    let session = CameraHostedTransferSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5), mode: .xApp,
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    let filename = try await session.readEvents()
    let scalar = try await session.readEvents()
    let empty = try await session.readEvents()
    XCTAssertEqual(filename, [:])
    XCTAssertEqual(scalar, [0xd22f: 0x12345678])
    XCTAssertEqual(empty, [:])
    for _ in malformed {
      await expect(.malformedData) { _ = try await session.readEvents() }
    }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testXAppEventReaderPreservesNumericEventsBeforeTheShortFilenameEvent() async throws {
    let filename = Data([0x2f, 0xd2, 0x01, 0x00, 0x00])
    let numeric = events([(0xd21b, 15), (0xd22f, 0x12345678), (0xdf00, 6)]).dropFirst(2)
    let replies: [(Data, [UInt32: UInt32])] = [
      (mixedXAppEvents, [0xd21b: 15]),
      (Data([4, 0]) + numeric + filename, [0xd21b: 15, 0xd22f: 0x12345678, 0xdf00: 6]),
    ]
    let records = Data(mixedXAppEvents.dropFirst(2))
    let deviceError = Data(events([(0xd21b, 15)]).dropFirst(2))
    let oversized = word(4097, 2) + Data(repeating: 0, count: 4096 * 6)
    let malformed: [Data] = [
      Data([0x00, 0x00]) + records,
      Data([0x03, 0x00]) + records,
      Data(mixedXAppEvents.dropLast()),
      mixedXAppEvents + Data([0, 0]),
      Data(mixedXAppEvents.dropLast()) + Data([1]),
      Data(mixedXAppEvents.dropLast(5)) + Data([0x30, 0xd2, 1, 0, 0]),
      Data([0x02, 0x00]) + filename + deviceError,
      oversized + filename,
    ]
    let channel = Replay(start(.xt5, "4.31")
      + (replies.map { $0.0 } + malformed).map { .property(0xd212, $0) }
      + [.read(0x1003)])
    let session = CameraHostedTransferSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5), mode: .xApp,
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    for (_, expected) in replies {
      let actual = try await session.readEvents()
      XCTAssertEqual(actual, expected)
    }
    for _ in malformed {
      await expect(.malformedData) { _ = try await session.readEvents() }
    }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testLegacyEventReadersRejectTheShortXAppFilenameEvent() async throws {
    let filename = Data([0x01, 0x00, 0x2f, 0xd2, 0x01, 0x00, 0x00])
    for mode in [WirelessMode.phone, .autoSave] {
      let channel = Replay(start(.xe3, "1.32") + [
        .property(0xd212, filename), .property(0xd212, mixedXAppEvents), .read(0x1003),
      ])
      let camera = mode == .autoSave ? autoSaveIdentity() : identity(.xe3)
      let session = CameraHostedTransferSession(
        transport: .init(channel: channel), expectedIdentity: camera, mode: mode,
        clientGUID: Data(repeating: 1, count: 16))
      _ = try await session.open()
      for _ in 0..<2 {
        await expect(.malformedData) { _ = try await session.readEvents() }
      }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  #if DEBUG
  func testManualXAppDiagnosticAcceptsExactEmptyDeviceInfoWithReadOnlyStartup() async throws {
    let channel = Replay([.read(0x1002, [1]), .emptyDeviceInfo,
      .property(0xd212, events()), .property(0xd212, events([(0xdf00, 0)])),
      .property(0xd212, events([(0xdf00, 6)])), .property(0xdf24, word(0x2000b)),
      .read(0x1003)])
    let session = CameraHostedTransferSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5), mode: .xApp,
      clientGUID: Data(repeating: 1, count: 16))
    let result = try await session.checkConnection()
    XCTAssertEqual(result, .respondingWithoutDeviceInfo)
    await expect(.connectionLost) { _ = try await session.capabilities() }
    await expect(.connectionLost) { _ = try await session.enumerate() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }
  func testManualXAppDiagnosticKeepsValidDeviceInfoWithoutAdmittingTransfer() async throws {
    let channel = Replay(start(.xt5, "4.31") + [.read(0x1003)])
    let camera = identity(.xt5)
    let session = diagnosticSession(channel, camera: camera)
    let result = try await session.checkConnection()
    guard case .identified(let peer) = result else { return XCTFail("DeviceInfo identity was lost") }
    XCTAssertEqual(peer.model, .xt5)
    XCTAssertEqual(peer.firmware, "4.31")
    XCTAssertEqual(peer.cameraID, camera.cameraID)
    await expect(.connectionLost) { _ = try await session.capabilities() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testManualXAppDiagnosticRejectsUnprovenEmptyAndMalformedDeviceInfo() async throws {
    for step in [Exchange.read(0x1001), .read(0x1001, [], Data([1]))] {
      let channel = Replay([.read(0x1002, [1]), step, .read(0x1003)])
      let session = diagnosticSession(channel)
      await expect(.malformedData) { _ = try await session.checkConnection() }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
    let channel = Replay(start(.xe3, "1.32") + [.read(0x1003)])
    let session = diagnosticSession(channel)
    await expect(.peerMismatch) { _ = try await session.checkConnection() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testManualXAppDiagnosticRejectsInvalidWireRepliesBeforeReadingProperties() async throws {
    var wrongID = Exchange.emptyDeviceInfo
    wrongID.responseTransaction = 3
    var wrongCode = Exchange.emptyDeviceInfo
    wrongCode.dataCode = 0x1008
    var rejected = Exchange.emptyDeviceInfo
    rejected.response = 0x2002
    for (step, failure) in [
      (wrongID, PTPError.wrongTransaction(expected: 2, actual: 3)),
      (wrongCode, .invalidOpcode(0x1008)),
      (rejected, .responseCode(0x2002)),
    ] {
      let cleanup: [Exchange] = step.response == 0x2002 ? [.read(0x1003)] : []
      let channel = Replay([.read(0x1002, [1]), step] + cleanup)
      let session = diagnosticSession(channel)
      do {
        _ = try await session.checkConnection()
        XCTFail("Invalid wire response was accepted")
      } catch { XCTAssertEqual(error as? PTPError, failure) }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testManualXAppDiagnosticRejectsUnexpectedAccessStateAndRemoteVersion() async throws {
    for (checks, failure) in [
      ([Exchange.property(0xd212, events([(0xdf00, 3)]))], WirelessFailure.unsupportedProtocol),
      ([.property(0xd212, events([(0xdf00, 6)])), .property(0xdf24, word(0x20006))], .unsupportedProtocol),
      ([.property(0xd212, events([(0xdf00, 6)])), .property(0xdf24, word(0x2000d))], .unsupportedProtocol),
      ([.property(0xd212, events([(0xdf00, 6)])), .property(0xdf24, word(0x000b, 2))], .malformedData),
    ] {
      let channel = Replay([.read(0x1002, [1]), .emptyDeviceInfo] + checks + [.read(0x1003)])
      let session = diagnosticSession(channel)
      await expect(failure) { _ = try await session.checkConnection() }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testManualXAppDiagnosticCancellationDuringAccessWaitClosesSocket() async throws {
    let channel = Replay([.read(0x1002, [1]), .emptyDeviceInfo,
      .property(0xd212, events()), .read(0x1003)])
    let (waiting, signal) = AsyncStream<Void>.makeStream()
    let session = diagnosticSession(channel) { event in
      if event.stage == .xAppAccess && event.action == .waiting { signal.yield() }
    }
    let probe = Task {
      defer { signal.finish() }
      return try await session.checkConnection()
    }
    for await _ in waiting { break }
    probe.cancel()
    do {
      _ = try await probe.value
      XCTFail("A cancelled diagnostic returned a result")
    } catch is CancellationError {}
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryAppliesCapturedJPEGRAWFilterAfterColdInventory() async throws {
    // X-T5 04.31 cold transactions 1–17, then the combined filter and
    // refresh from transactions 2319–2323. Inventory is reduced for replay.
    let handles = (101...134).map(UInt32.init)
    let list = handles.reduce(into: Data()) { $0 += word($1) }
    let metadata = handles.map {
      if $0 == 133 { return Exchange.read(0x1008, [$0], object("PAIR.RAF", format: 0xb103, bytes: 789)) }
      if $0 == 134 { return Exchange.read(0x1008, [$0], object("PAIR.JPG", format: 0x3801, bytes: 456)) }
      return Exchange.read(0x1008, [$0], object("PHOTO\($0).JPG", format: 0x3801, bytes: 456))
    }
    let channel = Replay([
      .read(0x1002, [1]),
      .property(0xd212, events([(0xdf00, 6), (0xd222, 35)])),
      .write(0xdf01, [20, 0]), .property(0xdf28, word(3)), .write(0xdf28, [3, 0, 0, 0]),
      .property(0xd244, Data([2])), .property(0xd212, events([(0xdf00, 20), (0xd222, 35)])),
      .property(0xd244, Data([2])), .read(0x9054, [0x10000001]),
      .read(0x9055, [0x10000001]), .read(0x9050),
      .property(0xd212, Data([0x01, 0x00, 0x2f, 0xd2, 0x01, 0x00, 0x00])), .property(0xd22b, word(35)),
      .read(0x9053, [0, 30000]), .property(0xd212, events()),
      .property(0xd620, word(35)), .property(0xd621, word(35) + word(20) + list),
      .galleryJPEGRAWFilter,
      .read(0x9053, [0, 30000]), .property(0xd212, events()),
      .property(0xd620, word(34)), .property(0xd621, word(34) + list),
      originalMode,
    ] + metadata + [
      .write(0xd244, [1]), .property(0xd244, Data([1])),
      .rejection(0x9054, [0x10000001], 0x2013), .read(0x1003),
    ])
    let (observations, trace) = AsyncStream<WirelessIdentityTrace.Event>.makeStream()
    let session = diagnosticSession(channel) { trace.yield($0) }
    let result = try await session.listCameraPhotos()
    XCTAssertFalse(result.wifiIdentityAvailable)
    XCTAssertEqual(result.cards.map(\.summary.totalHandles), [34, nil])
    XCTAssertEqual(result.cards.map(\.summary.jpegCount), [33, 0])
    XCTAssertEqual(result.cards.map(\.summary.rafCount), [1, 0])
    XCTAssertEqual(result.cards.first?.samples.count, 32)
    XCTAssertEqual(result.cards.first?.samples.first?.filename, "PHOTO101.JPG")
    let candidates = try await session.scannedPairCandidates()
    XCTAssertEqual(Set(candidates.map(\.handle)), Set(handles))
    XCTAssertEqual(Set(candidates.filter { $0.handle >= 133 }.map(\.filename)), ["PAIR.JPG", "PAIR.RAF"])
    await expect(.connectionLost) { _ = try await session.enumerate() }
    try await session.close()
    trace.finish()
    var milestones: [WirelessIdentityTrace.Event] = []
    for await event in observations where event.galleryVersion != nil || event.galleryHandleCount != nil {
      milestones.append(event)
    }
    XCTAssertEqual(milestones, [
      .init(.galleryVersionValidation, .completed, galleryVersion: .version3),
      .init(.galleryInitialInventory, .completed, gallerySlot: 2, galleryHandleCount: 35),
      .init(.galleryFilteredInventory, .completed, gallerySlot: 2, galleryHandleCount: 34),
    ])
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryDoesNotReturnInventoryOrDownloadCandidatesAfterInvalidFilterReply() async throws {
    let setup = galleryStartup + cardSetup() + cardRefresh([])
    var rejected = Exchange.galleryJPEGRAWFilter
    rejected.response = 0x2002
    var missing = Exchange.galleryJPEGRAWFilter
    missing.omitsResponse = true
    var wrongTransaction = Exchange.galleryJPEGRAWFilter
    wrongTransaction.responseTransaction = 0
    let failures: [(Exchange, PTPError, [Exchange])] = [
      (rejected, .responseCode(0x2002), [.read(0x1003)]),
      (missing, .truncatedContainer, []),
      (wrongTransaction, .wrongTransaction(expected: UInt32(setup.count + 1), actual: 0), []),
    ]
    let candidate = WirelessObjectDescriptor(
      cameraID: .init(), sessionID: .init(), storageID: 1, handle: 1, filename: "PAIRED.RAF", format: .raf, byteLength: 3)
    for (filter, failure, cleanup) in failures {
      let channel = Replay(setup + [filter] + cleanup)
      let session = diagnosticSession(channel)
      do {
        _ = try await session.listCameraPhotos()
        XCTFail("A failed filter selection returned a gallery")
      } catch {
        XCTAssertEqual(error as? PTPError, failure)
      }
      await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
      await expect(.objectChanged) { _ = try await session.downloadGalleryCandidate(candidate) { _ in XCTFail() } }
      try await session.close()
      let remaining = await channel.remaining
      let closed = await channel.closed
      XCTAssertEqual(remaining, 0)
      XCTAssertTrue(closed)
    }
  }

  func testPhotoCountsReuseValidatedGalleryInventoryWithoutReadingMetadataOrDownloading() async throws {
    let unavailable: [Exchange] = [
      .property(0xd244, Data([2])), .rejection(0x9054, [0x10000001], 0x2013),
    ]
    for (first, second, expected) in [
      (card(Array(1...548)), unavailable, [548, nil]),
      (card(Array(1...1_167)), card([], storage: 2), [1_167, 0]),
    ] {
      // The strict replay accepts only setup, inventory and graceful close.
      let channel = Replay(galleryStartup + first + [.write(0xd244, [2])] + second + [.read(0x1003)])
      let session = diagnosticSession(channel)
      let counts = try await session.checkPhotoCounts()
      XCTAssertEqual(counts.cards.map(\.slot), [1, 2])
      XCTAssertEqual(counts.cards.map(\.totalHandles), expected)
      await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
      try await session.close()
      let remaining = await channel.remaining
      let closed = await channel.closed
      XCTAssertEqual(remaining, 0)
      XCTAssertTrue(closed)
    }
  }

  func testPhotoCountsRejectMismatchedHandleListAndClose() async throws {
    let mismatched = card([1, 2]).dropLast() + [cardRefresh([1]).last!]
    let channel = Replay(galleryStartup + mismatched + [.read(0x1003)])
    let session = diagnosticSession(channel)
    await expect(.malformedData) { _ = try await session.checkPhotoCounts() }
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testPhotoCountsReplayCapturedGalleryStartupTiming() async throws {
    let unavailable: [Exchange] = [
      .property(0xd244, Data([2])), .rejection(0x9054, [0x10000001], 0x2013),
    ]
    let channel = Replay(galleryStartup + card([1]) + [.write(0xd244, [2])] + unavailable + [.read(0x1003)])
    let times = Mutex([(WirelessIdentityTrace.Event, ContinuousClock.Instant)]())
    let session = XAppTransferAdapter.makeGalleryDiagnostic(
      transport: .init(channel: channel, identityTrace: { event in
        times.withLock { $0.append((event, .now)) }
      }), expectedIdentity: identity(.xt5), clientGUID: Data(repeating: 1, count: 16),
      clientName: "iPhone-0000", replayCapturedStartup: true)

    let counts = try await session.checkPhotoCounts()
    XCTAssertEqual(counts.cards.map(\.totalHandles), [1, nil])
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)

    let observed = times.withLock { $0 }
    let gaps: [(WirelessIdentityTrace.Stage, WirelessIdentityTrace.Stage, Duration)] = [
      (.initializationACK, .openSessionWrite, .milliseconds(11)),
      (.openSessionResponseBody, .xAppEventsRead, .milliseconds(207)),
      (.xAppAccess, .galleryModeWrite, .milliseconds(392)),
    ]
    for (response, nextCommand, delay) in gaps {
      let responseTime = try XCTUnwrap(observed.first { $0.0.stage == response && $0.0.action == .completed }?.1)
      let commandTime = try XCTUnwrap(observed.first { $0.0.stage == nextCommand && $0.0.action == .waiting }?.1)
      XCTAssertGreaterThanOrEqual(responseTime.duration(to: commandTime), delay)
    }
  }

  func testGalleryDistinguishesEmptyAndUnavailableCards() async throws {
    let channel = Replay(galleryStartup + card([])
      + [originalMode, .write(0xd244, [2]), .property(0xd244, Data([2])),
        .rejection(0x9054, [0x10000001], 0x2013), .read(0x1003)])
    let session = diagnosticSession(channel)
    let result = try await session.listCameraPhotos()
    XCTAssertEqual(result.cards.map(\.summary.status), [.available, .unavailable])
    XCTAssertEqual(result.cards.map(\.summary.totalHandles), [0, nil])
    XCTAssertEqual(result.cards.map(\.summary.scannedCount), [0, 0])
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryEnumeratesTheSecondSlotAfterMixedEvents() async throws {
    // Regression replay of the native card-switch sequence using the captured
    // event bytes. The official trace returned those bytes on the first slot.
    let unavailableSlot: [Exchange] = [
      .property(0xd244, Data([1])), .rejection(0x9054, [0x10000001], 0x2013),
      .write(0xd244, [2]),
    ]
    let availableSlot = card([1, 2], storage: 2, postOpenEvents: mixedXAppEvents)
    let inventory: [Exchange] = [
      originalMode,
      .read(0x1008, [1], object("PAIR.RAF", format: 0xb103, bytes: 3)),
      .read(0x1008, [2], object("PAIR.JPG", format: 0x3801, bytes: 5)),
    ]
    let channel = Replay(galleryStartup + unavailableSlot + availableSlot + inventory + [.read(0x1003)])
    let session = diagnosticSession(channel)
    let gallery = try await session.listCameraPhotos()
    XCTAssertEqual(gallery.cards.map(\.summary.status), [.unavailable, .available])
    XCTAssertEqual(gallery.cards.map(\.summary.totalHandles), [nil, 2])
    XCTAssertEqual(gallery.cards.map(\.summary.rafCount), [0, 1])
    XCTAssertEqual(gallery.cards.map(\.summary.jpegCount), [0, 1])
    let candidates = try await session.scannedPairCandidates()
    XCTAssertEqual(candidates.map(\.storageID), [2, 2])
    XCTAssertEqual(Set(candidates.map(\.filename)), ["PAIR.RAF", "PAIR.JPG"])
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryRejectsInvalidHandlesAndMetadataBeforeReturningResults() async throws {
    let duplicate = card([1, 1])
    let mismatch = Array(card([1]).dropLast()) + [.property(0xd621, word(0))]
    let malformed = card([1]) + [originalMode, .read(0x1008, [1], Data([1]))]
    let coldCountMismatch = cardSetup() + [
      .read(0x9053, [0, 30000]), .property(0xd212, events()),
      .property(0xd620, word(1)), .property(0xd621, word(0)),
    ]
    for steps in [coldCountMismatch, duplicate, mismatch, malformed] {
      let channel = Replay(galleryStartup + steps + [.read(0x1003)])
      let session = diagnosticSession(channel)
      await expect(.malformedData) { _ = try await session.listCameraPhotos() }
      await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testGalleryStopsAfterMalformedPostRefreshEvents() async throws {
    let invalidRefresh: [Exchange] = [
      .read(0x9053, [0, 30000]), .property(0xd212, word(1, 2)),
    ]
    let filteredSetup = cardRefresh([]) + [.galleryJPEGRAWFilter]
    for priorSteps in [[], filteredSetup] {
      let channel = Replay(galleryStartup + cardSetup() + priorSteps + invalidRefresh + [.read(0x1003)])
      let session = diagnosticSession(channel)
      await expect(.malformedData) { _ = try await session.listCameraPhotos() }
      await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testGalleryRejectsUnsupportedBluetoothFirmwareBeforeWirelessTraffic() async throws {
    let channel = Replay([])
    let camera = WirelessIdentity(cameraID: WirelessCameraID(), model: .xt5, firmware: "4.29")
    let session = diagnosticSession(channel, camera: camera)
    await expect(.unsupportedFirmware) { _ = try await session.listCameraPhotos() }
    try await session.close()
    let initialization = await channel.initializationRequest
    XCTAssertNil(initialization)
  }

  func testGalleryRejectsUnsupportedAccessBeforeGalleryWrites() async throws {
    let channel = Replay([.read(0x1002, [1]), .property(0xd212, events([(0xdf00, 3)])), .read(0x1003)])
    let session = diagnosticSession(channel)
    await expect(.unsupportedProtocol) { _ = try await session.listCameraPhotos() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryRejectsUnsupportedGalleryVersionBeforeEcho() async throws {
    let channel = Replay([.read(0x1002, [1]), .property(0xd212, events([(0xdf00, 6)])),
      .write(0xdf01, [20, 0]), .property(0xdf28, word(4)), .read(0x1003)])
    let session = diagnosticSession(channel)
    await expect(.unsupportedProtocol) { _ = try await session.listCameraPhotos() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryRejectsUncorrelatedHandleListAndClosesSocket() async throws {
    var response = card([1]).last!
    response.responseTransaction = 999
    let channel = Replay(galleryStartup
      + card([1]).dropLast() + [response])
    let session = diagnosticSession(channel)
    do {
      _ = try await session.listCameraPhotos()
      XCTFail("An uncorrelated handle list returned a gallery")
    } catch PTPError.wrongTransaction(_, let actual) {
      XCTAssertEqual(actual, 999)
    }
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryAbortClosesSocketWhileObjectInfoReplyIsPending() async throws {
    let channel = Replay(galleryStartup
      + card([1]) + [originalMode, .read(0x1008, [1], object("PENDING.JPG", format: 0x3801, bytes: 456))])
    let (pending, signal) = AsyncStream<Void>.makeStream()
    await channel.holdReply(matching: .read(0x1008, [1]), signal)
    let session = diagnosticSession(channel)
    let listing = Task { try await session.listCameraPhotos() }
    for await _ in pending { break }
    await session.abortGallery()
    do {
      _ = try await listing.value
      XCTFail("An aborted diagnostic returned a result")
    } catch {}
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryNegotiatesFullJPEGSizeBeforeScanningAndRestoresPriorMode() async throws {
    let fullLength: UInt32 = 1_048_577
    let original = object("CANDIDATE.JPG", format: 0x3801, bytes: fullLength)
    let placeholder = object("CANDIDATE.JPG", format: 0x3801, bytes: 167_936)
    let fullBlock = Data(repeating: 0xff, count: Int(fullLength - 1))
    for prior: UInt8 in [0, 1] {
      var modeRead = Exchange.property(0xd226, word(UInt32(prior), 2))
      modeRead.alternative = [.read(0x1008, [1], placeholder)]
      let channel = Replay(galleryStartup + card([1]) + [
        modeRead, .write(0xd226, [2, 0]), originalMode, .read(0x1008, [1], original),
        .write(0xd226, [prior, 0]), .write(0xd244, [2]), .property(0xd244, Data([2])),
        .rejection(0x9054, [0x10000001], 0x2013),
        .write(0xd244, [1]),
      ] + card([1]) + [
        .property(0xd226, word(UInt32(prior), 2)), .write(0xd226, [2, 0]), originalMode,
        .read(0x1008, [1], original),
        .read(0x101b, [1, 0, fullLength - 1], fullBlock),
        .read(0x101b, [1, fullLength - 1, 1], Data([0xd9])),
        .write(0xd226, [prior, 0]), .read(0x1003),
      ])
      let session = diagnosticSession(channel)
      let result = try await session.listCameraPhotos()
      XCTAssertEqual(result.cards[0].samples.first?.byteLength, UInt64(fullLength))
      let candidates = try await session.scannedPairCandidates()
      let member = try XCTUnwrap(candidates.first)
      XCTAssertEqual(member.byteLength, UInt64(fullLength))
      let received = Bytes()
      let control = try await session.downloadGalleryCandidate(member) { await received.append($0) }
      XCTAssertEqual(control, .reported(2))
      let bytes = await received.value
      XCTAssertEqual(bytes, fullBlock + Data([0xd9]))
      try await session.close()
      let remaining = await channel.remaining
      let closed = await channel.closed
      XCTAssertEqual(remaining, 0)
      XCTAssertTrue(closed)
    }
  }

  func testGalleryRejectsUnavailableOrUnconfirmedOriginalSizeBeforeCollectingObjects() async throws {
    var refusal = Exchange.write(0xd226, [2, 0])
    refusal.response = 0x2002
    let cases: [([Exchange], [Exchange])] = [
      ([.rejection(0x1015, [0xd226], 0x200a)], []),
      ([.property(0xd226, Data([1, 0, 0]))], []),
      ([.property(0xd226, word(3))], []),
      ([.property(0xd226, word(1)), refusal], []),
      ([.property(0xd226, word(1)), .write(0xd226, [2, 0]), .property(0xd226, word(1, 2))],
        [.write(0xd226, [1, 0])]),
    ]
    for (negotiation, restoration) in cases {
      let channel = Replay(galleryStartup + card([1])
        + negotiation + restoration + [.read(0x1003)])
      let session = diagnosticSession(channel)
      do {
        _ = try await session.listCameraPhotos()
        XCTFail("Original metadata was admitted without confirmed original size")
      } catch {}
      await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
      try await session.close()
      let remaining = await channel.remaining
      let closed = await channel.closed
      XCTAssertEqual(remaining, 0)
      XCTAssertTrue(closed)
    }
  }

  func testGalleryRestoresModeOnTheChangedCardBeforeSelectingAnotherCard() async throws {
    let raf = object("PAIR.RAF", format: 0xb103, bytes: 3)
    let jpeg = object("PAIR.JPG", format: 0x3801, bytes: 3)
    let negotiateFirst: [Exchange] = [.property(0xd226, word(0, 2)), .write(0xd226, [2, 0]), originalMode]
    let restoreFirst = Exchange.write(0xd226, [0, 0])
    for secondAvailable in [false, true] {
      let secondCard: [Exchange] = secondAvailable
        ? card([1], storage: 2) + [originalMode, .read(0x1008, [1], jpeg)]
        : [.property(0xd244, Data([2])), .rejection(0x9054, [0x10000001], 0x2013)]
      let startup = galleryStartup + card([1])
      var steps = startup + negotiateFirst + [
        .read(0x1008, [1], raf), restoreFirst, .write(0xd244, [2]),
      ] + secondCard
      if secondAvailable {
        steps += [.write(0xd244, [1])] + card([1]) + negotiateFirst + [
          .read(0x1008, [1], raf), .read(0x101b, [1, 0, 3], Data([1, 2, 3])),
          restoreFirst, .write(0xd244, [2]),
        ] + card([1], storage: 2) + [
          originalMode, .read(0x1008, [1], jpeg), .read(0x101b, [1, 0, 3], Data([4, 5, 6])),
        ]
      }
      let prior: [UInt8: UInt8] = [1: 0, 2: 2]
      let channel = Replay(steps + [.read(0x1003)], galleryModes: prior)
      let session = diagnosticSession(channel)
      let gallery = try await session.listCameraPhotos()
      XCTAssertEqual(gallery.cards.map(\.summary.status), [.available, secondAvailable ? .available : .unavailable])
      if secondAvailable {
        let candidates = try await session.scannedPairCandidates()
        let first = try XCTUnwrap(candidates.first { $0.storageID == 1 })
        let second = try XCTUnwrap(candidates.first { $0.storageID == 2 })
        let received = Bytes()
        _ = try await session.downloadGalleryCandidate(first) { await received.append($0) }
        _ = try await session.downloadGalleryCandidate(second) { await received.append($0) }
        let bytes = await received.value
        XCTAssertEqual(bytes, Data([1, 2, 3, 4, 5, 6]))
      }
      try await session.close()
      let finalModes = await channel.galleryModes
      XCTAssertEqual(finalModes, prior)
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testGalleryRestoreRefusalBlocksTheCardSwitchAndClosesTheSocket() async throws {
    var refusal = Exchange.write(0xd226, [0, 0])
    refusal.response = 0x2002
    let channel = Replay(galleryStartup + card([])
      + [.property(0xd226, word(0, 2)), .write(0xd226, [2, 0]), originalMode, refusal, .read(0x1003)],
      galleryModes: [1: 0, 2: 2])
    let session = diagnosticSession(channel)
    do {
      _ = try await session.listCameraPhotos()
      XCTFail("Card selection continued after restoration was refused")
    } catch {
      XCTAssertEqual(error as? PTPError, .responseCode(0x2002))
    }
    await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
    do {
      try await session.close()
      XCTFail("Cleanup discarded the failed restoration")
    } catch {
      XCTAssertEqual(error as? PTPError, .responseCode(0x2002))
    }
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryRestoreRefusalStillClosesSocketAndRemainsAFailedClose() async throws {
    var refusal = Exchange.write(0xd226, [0, 0])
    refusal.response = 0x2002
    let channel = Replay(galleryStartup + card([])
      + [originalMode, .write(0xd244, [2])] + card([], storage: 2)
      + [.property(0xd226, word(0, 2)), .write(0xd226, [2, 0]), originalMode, refusal, .read(0x1003)],
      galleryModes: [1: 2, 2: 0])
    let session = diagnosticSession(channel)
    _ = try await session.listCameraPhotos()
    for _ in 0..<2 {
      do {
        try await session.close()
        XCTFail("Refused restoration was reported as successful cleanup")
      } catch {
        XCTAssertEqual(error as? PTPError, .responseCode(0x2002))
      }
    }
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryAbortWhileOriginalModeAcknowledgementOrRestorationIsPending() async throws {
    let setup = galleryStartup + card([])
    let enable = Exchange.write(0xd226, [2, 0])
    let restore = Exchange.write(0xd226, [0, 0])
    for duringRestore in [false, true] {
      let prior = Exchange.property(0xd226, word(0, 2))
      let steps = duringRestore
        ? setup + [originalMode, .write(0xd244, [2])] + card([], storage: 2) + [prior, enable, originalMode, restore]
        : setup + [prior, enable]
      let channel = Replay(steps)
      let (pending, signal) = AsyncStream<Void>.makeStream()
      let (events, trace) = AsyncStream<WirelessIdentityTrace.Event>.makeStream()
      await channel.holdReply(matching: duringRestore ? restore : enable, signal)
      let session = diagnosticSession(channel) { trace.yield($0) }
      let operation = Task {
        defer { signal.finish() }
        _ = try await session.listCameraPhotos()
        if duringRestore { try await session.close() }
      }
      var replyWasPending = false
      for await _ in pending { replyWasPending = true }
      XCTAssertTrue(replyWasPending)
      operation.cancel()
      await session.abortGallery()
      do {
        try await operation.value
        XCTFail("An abort exposed a successful scan or restoration")
      } catch {}
      do {
        try await session.close()
        XCTFail("An abort with unconfirmed restoration reported successful cleanup")
      } catch {}
      trace.finish()
      var unconfirmed: [WirelessIdentityTrace.Event] = []
      for await event in events where event.stage == .galleryOriginalModeRestoreUnconfirmed {
        unconfirmed.append(event)
      }
      XCTAssertEqual(unconfirmed.count, 1)
      XCTAssertEqual(unconfirmed.first?.galleryOriginalMode, .mode0)
      XCTAssertEqual(unconfirmed.first?.gallerySlot, duringRestore ? 2 : 1)
      XCTAssertEqual(unconfirmed.first?.action, .failed)
      let remaining = await channel.remaining
      let closed = await channel.closed
      XCTAssertEqual(remaining, 0)
      XCTAssertTrue(closed)
    }
  }

  func testGalleryDownloadsBoundedCandidatesFromTheirOwnCardsWhenOriginalModeIsAlreadyActive() async throws {
    let cap = UInt32(1_048_576)
    let raf = object("CANDIDATE.RAF", format: 0xb103, bytes: cap + 1)
    let jpeg = object("CANDIDATE.JPG", format: 0x3801, bytes: 2)
    let rawBlock = Data(repeating: 0x52, count: Int(cap))
    var steps = galleryStartup + card([1])
    steps += [originalMode, .read(0x1008, [1], raf), .write(0xd244, [2])] + card([1], storage: 2)
    steps += [originalMode, .read(0x1008, [1], jpeg), .write(0xd244, [1])] + card([1])
    steps += [
      originalMode, .read(0x1008, [1], raf),
      .read(0x101b, [1, 0, cap], rawBlock), .read(0x101b, [1, cap, 1], Data([0x46])),
      .write(0xd244, [2]),
    ] + card([1], storage: 2)
    steps += [
      originalMode, .read(0x1008, [1], jpeg),
      .read(0x101b, [1, 0, 2], Data([0xff, 0xd8])), .read(0x1003)
    ]
    let channel = Replay(steps)
    let session = diagnosticSession(channel)
    await expect(.objectChanged) { _ = try await session.scannedPairCandidates() }
    _ = try await session.listCameraPhotos()
    let candidates = try await session.scannedPairCandidates()
    let rawObject = try XCTUnwrap(candidates.first { $0.format == .raf })
    let jpegObject = try XCTUnwrap(candidates.first { $0.format == .jpeg })
    XCTAssertEqual(rawObject.storageID, 1)
    XCTAssertEqual(jpegObject.storageID, 2)
    XCTAssertEqual(rawObject.handle, jpegObject.handle)
    await expect(.connectionLost) { try await session.download(rawObject) { _ in XCTFail() } }
    let raw = Bytes()
    let jpg = Bytes()
    let rawControl = try await session.downloadGalleryCandidate(rawObject) { await raw.append($0) }
    let jpegControl = try await session.downloadGalleryCandidate(jpegObject) { await jpg.append($0) }
    XCTAssertEqual(rawControl, .reported(2))
    XCTAssertEqual(jpegControl, .reported(2))
    let rawBytes = await raw.value
    let jpegBytes = await jpg.value
    XCTAssertEqual(rawBytes, rawBlock + Data([0x46]))
    XCTAssertEqual(jpegBytes, Data([0xff, 0xd8]))
    try await session.close()
    await expect(.connectionLost) { _ = try await session.scannedPairCandidates() }
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryDownloadRetriesOnlyConfirmationAfterAnAcknowledgedModeChange() async throws {
    let info = object("CANDIDATE.RAF", format: 0xb103, bytes: 3)
    let mismatchedMode = Exchange.property(0xd226, word(1, 2))
    let channel = Replay(galleryStartup + card([1])
      + [originalMode, .read(0x1008, [1], info), .write(0xd244, [2])] + card([], storage: 2)
      + [originalMode, .write(0xd244, [1])] + card([1]) + [
        .property(0xd226, word(0, 2)), .write(0xd226, [2, 0]), mismatchedMode,
        mismatchedMode, originalMode, .read(0x1008, [1], info),
        .read(0x101b, [1, 0, 3], Data([1, 2, 3])), .write(0xd226, [0, 0]), .read(0x1003),
      ])
    let session = diagnosticSession(channel)
    _ = try await session.listCameraPhotos()
    let candidates = try await session.scannedPairCandidates()
    let member = try XCTUnwrap(candidates.first)
    for _ in 0..<2 {
      await expect(.originalSizeUnavailable) {
        _ = try await session.downloadGalleryCandidate(member) { _ in
          XCTFail("Unconfirmed original mode reached the download sink")
        }
      }
    }
    let received = Bytes()
    _ = try await session.downloadGalleryCandidate(member) { await received.append($0) }
    let bytes = await received.value
    XCTAssertEqual(bytes, Data([1, 2, 3]))
    try await session.close()
    let remaining = await channel.remaining
    let closed = await channel.closed
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(closed)
  }

  func testGalleryDownloadRetryReconfiguresCardAfterFilterWasRefused() async throws {
    let info = object("CANDIDATE.RAF", format: 0xb103, bytes: 3)
    var rejectedFilter = Exchange.galleryJPEGRAWFilter
    rejectedFilter.response = 0x2002
    let selectFirst: [Exchange] = [.write(0xd244, [1])]
    let channel = Replay(galleryStartup + card([1])
      + [originalMode, .read(0x1008, [1], info), .write(0xd244, [2])] + card([], storage: 2)
      + [originalMode] + selectFirst + cardSetup() + cardRefresh([]) + [rejectedFilter]
      + selectFirst + card([1]) + [
        .property(0xd226, word(2, 2)), .read(0x1008, [1], info),
        .read(0x101b, [1, 0, 3], Data([1, 2, 3])), .read(0x1003),
      ])
    let session = diagnosticSession(channel)
    _ = try await session.listCameraPhotos()
    let candidates = try await session.scannedPairCandidates()
    let member = try XCTUnwrap(candidates.first)
    do {
      _ = try await session.downloadGalleryCandidate(member) { _ in XCTFail("Rejected filter reached sink") }
      XCTFail("Rejected filter allowed download")
    } catch {
      XCTAssertEqual(error as? PTPError, .responseCode(0x2002))
    }
    let received = Bytes()
    _ = try await session.downloadGalleryCandidate(member) { await received.append($0) }
    let bytes = await received.value
    XCTAssertEqual(bytes, Data([1, 2, 3]))
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryCandidateRejectsForeignMemberAndChangedObjectAfterUnavailableCard() async throws {
    let raf = object("CANDIDATE.RAF", format: 0xb103, bytes: 3)
    let changed = object("CHANGED.RAF", format: 0xb103, bytes: 3)
    let channel = Replay(galleryStartup + card([1])
      + [originalMode, .read(0x1008, [1], raf), .write(0xd244, [2]), .property(0xd244, Data([2])),
         .rejection(0x9054, [0x10000001], 0x2013), .write(0xd244, [1])] + card([1])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [1], changed), .read(0x1003)])
    let session = diagnosticSession(channel)
    _ = try await session.listCameraPhotos()
    let candidates = try await session.scannedPairCandidates()
    let member = try XCTUnwrap(candidates.first)
    let foreign = WirelessObjectDescriptor(cameraID: member.cameraID, sessionID: UUID(),
      storageID: member.storageID, handle: member.handle, filename: member.filename, format: member.format,
      byteLength: member.byteLength, captureDate: member.captureDate, dimensions: member.dimensions,
      orientation: member.orientation, reportedStorageID: member.reportedStorageID, hasThumbnail: member.hasThumbnail)
    await expect(.objectChanged) {
      _ = try await session.downloadGalleryCandidate(foreign) { _ in XCTFail("Foreign candidate reached sink") }
    }
    await expect(.objectChanged) {
      _ = try await session.downloadGalleryCandidate(member) { _ in XCTFail("Changed candidate reached sink") }
    }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testGalleryCandidateAbortsOnFatalD226OrInvalidPartialObject() async throws {
    let info = object("CANDIDATE.RAF", format: 0xb103, bytes: 3)
    let validPrelude: [Exchange] = [originalMode, .read(0x1008, [1], info)]
    let badTransaction = Exchange(opcode: 0x101b, parameters: [1, 0, 3], payload: Data([1, 2, 3]),
      responseTransaction: 0)
    let cases: [([Exchange], PTPError)] = [
      ([.rejection(0x1015, [0xd226], 0x2002)], .responseCode(0x2002)),
      (validPrelude + [.init(opcode: 0x101b, parameters: [1, 0, 3], sendsEmptyData: true)], .truncatedContainer),
      (validPrelude + [.read(0x101b, [1, 0, 3], Data([1, 2, 3, 4]))], .payloadTooLarge),
      (validPrelude + [.rejection(0x101b, [1, 0, 3], 0x2002)], .responseCode(0x2002))
    ]
    for (transfer, expected) in cases + [(validPrelude + [badTransaction], .wrongTransaction(expected: 33, actual: 0))] {
      let channel = Replay(galleryStartup + card([])
        + [originalMode, .write(0xd244, [2])] + card([1], storage: 2) + [originalMode, .read(0x1008, [1], info)] + transfer)
      let session = diagnosticSession(channel)
      _ = try await session.listCameraPhotos()
      let candidates = try await session.scannedPairCandidates()
      let member = try XCTUnwrap(candidates.first)
      do {
        _ = try await session.downloadGalleryCandidate(member) { _ in }
        XCTFail("Invalid candidate response returned success")
      } catch let error as PTPError {
        if case .wrongTransaction = expected, case .wrongTransaction = error {
          // The transaction ID depends on the number of preceding setup exchanges.
        } else {
          XCTAssertEqual(error, expected)
        }
      }
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  private var originalMode: Exchange { .property(0xd226, word(2, 2)) }

  private var galleryStartup: [Exchange] {
    [.read(0x1002, [1]), .property(0xd212, events([(0xdf00, 6)]))] + galleryModeSetup
  }

  private func diagnosticSession(
    _ channel: Replay, camera: WirelessIdentity? = nil,
    trace: WirelessIdentityTrace.Observer? = nil
  ) -> CameraHostedTransferSession {
    CameraHostedTransferSession(
      transport: .init(channel: channel, identityTrace: trace),
      expectedIdentity: camera ?? identity(.xt5), mode: .xApp, clientGUID: Data(repeating: 1, count: 16))
  }
  #endif

  func testAutoSaveRejectsTruncatedOrDifferentPeerBeforeInventory() async throws {
    for serial in ["", "other"] {
      let channel = Replay(start(.xe3, "1.32", serial: serial) + [.read(0x1003)])
      let session = autoSaveSession(channel)
      await expect(.peerMismatch) { _ = try await session.open() }
      try await session.close()
      let operations = await channel.operations
      XCTAssertEqual(operations, [0x1002, 0x1001, 0x1003])
    }
  }

  func testAutoSaveKeepsOriginalsGatedAndEnumeratesSyntheticPairWithoutMarkers() async throws {
    let jpegInfo = object("DSCF0001.JPG", format: 0x3801, bytes: 3)
    let rafInfo = object("DSCF0001.RAF", format: 0xb103, bytes: 5)
    let channel = Replay(start(.xe3, "1.32") + autoSaveSetup(count: 2) + beginLegacyLengths + [
      .read(0x1008, [1], jpegInfo), .read(0x1008, [2], rafInfo),
    ] + endLegacyLengths + [.read(0x1003)])
    let session = autoSaveSession(channel)
    _ = try await session.open()
    let stream = try await session.enumerate()
    var iterator = stream.makeAsyncIterator()
    let batch = try await iterator.next()
    let files = try XCTUnwrap(batch).objects
    XCTAssertEqual(files.map(\.format), [.jpeg, .raf])
    XCTAssertEqual(files.map(\.byteLength), [3, 5])
    let reported = try await session.capabilities()
    XCTAssertEqual(reported.mode, .autoSave)
    XCTAssertFalse(reported.originalSizeVerified)
    XCTAssertEqual(reported.rawExposure, .available)
    await expect(.originalSizeUnavailable) {
      try await session.download(files[1]) { _ in XCTFail("Unverified AutoSave bytes reached the sink") }
    }
    try await session.close()
    let leftover = await channel.remaining
    XCTAssertEqual(leftover, 0)
  }

  func testCancellationAfterLengthReportingAcknowledgementRestoresOnOpenSocket() async throws {
    let channel = Replay(start(.xe3, "1.32") + autoSaveSetup(count: 1)
      + beginLegacyLengths + endLegacyLengths + [.read(0x1003)])
    let session = try XCTUnwrap(autoSaveSession(channel) as? CameraHostedTransferSession)
    let transport = await session.transport
    _ = try await session.open()
    let stream = try await session.enumerate()
    let (held, acknowledged) = AsyncStream<Void>.makeStream()
    await channel.holdNextD227EnableReply(acknowledged)
    let scan = Task {
      var iterator = stream.makeAsyncIterator()
      return try await iterator.next()
    }
    var replies = held.makeAsyncIterator()
    _ = await replies.next()

    let (occupancy, entered) = AsyncStream<Void>.makeStream()
    let resumeSession = DispatchSemaphore(value: 0)
    let blocker = Task { await occupySession(session, entered: entered, resume: resumeSession) }
    var busy = occupancy.makeAsyncIterator()
    _ = await busy.next()
    await channel.resumeD227EnableReply()
    // The command transport finishing while the session executor is occupied
    // fixes the cancellation point after ACK and before session bookkeeping.
    var consumedReply = false
    for _ in 0..<200 {
      do {
        _ = try await transport.initialize(Data())
        XCTFail("The transport was unexpectedly initialized a second time")
        break
      } catch PTPError.busy {
        try await Task.sleep(for: .milliseconds(5))
      } catch PTPError.invalidParameters {
        consumedReply = true
        break
      }
    }
    XCTAssertTrue(consumedReply)
    scan.cancel()
    resumeSession.signal()
    await blocker.value
    do {
      _ = try await scan.value
      XCTFail("The cancelled scan returned inventory")
    } catch is CancellationError {}
    try await session.close()
    let outstanding = await channel.remaining
    XCTAssertEqual(outstanding, 0)
    let operations = await channel.operations
    XCTAssertEqual(operations.suffix(3), [0x1015, 0x1016, 0x1003])
  }

  func testAutoSaveRejectsUnknownFirmwareBeforeModeSetup() async throws {
    for firmware in ["1.31", "1.33", ""] {
      let channel = Replay(start(.xe3, firmware) + [.read(0x1003)])
      let session = autoSaveSession(channel)
      _ = try await session.open()
      await expect(.unsupportedFirmware) { _ = try await session.enumerate() }
      try await session.close()
      let leftover = await channel.remaining
      XCTAssertEqual(leftover, 0)
    }
  }

  #if DEBUG
  func testAutoSaveDiagnosticStreamsFreshBoundedCandidatesWithoutMarkers() async throws {
    let jpeg = object("DSCF0001.JPG", format: 0x3801, bytes: 3)
    let raf = object("DSCF0001.RAF", format: 0xb103, bytes: 5)
    let channel = Replay(start(.xe3, "1.32") + autoSaveSetup(count: 2)
      + beginLegacyLengths + [.read(0x1008, [1], jpeg), .read(0x1008, [2], raf)] + endLegacyLengths
      + beginLegacyLengths + [.read(0x1008, [1], jpeg), .read(0x101b, [1, 0, 3], Data([1, 2, 3]))]
      + endLegacyLengths
      + beginLegacyLengths + [.read(0x1008, [2], raf), .read(0x101b, [2, 0, 5], Data([1, 2, 3, 4, 5]))]
      + endLegacyLengths + [.read(0x1003)])
    let session = autoSaveSession(channel)
    _ = try await session.open()
    let stream = try await session.enumerate()
    var iterator = stream.makeAsyncIterator()
    let batch = try await iterator.next()
    let files = try XCTUnwrap(batch).objects
    let diagnostic = try XCTUnwrap(session as? any WirelessDiagnosticCandidateSession)
    for (object, expected) in zip(files, [Data([1, 2, 3]), Data([1, 2, 3, 4, 5])]) {
      let output = Bytes()
      try await diagnostic.downloadDiagnosticCandidate(object) { await output.append($0) }
      let bytes = await output.value
      XCTAssertEqual(bytes, expected)
    }
    try await session.close()
    let leftover = await channel.remaining
    XCTAssertEqual(leftover, 0)
  }
  #endif

  private func autoSaveSetup(count: UInt32) -> [Exchange] {
    [.property(0xd212, events([(0xdf00, 3), (0xd222, count)])),
     .property(0xdf24, word(.max)), .write(0xdf01, [3, 0]), .property(0xd212, events()),
     .property(0xdf23, word(0x20001)), .write(0xdf23, [1, 0, 2, 0])]
  }

  private var beginLegacyLengths: [Exchange] {
    [.property(0xd212, events()), .write(0xd227, [1, 0])]
  }

  private var endLegacyLengths: [Exchange] {
    [.property(0xd212, events()), .write(0xd227, [0, 0])]
  }

  private func autoSaveSession(_ channel: Replay) -> any WirelessTransferSession {
    AutoSaveTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: autoSaveIdentity(),
      clientGUID: Data(repeating: 1, count: 16))
  }

  private func autoSaveIdentity() -> WirelessIdentity {
    let key = Data(SHA256.hash(data: Data("FujiStudio:PTP-DeviceInfo:X-E3:private".utf8)))
    return .init(
      cameraID: WirelessCameraID(), model: .xe3, firmware: "1.32", protocolPeerKey: .init(bytes: key))
  }

  func testXAppEnumeratesBothSlotsAndRefetchesInOriginalModeBeforeStreaming() async throws {
    let handle: UInt32 = 44
    let info = object("DSCF0044.RAF", format: 0xb103, bytes: 5)
    let commands = start(.xt5, "4.31") + xappSetup + card([handle])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [handle], info),
         .read(0x1008, [handle], info), .read(0x100a, [handle], Data([0xff, 0xd8])),
         .write(0xd244, [2])] + card([], storage: 2)
      + [.write(0xd244, [1])] + card([handle])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [handle], info),
         .read(0x101b, [handle, 0, 3], Data([1, 2, 3])),
         .read(0x101b, [handle, 3, 2], Data([4, 5])),
         .read(0x1003)]
    let channel = Replay(commands)
    let camera = WirelessIdentity(cameraID: .init(), model: .xt5, firmware: "04.31")
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel, maximumPartialObjectBytes: 3),
      expectedIdentity: camera, clientGUID: Data(repeating: 1, count: 16))
    let peer = try await session.open()
    XCTAssertEqual(peer.cameraID, camera.cameraID)
    XCTAssertEqual(peer.model, camera.model)
    XCTAssertEqual(peer.firmware, "4.31")
    XCTAssertNotNil(peer.protocolPeerKey)

    let inventory = try await session.enumerate()
    var iterator = inventory.makeAsyncIterator()
    let firstBatch = try await iterator.next()
    let file = try XCTUnwrap(firstBatch?.objects.first)
    XCTAssertEqual(firstBatch?.storageChanges, [1: .complete, 2: .pending])
    XCTAssertEqual(file.storageID, 1)
    XCTAssertEqual(file.filename, "DSCF0044.RAF")
    XCTAssertEqual(file.format, .raf)
    XCTAssertEqual(file.byteLength, 5)
    XCTAssertEqual(file.dimensions?.width, 7728)
    XCTAssertEqual(file.captureDate, "20261114T173001")
    XCTAssertEqual(file.orientation, 6)
    XCTAssertNil(file.directory)
    let thumbnail = try await session.thumbnail(file)
    XCTAssertEqual(thumbnail, Data([0xff, 0xd8]))

    var completions: [UInt32: WirelessStorageInventory.Completeness] = [:]
    for (id, status) in try XCTUnwrap(firstBatch).storageChanges { completions[id] = status }
    while let batch = try await iterator.next() {
      completions.merge(batch.storageChanges) { _, new in new }
    }
    XCTAssertEqual(completions, [1: .complete, 2: .complete])
    let capabilities = try await session.capabilities()
    XCTAssertEqual(capabilities.rawExposure, .available)
    XCTAssertEqual(capabilities.storageIDs, [1, 2])

    let output = Bytes()
    try await session.download(file) { await output.append($0) }
    let downloaded = await output.value
    XCTAssertEqual(downloaded, Data([1, 2, 3, 4, 5]))
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testVerifiedXAppGalleryStreamsBothOriginalsAcrossShortReadsAndRestoresMode() async throws {
    let raf = object("DSCF0044.RAF", format: 0xb103, bytes: 5)
    let jpeg = object("DSCF0044.JPG", format: 0x3801, bytes: 4)
    let unavailable: [Exchange] = [.property(0xd244, Data([1])), .rejection(0x9054, [0x10000001], 0x2013)]
    let originals: [Exchange] = [
      .property(0xd226, word(0, 2)), .write(0xd226, [2, 0]), .property(0xd226, word(2, 2)),
      .read(0x1008, [44], raf), .read(0x1008, [45], jpeg),
    ]
    let downloads: [Exchange] = [
      .property(0xd226, word(2, 2)), .read(0x1008, [44], raf),
      .read(0x101b, [44, 0, 3], Data([1, 2])), .read(0x101b, [44, 2, 3], Data([3, 4, 5])),
      .property(0xd226, word(2, 2)), .read(0x1008, [45], jpeg),
      .read(0x101b, [45, 0, 3], Data([6, 7, 8])), .read(0x101b, [45, 3, 1], Data([9])),
      .property(0xd226, word(2, 2)), .read(0x1008, [44], raf),
      .read(0x101b, [44, 1, 3], Data([2])), .read(0x101b, [44, 2, 2], Data([3, 4])),
      .write(0xd226, [0, 0]), .read(0x1003),
    ]
    let commands = [.read(0x1002, [1]), .property(0xd212, events([(0xdf00, 6)]))] + galleryModeSetup
      + unavailable + [.write(0xd244, [2])] + card([44, 45], storage: 2) + originals + downloads
    let channel = Replay(commands, initializationName: "X-T5")
    let selected = identity(.xt5)
    let session = XAppTransferAdapter.makeSessionOnCameraNetwork(
      transport: .init(channel: channel, maximumPartialObjectBytes: 3), expectedIdentity: selected,
      clientGUID: Data(repeating: 1, count: 16))

    let peer = try await session.open()
    XCTAssertEqual(peer.cameraID, selected.cameraID)
    XCTAssertNil(peer.protocolPeerKey)
    XCTAssertTrue(peer.firmwareFromBluetooth)
    var objects: [WirelessObjectDescriptor] = []
    for try await batch in try await session.enumerate() { objects += batch.objects }
    XCTAssertEqual(objects.map(\.format), [.raf, .jpeg])
    let capabilities = try await session.capabilities()
    XCTAssertTrue(capabilities.originalSizeVerified)
    XCTAssertEqual(capabilities.rawExposure, .available)

    let received = Mutex(Data())
    for object in objects {
      try await session.download(object) { chunk in received.withLock { $0.append(chunk) } }
    }
    XCTAssertEqual(received.withLock { $0 }, Data(1...9))
    let sampling = try XCTUnwrap(session as? any WirelessOriginalSampling)
    let middle = try await sampling.originalSample(objects[0], offset: 1, count: 3)
    XCTAssertEqual(middle, Data([2, 3, 4]))
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testVerifiedXAppGalleryRejectsDifferentCameraNameBeforeOpeningPTP() async throws {
    let channel = Replay([], initializationName: "X-E3")
    let session = XAppTransferAdapter.makeSessionOnCameraNetwork(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5), clientGUID: Data(repeating: 1, count: 16))
    await expect(.peerMismatch) { _ = try await session.open() }
    try await session.close()
    let operations = await channel.operations
    XCTAssertTrue(operations.isEmpty)
  }

  func testPhoneGalleryAvoidsCaptureAndReportsDeclaredRAWUnavailability() async throws {
    let (session, channel) = try await phoneSession(
      placeholder: 100_000, accurate: 3, commands: [.read(0x1003)])
    let jpegFile = try await firstFile(session)
    XCTAssertEqual(jpegFile.byteLength, 3)
    let sizeControls = await channel.sizeControls
    XCTAssertEqual(sizeControls, [1, 0])
    let capabilities = try await session.capabilities()
    XCTAssertEqual(capabilities.rawExposure, .unavailable)
    XCTAssertFalse(capabilities.originalSizeVerified)
    XCTAssertEqual(jpegFile.format, .jpeg)
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testPhoneCorrectLengthDoesNotPermitProductionDownload() async throws {
    let (session, channel) = try await phoneSession(
      placeholder: 3, accurate: 3, commands: [.read(0x1003)],
      optionalReads: [
        .read(0x1008, [1], object("DSCF0001.JPG", format: 0x3801, bytes: 3)),
        .read(0x101b, [1, 0, 3], Data([1, 2, 3])),
      ])
    let jpeg = try await firstFile(session)
    await expect(.originalSizeUnavailable) {
      try await session.download(jpeg) { _ in XCTFail("Unverified phone representation reached the sink") }
    }
    let capabilities = try await session.capabilities()
    XCTAssertFalse(capabilities.originalSizeVerified)
    let operations = await channel.operations
    XCTAssertFalse(operations.contains(0x101b))
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  #if DEBUG
  func testPhoneDiagnosticCandidateUsesFreshAccurateLengthAndRestoresReporting() async throws {
    let (session, channel) = try await phoneSession(
      placeholder: 100_000, accurate: 3,
      commands: [.read(0x1008, [1]), .read(0x101b, [1, 0, 3], Data([1, 2, 3])), .read(0x1003)])
    let jpeg = try await firstFile(session)
    let diagnostic = try XCTUnwrap(session as? any WirelessDiagnosticCandidateSession)
    let output = Bytes()
    try await diagnostic.downloadDiagnosticCandidate(jpeg) { await output.append($0) }
    let bytes = await output.value
    XCTAssertEqual(bytes, Data([1, 2, 3]))
    let sizeControls = await channel.sizeControls
    XCTAssertEqual(sizeControls, [1, 0, 1, 0])
    let capability = try await session.capabilities()
    XCTAssertFalse(capability.originalSizeVerified)
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testPhoneDiagnosticRejectsObjectChangeAndRestoresReporting() async throws {
    let (session, channel) = try await phoneSession(
      placeholder: 100_000, accurate: 3, commands: [.read(0x1008, [1]), .read(0x1003)],
      fresh: 4)
    let jpeg = try await firstFile(session)
    let diagnostic = try XCTUnwrap(session as? any WirelessDiagnosticCandidateSession)
    await expect(.objectChanged) {
      try await diagnostic.downloadDiagnosticCandidate(jpeg) { _ in XCTFail("Changed bytes reached the sink") }
    }
    let controls = await channel.sizeControls
    XCTAssertEqual(controls, [1, 0, 1, 0])
    let operations = await channel.operations
    XCTAssertFalse(operations.contains(0x101b))
    try await session.close()
  }
  #endif

  private func phoneSession(
    placeholder: UInt32, accurate: UInt32, commands: [Exchange],
    fresh: UInt32? = nil, optionalReads: [Exchange] = []
  ) async throws -> (any WirelessTransferSession, Replay) {
    let initial = start(.xe3, "1.32", formats: [0x3801]) + phoneSetup(count: 1)
    let channel = Replay(
      initial + [.read(0x1008, [1])] + commands,
      optionalReads: optionalReads, phoneObjectInformation: .init(
        placeholder: object("DSCF0001.JPG", format: 0x3801, bytes: placeholder),
        accurate: object("DSCF0001.JPG", format: 0x3801, bytes: accurate),
        fresh: fresh.map { object("DSCF0001.JPG", format: 0x3801, bytes: $0) }))
    let session = PhoneTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xe3),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    return (session, channel)
  }

  private func firstFile(_ session: any WirelessTransferSession) async throws -> WirelessObjectDescriptor {
    let stream = try await session.enumerate()
    var iterator = stream.makeAsyncIterator()
    let batch = try await iterator.next()
    return try XCTUnwrap(batch?.objects.first)
  }

  func testFirmwareMismatchPermitsIdentityReadsAndBlocksEveryObjectOperation() async throws {
    for firmware in ["4.29", "4.31.0", ""] {
      let channel = Replay(start(.xt5, firmware) + [.read(0x1003)])
      let session = XAppTransferAdapter.makeSession(
        transport: .init(channel: channel), expectedIdentity: identity(.xt5),
        clientGUID: Data(repeating: 1, count: 16))
      let peer = try await session.open()
      XCTAssertEqual(peer.firmware, firmware.isEmpty ? nil : firmware)
      let object = WirelessObjectDescriptor(
        cameraID: peer.cameraID, sessionID: UUID(), storageID: 1, handle: 44,
        filename: "DSCF0044.RAF", format: .raf, byteLength: 5)
      await expect(.unsupportedFirmware) { _ = try await session.capabilities() }
      await expect(.unsupportedFirmware) { _ = try await session.enumerate() }
      await expect(.unsupportedFirmware) { _ = try await session.thumbnail(object) }
      await expect(.unsupportedFirmware) {
        try await session.download(object) { _ in XCTFail("Unadmitted bytes reached the sink") }
      }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testUnknownSetupVersionShapeFailsBeforeFirstWrite() async throws {
    let channel = Replay(start(.xt5, "4.32") + [.property(0xdf24, Data([3, 0, 0])), .read(0x1003)])
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    await expect(.malformedData) { _ = try await session.enumerate() }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testChangedOriginalDescriptorPreventsEveryFullByteCommand() async throws {
    let commands = start(.xt5, "4.32") + xappSetup + card([44])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [44], object("DSCF0044.RAF", format: 0xb103, bytes: 5)),
         .property(0xd226, word(2, 2)), .read(0x1008, [44], object("DSCF0044.RAF", format: 0xb103, bytes: 6)),
         .read(0x1003)]
    let channel = Replay(commands)
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    let stream = try await session.enumerate()
    var iterator = stream.makeAsyncIterator()
    let firstBatch = try await iterator.next()
    let file = try XCTUnwrap(firstBatch?.objects.first)
    await expect(.objectChanged) {
      try await session.download(file) { _ in XCTFail("Changed object reached the sink") }
    }
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
  }

  func testMissingSlotDoesNotBecomeACompleteEmptyCard() async throws {
    let channel = Replay(start(.xt5, "4.32") + xappSetup + [
      .property(0xd244, Data([1])), .rejection(0x9054, [0x10000001], 0x2013),
      .write(0xd244, [2]),
    ] + card([], storage: 2) + [.read(0x1003)])
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    let stream = try await session.enumerate()
    var completions: [UInt32: WirelessStorageInventory.Completeness] = [:]
    for try await batch in stream { completions.merge(batch.storageChanges) { _, new in new } }
    XCTAssertEqual(completions, [1: .unavailable, 2: .complete])
    try await session.close()
  }

  func testChangedDescriptorPreventsThumbnailRead() async throws {
    let first = object("DSCF0044.RAF", format: 0xb103, bytes: 5)
    let replacement = object("DSCF0045.RAF", format: 0xb103, bytes: 5)
    let channel = Replay(start(.xt5, "4.32") + xappSetup + card([44])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [44], first),
         .read(0x1008, [44], replacement), .read(0x1003)],
      optionalReads: [.read(0x100a, [44], Data([0xff, 0xd8]))])
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xt5),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    let file = try await firstFile(session)
    await expect(.objectChanged) { _ = try await session.thumbnail(file) }
    try await session.close()
    let operations = await channel.operations
    XCTAssertFalse(operations.contains(0x100a))
  }

  func testXAppResizedOrUnreadableControlDoesNotPermitOriginalDownload() async throws {
    let handle: UInt32 = 44
    let info = object("DSCF0044.JPG", format: 0x3801, bytes: 5)
    for control in [
      Exchange.property(0xd226, word(0, 2)), .rejection(0x1015, [0xd226], 0x200a),
    ] {
      let commands = start(.xt5, "4.32") + xappSetup + card([handle])
        + [control, .read(0x1008, [handle], info), control, .read(0x1003)]
      let channel = Replay(commands)
      let session = XAppTransferAdapter.makeSession(
        transport: .init(channel: channel), expectedIdentity: identity(.xt5),
        clientGUID: Data(repeating: 1, count: 16))
      _ = try await session.open()
      let stream = try await session.enumerate()
      var iterator = stream.makeAsyncIterator()
      let batch = try await iterator.next()
      let file = try XCTUnwrap(batch?.objects.first)
      let capability = try await session.capabilities()
      XCTAssertFalse(capability.originalSizeVerified)
      await expect(.originalSizeUnavailable) {
        try await session.download(file) { _ in XCTFail("Unverified bytes reached the sink") }
      }
      try await session.close()
      let remaining = await channel.remaining
      XCTAssertEqual(remaining, 0)
    }
  }

  func testConflictingXAppCardObservationsBlockBothCardOrdersAndSplitPairMembers() async throws {
    let raf = object("DSCF0044.RAF", format: 0xb103, bytes: 5)
    let jpeg = object("DSCF0044.JPG", format: 0x3801, bytes: 3)
    for (first, second) in [(UInt32(2), UInt32(0)), (0, 2)] {
      let channel = Replay(start(.xt5, "4.32") + xappSetup + card([44])
        + [.property(0xd226, word(first, 2)), .read(0x1008, [44], raf), .write(0xd244, [2])]
        + card([45], storage: 2)
        + [.property(0xd226, word(second, 2)), .read(0x1008, [45], jpeg), .read(0x1003)],
        optionalReads: [.property(0xd226, word(second, 2))])
      let session = XAppTransferAdapter.makeSession(
        transport: .init(channel: channel), expectedIdentity: identity(.xt5),
        clientGUID: Data(repeating: 1, count: 16))
      _ = try await session.open()
      let stream = try await session.enumerate()
      var files: [WirelessObjectDescriptor] = []
      for try await batch in stream { files += batch.objects }
      XCTAssertEqual(files.map(\.storageID), [1, 2])
      let capabilities = try await session.capabilities()
      XCTAssertFalse(capabilities.originalSizeVerified)
      XCTAssertEqual(capabilities.originalSizeFailure, .inconsistentOriginalSizeObservations)
      let writesBeforeDownload = await channel.operations
      for file in files {
        await expect(.inconsistentOriginalSizeObservations) {
          try await session.download(file) { _ in XCTFail("Conflicting original evidence reached the sink") }
        }
      }
      let writesAfterDownload = await channel.operations
      XCTAssertEqual(writesAfterDownload, writesBeforeDownload)
      try await session.close()
    }
  }

  func testInvalidXAppOriginalRequestDoesNotReadControlOrObject() async throws {
    for (format, bytes, limit) in [(UInt32(0xb981), UInt32(3), UInt32(5)), (0xb103, 0, 5), (0xb103, 3, 0)] {
      let channel = Replay(start(.xt5, "4.32") + xappSetup + card([44])
        + [.property(0xd226, word(2, 2)),
           .read(0x1008, [44], object("DSCF0044.RAF", format: format, bytes: bytes)), .read(0x1003)],
        optionalReads: [.property(0xd226, word(2, 2))])
      let session = XAppTransferAdapter.makeSession(
        transport: .init(channel: channel, maximumPartialObjectBytes: limit),
        expectedIdentity: identity(.xt5), clientGUID: Data(repeating: 1, count: 16))
      _ = try await session.open()
      let file = try await firstFile(session)
      let before = await channel.operations
      await expect(.unsupportedProtocol) {
        try await session.download(file) { _ in XCTFail("Invalid original request reached the sink") }
      }
      let after = await channel.operations
      XCTAssertEqual(after, before)
      try await session.close()
    }
  }

  private func identity(_ model: WirelessCameraModel) -> WirelessIdentity {
    .init(cameraID: WirelessCameraID(), model: model, firmware: model == .xt5 ? "4.32" : "1.32")
  }

  private func expect(_ failure: WirelessFailure, operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("An unsafe operation succeeded")
    } catch { XCTAssertEqual(error as? WirelessFailure, failure) }
  }

  private func start(
    _ model: WirelessCameraModel, _ firmware: String, formats: [UInt16] = [0x3801, 0xb103],
    serial: String = "private"
  ) -> [Exchange] {
    var device = word(100, 2) + word(14) + word(100, 2) + string("") + word(0, 2)
    device += Data(repeating: 0, count: 16)
    device += word(UInt32(formats.count))
    for format in formats { device += word(UInt32(format), 2) }
    device += string("FUJIFILM") + string(model.rawValue) + string(firmware) + string(serial)
    return [.read(0x1002, [1]), .read(0x1001, [], device)]
  }

  private var xappSetup: [Exchange] {
    [.property(0xdf24, word(0x2000c))] + galleryModeSetup
  }

  private var galleryModeSetup: [Exchange] {
    [.write(0xdf01, [20, 0]), .property(0xdf28, word(3)), .write(0xdf28, [3, 0, 0, 0]),
     .property(0xd244, Data([1])), .property(0xd212, events([(0xdf00, 20)]))]
  }

  private func cardSetup(storage: UInt8 = 1, postOpenEvents: Data = Data([0, 0])) -> [Exchange] {
    [.property(0xd244, Data([storage])),
     .read(0x9054, [0x10000001]), .read(0x9055, [0x10000001]), .read(0x9050),
     .property(0xd212, postOpenEvents), .property(0xd22b, word(0))]
  }

  private func card(_ handles: [UInt32], storage: UInt8 = 1, postOpenEvents: Data = Data([0, 0])) -> [Exchange] {
    cardSetup(storage: storage, postOpenEvents: postOpenEvents)
      + cardRefresh([]) + [.galleryJPEGRAWFilter] + cardRefresh(handles)
  }

  private func cardRefresh(_ handles: [UInt32]) -> [Exchange] {
    [.read(0x9053, [0, 30000]), .property(0xd212, events()), .property(0xd620, word(UInt32(handles.count))),
     .property(0xd621, word(UInt32(handles.count)) + handles.reduce(into: Data()) { $0 += word($1) })]
  }

  private func phoneSetup(count: UInt32) -> [Exchange] {
    [.property(0xd212, events([(0xdf00, 6), (0xd222, count)])),
     .property(0xdf24, word(0x20006)), .property(0xdf25, word(4)),
     .write(0xdf01, [5, 0]), .property(0xd212, events()),
     .write(0xdf24, [12, 0, 2, 0]), .write(0xdf00, [6, 0]),
     .property(0xd212, events()), .property(0xd212, events()),
     .write(0xdf01, [11, 0]), .property(0xd212, events()),
     .write(0xdf25, [5, 0, 0, 0]), .property(0xd212, events())]
  }

  private func events(_ entries: [(UInt16, UInt32)] = []) -> Data {
    word(UInt32(entries.count), 2) + entries.reduce(into: Data()) {
      $0 += word(UInt32($1.0), 2) + word($1.1)
    }
  }

  private func object(_ filename: String, format: UInt32, bytes: UInt32) -> Data {
    var info = word(0x00010001) + word(format, 2) + word(0, 2) + word(bytes)
    info += word(0x3801, 2) + word(2) + word(160) + word(120)
    info += word(7728) + word(5152) + Data(repeating: 0, count: 18)
    return info + string(filename) + string("20261114T173001") + string("") + string("Orientation:6")
  }
}

private struct Exchange: Sendable {
  let opcode: UInt16
  let parameters: [UInt32]
  var outbound: Data? = nil
  var response: UInt16 = 0x2001
  var payload: Data = Data()
  var sendsEmptyData = false
  var dataCode: UInt16?
  var responseTransaction: UInt32?
  var omitsResponse = false
  var alternative: [Exchange] = []

  static var galleryJPEGRAWFilter: Self {
    // XApp JPEG+RAW filter transaction 2319 on X-T5 04.31.
    .init(opcode: 0x9051, parameters: [], outbound: Data([
      0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0xd6, 0x11, 0x00,
    ]))
  }

  static var emptyDeviceInfo: Self { .init(opcode: 0x1001, parameters: [], sendsEmptyData: true) }

  static func read(_ opcode: UInt16, _ parameters: [UInt32] = [], _ payload: Data = Data()) -> Self {
    .init(opcode: opcode, parameters: parameters, payload: payload)
  }
  static func property(_ code: UInt32, _ payload: Data) -> Self { .read(0x1015, [code], payload) }
  static func write(_ code: UInt32, _ bytes: [UInt8]) -> Self {
    .init(opcode: 0x1016, parameters: [code], outbound: Data(bytes))
  }
  static func rejection(_ opcode: UInt16, _ parameters: [UInt32], _ code: UInt16) -> Self {
    .init(opcode: opcode, parameters: parameters, response: code)
  }
}

private actor Replay: WirelessByteChannel {
  struct PhoneObjectInformation: Sendable {
    let placeholder: Data
    let accurate: Data
    let fresh: Data?
  }

  private var exchanges: [Exchange]
  private let optionalReads: [Exchange]
  private let phoneObjectInformation: PhoneObjectInformation?
  private let initializationName: String
  private var gallerySlot: UInt8?
  private(set) var galleryModes: [UInt8: UInt8]?
  private var buffer = Data()
  private var initialized = false
  private var transaction: UInt32 = 1
  private var waitingForData = false
  private var waitingForSizeControl = false
  private var d227EnableReply: AsyncStream<Void>.Continuation?
  private var holdD227EnableRead = false
  private var resumeD227Read: CheckedContinuation<Void, Never>?

  func holdNextD227EnableReply(_ reply: AsyncStream<Void>.Continuation) { d227EnableReply = reply }

  func resumeD227EnableReply() {
    resumeD227Read?.resume()
    resumeD227Read = nil
  }
  private var heldReply: (exchange: Exchange, signal: AsyncStream<Void>.Continuation)?
  private var holdNextRead = false
  private var pendingReply: CheckedContinuation<Void, Never>?

  func holdReply(matching exchange: Exchange, _ signal: AsyncStream<Void>.Continuation) {
    heldReply = (exchange, signal)
  }

  private var objectReads = 0
  private(set) var sizeControls: [UInt8] = []
  private(set) var operations: [UInt16] = []
  private(set) var closed = false
  private(set) var initializationRequest: Data?
  var remaining: Int { exchanges.count }

  init(
    _ exchanges: [Exchange], optionalReads: [Exchange] = [],
    phoneObjectInformation: PhoneObjectInformation? = nil, galleryModes: [UInt8: UInt8]? = nil,
    initializationName: String = "Fixture"
  ) {
    self.exchanges = exchanges
    self.optionalReads = optionalReads
    self.phoneObjectInformation = phoneObjectInformation
    self.galleryModes = galleryModes
    self.initializationName = initializationName
  }

  func write(_ data: Data) async throws {
    guard initialized else {
      initialized = true
      initializationRequest = data
      let name = Data(initializationName.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] } + [0, 0])
      buffer = word(UInt32(28 + name.count)) + word(2) + Data(repeating: 0, count: 20) + name
      return
    }
    guard let step = exchanges.first else {
      XCTFail("An unexpected command was written")
      throw WirelessFailure.unsupportedProtocol
    }
    let parameters = step.parameters.reduce(into: Data()) { $0 += word($1) }
    let expectedCommand = frame(1, step.opcode, transaction, parameters)
    if !waitingForData, let alternate = step.alternative.first {
      let alternateParameters = alternate.parameters.reduce(into: Data()) { $0 += word($1) }
      if data == frame(1, alternate.opcode, transaction, alternateParameters) {
        // Refreshing without a filter selection keeps the previous view in this fixture.
        let nextCard = exchanges.dropFirst().firstIndex { $0.parameters == [0xd244] } ?? exchanges.endIndex
        exchanges.replaceSubrange(..<nextCard, with: step.alternative)
        try await write(data)
        return
      }
    }
    if data != expectedCommand, let alternative = optionalReads.first(where: { exchange in
      let parameters = exchange.parameters.reduce(into: Data()) { $0 += word($1) }
      return data == frame(1, exchange.opcode, transaction, parameters)
    }) {
      operations.append(alternative.opcode)
      respond(alternative)
      return
    }
    // Model the documented D227 behavior rather than prescribing reads from one mode.
    if phoneObjectInformation != nil {
      if waitingForSizeControl {
        waitingForSizeControl = false
        guard let value = [UInt8(0), 1].first(where: {
          data == frame(2, 0x1016, transaction, Data([$0, 0]))
        }) else { throw WirelessFailure.malformedData }
        sizeControls.append(value)
        respond(.read(0x1016))
        return
      }
      if data == frame(1, 0x1016, transaction, word(0xd227)) {
        operations.append(0x1016)
        waitingForSizeControl = true
        return
      }
      if data != expectedCommand, data == frame(1, 0x1015, transaction, word(0xd212)) {
        operations.append(0x1015)
        respond(.property(0xd212, Data([0, 0])))
        return
      }
    }
    if waitingForData, let outbound = step.outbound {
      XCTAssertEqual(data, frame(2, step.opcode, transaction, outbound))
    } else {
      let opcode = data.count >= 8 ? UInt16(data[6]) | UInt16(data[7]) << 8 : 0
      operations.append(opcode)
      XCTAssertEqual(data, expectedCommand)
      guard data == expectedCommand else { throw WirelessFailure.unsupportedProtocol }
      if step.outbound != nil {
        waitingForData = true
        return
      }
    }
    waitingForData = false
    exchanges.removeFirst()
    if step.opcode == 0x1008, let phoneObjectInformation {
      let accurate = objectReads == 0
        ? phoneObjectInformation.accurate : phoneObjectInformation.fresh ?? phoneObjectInformation.accurate
      let info = sizeControls.last == 1 ? accurate : phoneObjectInformation.placeholder
      objectReads += 1
      respond(.read(0x1008, step.parameters, info))
      return
    }
    if d227EnableReply != nil, step.parameters == [0xd227], step.outbound == Data([1, 0]) {
      holdD227EnableRead = true
    }
    respond(step)
  }

  private func respond(_ expected: Exchange) {
    var step = expected
    if galleryModes != nil {
      if step.parameters == [0xd244], step.response == 0x2001 {
        gallerySlot = (step.outbound ?? step.payload).first
      }
      if step.parameters == [0xd226], step.response == 0x2001, let gallerySlot {
        if let outbound = step.outbound, let mode = outbound.first {
          galleryModes?[gallerySlot] = mode
        } else if let mode = galleryModes?[gallerySlot] {
          step.payload = word(UInt32(mode), step.payload.count)
        }
      }
    }
    if let heldReply, heldReply.exchange.opcode == step.opcode,
      heldReply.exchange.parameters == step.parameters, heldReply.exchange.outbound == step.outbound {
      holdNextRead = true
    }
    if !step.payload.isEmpty || step.sendsEmptyData {
      buffer += frame(2, step.dataCode ?? step.opcode, transaction, step.payload)
    }
    let count = step.opcode == 0x101b ? word(UInt32(step.payload.count)) : Data()
    if !step.omitsResponse {
      buffer += frame(3, step.response, step.responseTransaction ?? transaction, count)
    }
    transaction += 1
  }

  func read(maximumBytes: Int) async throws -> Data {
    if holdD227EnableRead, let d227EnableReply {
      holdD227EnableRead = false
      self.d227EnableReply = nil
      await withCheckedContinuation { continuation in
        resumeD227Read = continuation
        d227EnableReply.yield()
        d227EnableReply.finish()
      }
    }
    if holdNextRead, let heldReply {
      holdNextRead = false
      self.heldReply = nil
      await withCheckedContinuation { continuation in
        pendingReply = continuation
        heldReply.signal.yield()
        heldReply.signal.finish()
      }
      if closed { throw PTPError.notConnected }
    }
    let result = Data(buffer.prefix(maximumBytes))
    buffer.removeFirst(result.count)
    return result
  }

  func close() async {
    closed = true
    heldReply?.signal.finish()
    pendingReply?.resume()
    pendingReply = nil
  }
}

private actor Bytes {
  private(set) var value = Data()
  func append(_ data: Data) { value += data }
}

private func frame(_ type: UInt16, _ code: UInt16, _ id: UInt32, _ data: Data) -> Data {
  word(UInt32(12 + data.count)) + word(UInt32(type), 2) + word(UInt32(code), 2) + word(id) + data
}

private func word(_ value: UInt32, _ width: Int = 4) -> Data {
  Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

private func string(_ value: String) -> Data {
  guard !value.isEmpty else { return Data([0]) }
  return Data([UInt8(value.utf16.count + 1)])
    + value.utf16.reduce(into: Data()) { $0 += word(UInt32($1), 2) } + Data([0, 0])
}

private func occupySession(
  _ session: isolated CameraHostedTransferSession,
  entered: AsyncStream<Void>.Continuation, resume: DispatchSemaphore
) {
  entered.yield()
  entered.finish()
  XCTAssertEqual(resume.wait(timeout: .now() + 5), .success)
}

