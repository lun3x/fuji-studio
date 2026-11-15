import CryptoKit
import Foundation
import XCTest

@testable import FujiCameraCore

final class WirelessTransferSessionTests: XCTestCase, @unchecked Sendable {
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
    let key = Data(SHA256.hash(data: Data("FujiStudio:PTP-DeviceInfo:X-E3:private".utf8)))
    return AutoSaveTransferAdapter.makeSession(
      transport: .init(channel: channel),
      expectedIdentity: .init(
        cameraID: WirelessCameraID(), model: .xe3, firmware: "1.32",
        protocolPeerKey: .init(bytes: key)),
      clientGUID: Data(repeating: 1, count: 16))
  }

  func testXAppEnumeratesBothSlotsAndRefetchesInOriginalModeBeforeStreaming() async throws {
    let handle: UInt32 = 44
    let info = object("DSCF0044.RAF", format: 0xb103, bytes: 5)
    let commands = start(.xt5, "4.32") + xappSetup + card([handle])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [handle], info),
         .read(0x1008, [handle], info), .read(0x100a, [handle], Data([0xff, 0xd8])),
         .write(0xd244, [2])] + card([], storage: 2)
      + [.write(0xd244, [1])] + card([handle])
      + [.property(0xd226, word(2, 2)), .read(0x1008, [handle], info),
         .read(0x101b, [handle, 0, 3], Data([1, 2, 3])),
         .read(0x101b, [handle, 3, 2], Data([4, 5])),
         .read(0x1003)]
    let channel = Replay(commands)
    let camera = identity(.xt5)
    let session = XAppTransferAdapter.makeSession(
      transport: .init(channel: channel, maximumPartialObjectBytes: 3),
      expectedIdentity: camera, clientGUID: Data(repeating: 1, count: 16))
    let peer = try await session.open()
    XCTAssertEqual(peer.cameraID, camera.cameraID)
    XCTAssertEqual(peer.model, camera.model)
    XCTAssertEqual(peer.firmware, camera.firmware)
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
    for firmware in ["4.31", "4.33", ""] {
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
    [.property(0xdf24, word(0x2000c)), .write(0xdf01, [20, 0]), .property(0xdf28, word(3)), .write(0xdf28, [3, 0, 0, 0]),
     .property(0xd244, Data([1]))]
  }

  private func card(_ handles: [UInt32], storage: UInt8 = 1) -> [Exchange] {
    [.property(0xd244, Data([storage])),
     .read(0x9054, [0x10000001]), .read(0x9055, [0x10000001]), .read(0x9050),
     .property(0xd212, events()), .property(0xd22b, word(0)),
     .read(0x9053, [0, 30000]), .property(0xd620, word(UInt32(handles.count))),
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
  private var objectReads = 0
  private(set) var sizeControls: [UInt8] = []
  private(set) var operations: [UInt16] = []
  var remaining: Int { exchanges.count }

  init(
    _ exchanges: [Exchange], optionalReads: [Exchange] = [],
    phoneObjectInformation: PhoneObjectInformation? = nil
  ) {
    self.exchanges = exchanges
    self.optionalReads = optionalReads
    self.phoneObjectInformation = phoneObjectInformation
  }

  func write(_ data: Data) async throws {
    guard initialized else {
      initialized = true
      let name = Data("Fixture".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] } + [0, 0])
      buffer = word(UInt32(28 + name.count)) + word(2) + Data(repeating: 0, count: 20) + name
      return
    }
    guard let step = exchanges.first else {
      XCTFail("An unexpected command was written")
      throw WirelessFailure.unsupportedProtocol
    }
    let parameters = step.parameters.reduce(into: Data()) { $0 += word($1) }
    let expectedCommand = frame(1, step.opcode, transaction, parameters)
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

  private func respond(_ step: Exchange) {
    if !step.payload.isEmpty { buffer += frame(2, step.opcode, transaction, step.payload) }
    let count = step.opcode == 0x101b ? word(UInt32(step.payload.count)) : Data()
    buffer += frame(3, step.response, transaction, count)
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
    let result = Data(buffer.prefix(maximumBytes))
    buffer.removeFirst(result.count)
    return result
  }

  func close() async {}
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
