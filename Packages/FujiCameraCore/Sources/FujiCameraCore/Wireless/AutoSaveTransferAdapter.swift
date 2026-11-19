import Foundation

public enum AutoSaveTransferAdapter {
  static let thumbnailPrefixBytes: UInt32 = 16 * 1024
  static let thumbnailTailBytes: UInt32 = 32

  /// Pass the independently verified DeviceInfo binding for the selected camera.
  public static func makeSession(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data
  ) -> any WirelessTransferSession {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .autoSave, clientGUID: clientGUID)
  }

  #if targetEnvironment(simulator)
  /// The Simulator uses the explicitly registered camera name and captured X-E3 profile.
  public static func makeSimulatorSession(
    transport: WirelessPTPTransport, cameraID: WirelessCameraID, cameraName: String, localIPv4Bytes: Data?
  ) throws -> any WirelessTransferSession {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: .init(cameraID: cameraID, model: .xe3, firmware: nil),
      mode: .autoSave, clientGUID: try FujiWirelessFrameDecoder.xAppClientGUID(localIPv4Bytes: localIPv4Bytes),
      clientName: cameraName, capturedAutoSaveName: cameraName)
  }

  public static func isSimulatorSession(_ session: any WirelessTransferSession) -> Bool {
    (session as? CameraHostedTransferSession)?.usesCapturedAutoSave == true
  }
  #endif
}

extension CameraHostedTransferSession {
  // libfuji 3b9932a lib/fuji.c AutoSave branch: PC AutoSave state, client mode
  // from remote version, echo DF23, and consecutive handles on a single card.
  // The other legacy version reads are unused by this branch.
  func configureAutoSave() async throws -> [UInt32] {
    let clock = ContinuousClock()
    let deadline = clock.now + WirelessLimits.transactionInactivity
    var state: UInt32?
    repeat {
      state = try await readEvents()[0xdf00]
      if state == 0 || state == nil {
        guard clock.now < deadline else { throw WirelessFailure.timeout(.transactionInactivity) }
        try await Task.sleep(for: .milliseconds(100))
      }
    } while state == 0 || state == nil
    guard state == 3 else { throw WirelessFailure.unsupportedProtocol }

    if usesCapturedAutoSave {
      try await setProperty(0xdf01, 3, width: 2)
    } else {
      let remote = try await readScalar(0xdf24)
      try await setProperty(0xdf01, remote == UInt32.max ? 3 : 5, width: 2)
      _ = try await readEvents()
    }
    let autoSaveVersion = try await readScalar(0xdf23)
    guard autoSaveVersion != 0, autoSaveVersion != UInt32.max else {
      throw WirelessFailure.unsupportedProtocol
    }
    try await setProperty(0xdf23, autoSaveVersion, width: 4)
    guard legacyObjectCount != nil else { throw WirelessFailure.unavailableStorage }
    if usesCapturedAutoSave {
      try await setProperty(0xd227, 1, width: 2) { legacyAccurateLengthsEnabled = true }
    }
    selectedStorage = 0
    return [0]
  }

  func prepareCapturedAutoSaveReads() async throws {
    guard !autoSaveReadsPrepared else { return }
    // The official receiver drains the initial events before setting progress.
    for _ in 0..<8 {
      try await Task.sleep(for: .milliseconds(200))
      try await readEvents()
    }
    try await setAutoSaveProgress()
    autoSaveReadsPrepared = true
  }

  func setAutoSaveProgress() async throws {
    guard let total = legacyObjectCount else { throw WirelessFailure.unavailableStorage }
    let value = "\(autoSaveDownloadedHandles.count)/\(total)"
    var data = Data([UInt8(value.utf16.count + 1)])
    data.append(contentsOf: value.utf8.flatMap { [$0, 0] })
    data.append(contentsOf: [0, 0])
    _ = try await execute(0x1016, [0xd228], data: data)
  }

  func capturedAutoSaveThumbnail(_ object: WirelessObjectDescriptor) async throws -> Data {
    let prefixBytes = AutoSaveTransferAdapter.thumbnailPrefixBytes
    let tailBytes = AutoSaveTransferAdapter.thumbnailTailBytes
    let length = try originalLength(object)
    guard object.format == .raf, length > prefixBytes else { return Data() }
    let prefix = try await readAutoSaveRange(object.handle, offset: 0, count: prefixBytes)
    // Reading through EOF releases this object before the next handle is opened.
    _ = try await readAutoSaveRange(object.handle, offset: length - tailBytes, count: tailBytes)
    return RAFMetadataReader().embeddedThumbnail(in: prefix, fileByteCount: Int(length)) ?? Data()
  }

  private func readAutoSaveRange(_ handle: UInt32, offset: UInt32, count: UInt32) async throws -> Data {
    let reply = try await execute(0x101b, [handle, offset, count])
    guard reply.data.count == Int(count), reply.parameters == [count] else {
      throw WirelessFailure.malformedData
    }
    return reply.data
  }
}
