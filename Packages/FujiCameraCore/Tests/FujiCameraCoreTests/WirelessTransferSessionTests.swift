import Foundation
import XCTest

@testable import FujiCameraCore

final class WirelessTransferSessionTests: XCTestCase, @unchecked Sendable {
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
    let jpeg = object("DSCF0001.JPG", format: 0x3801, bytes: 3)
    let commands = start(.xe3, "1.32", formats: [0x3801]) + phoneSetup(count: 1)
      + [.read(0x1008, [1], jpeg), .property(0xd212, events()),
         .write(0xd227, [1, 0]), .read(0x1008, [1], jpeg),
         .read(0x101b, [1, 0, 3], Data([1, 2, 3])),
         .property(0xd212, events()), .write(0xd227, [0, 0]), .read(0x1003)]
    let channel = Replay(commands)
    let session = PhoneTransferAdapter.makeSession(
      transport: .init(channel: channel), expectedIdentity: identity(.xe3),
      clientGUID: Data(repeating: 1, count: 16))
    _ = try await session.open()
    let stream = try await session.enumerate()
    var files: [WirelessObjectDescriptor] = []
    for try await batch in stream { files += batch.objects }
    let jpegFile = try XCTUnwrap(files.first)
    let capabilities = try await session.capabilities()
    XCTAssertEqual(capabilities.rawExposure, .unavailable)
    XCTAssertEqual(jpegFile.format, .jpeg)
    let output = Bytes()
    try await session.download(jpegFile) { await output.append($0) }
    let downloaded = await output.value
    XCTAssertEqual(downloaded, Data([1, 2, 3]))
    try await session.close()
    let remaining = await channel.remaining
    XCTAssertEqual(remaining, 0)
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
    _ model: WirelessCameraModel, _ firmware: String, formats: [UInt16] = [0x3801, 0xb103]
  ) -> [Exchange] {
    var device = word(100, 2) + word(14) + word(100, 2) + string("") + word(0, 2)
    device += Data(repeating: 0, count: 16)
    device += word(UInt32(formats.count))
    for format in formats { device += word(UInt32(format), 2) }
    device += string("FUJIFILM") + string(model.rawValue) + string(firmware) + string("private")
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
  private var exchanges: [Exchange]
  private var buffer = Data()
  private var initialized = false
  private var transaction: UInt32 = 1
  private var waitingForData = false
  var remaining: Int { exchanges.count }

  init(_ exchanges: [Exchange]) { self.exchanges = exchanges }

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
    if waitingForData, let outbound = step.outbound {
      XCTAssertEqual(data, frame(2, step.opcode, transaction, outbound))
    } else {
      XCTAssertEqual(data, frame(1, step.opcode, transaction, parameters))
      if step.outbound != nil {
        waitingForData = true
        return
      }
    }
    waitingForData = false
    exchanges.removeFirst()
    if !step.payload.isEmpty { buffer += frame(2, step.opcode, transaction, step.payload) }
    let count = step.opcode == 0x101b ? word(UInt32(step.payload.count)) : Data()
    buffer += frame(3, step.response, transaction, count)
    transaction += 1
  }

  func read(maximumBytes: Int) async throws -> Data {
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
