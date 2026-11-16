import Foundation

public enum XAppTransferAdapter {
  public static func makeSession(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data,
    clientName: String? = nil
  ) -> any WirelessTransferSession {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .xApp,
      clientGUID: clientGUID, clientName: clientName)
  }
}

extension CameraHostedTransferSession {
  // The production path retains its remote-version requirement before gallery setup.
  func configureXApp() async throws -> [UInt32] {
    try await requireXAppRemoteVersion()
    return try await configureXAppGalleryMode()
  }

  func configureXAppGalleryMode() async throws -> [UInt32] {
    try await setProperty(0xdf01, 20, width: 2)
    let version = try await readScalar(0xdf28)
    guard let galleryVersion = WirelessIdentityTrace.GalleryVersion(rawValue: version) else {
      transport.observeIdentity(.init(.galleryVersionValidation, .failed, failure: .unsupported))
      throw WirelessFailure.unsupportedProtocol
    }
    try await setProperty(0xdf28, galleryVersion.rawValue, width: 4)
    transport.observeIdentity(.init(.galleryVersionValidation, .completed, galleryVersion: galleryVersion))
    let storage = try await readScalar(0xd244, widths: [1, 2, 4])
    guard storage == 1 || storage == 2 else {
      transport.observeIdentity(.init(.galleryStorageConfirmation, .failed, failure: .unsupported))
      throw WirelessFailure.unsupportedProtocol
    }
    _ = try await readEvents()
    xAppInitialStorage = storage
    return [storage, storage == 1 ? 2 : 1]
  }

  private func requireXAppRemoteVersion() async throws {
    let version = try await readScalar(0xdf24)
    guard (0x20007...0x2000c).contains(version) else { throw WirelessFailure.unsupportedProtocol }
  }

  func observesXAppOriginalSize() async throws -> Bool {
    do {
      return try await readScalar(0xd226, widths: [2, 4]) == 2
    } catch PTPError.responseCode(0x200a) {
      return false
    }
  }

  func configureXAppCard(_ storage: UInt32) async throws -> [UInt32]? {
    let needsSelection = (selectedStorage ?? xAppInitialStorage) != storage
    xAppInitialStorage = nil
    if needsSelection {
      #if DEBUG
      try await restoreGalleryOriginalMode(canRestore: true, whileClosing: false)
      galleryOriginalModePrepared = false
      #endif
      selectedStorage = nil
      try await setProperty(0xd244, storage, width: 1)
    }
    // A retry must repeat setup after a failed confirmation, filter, or refresh.
    selectedStorage = nil
    let confirmedStorage = try await readScalar(0xd244, widths: [1, 2, 4])
    guard confirmedStorage == storage else {
      transport.observeIdentity(.init(.galleryStorageConfirmation, .failed, failure: .unavailableStorage))
      throw WirelessFailure.unavailableStorage
    }
    transport.observeIdentity(.init(.galleryStorageConfirmation, .completed))
    do {
      _ = try await execute(0x9054, [0x10000001])
    } catch PTPError.responseCode(0x2013) {
      // The reference attributes StoreNotAvailable to an inaccessible slot.
      return nil
    }
    _ = try await execute(0x9055, [0x10000001])
    _ = try await execute(0x9050)
    _ = try await readEvents()
    _ = try await property(0xd22b)
    // The cold X-T5 gallery inventories the card before making any filter writes.
    _ = try await refreshXAppInventory(slot: storage, stage: .galleryInitialInventory)
    // XApp on X-T5 04.31 selects JPEG+RAW with one 8-byte D604 record set to 0x0011.
    let jpegRAWFilter = Data([
      0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04, 0xd6, 0x11, 0x00,
    ])
    _ = try await execute(0x9051, data: jpegRAWFilter)
    let handles = try await refreshXAppInventory(slot: storage, stage: .galleryFilteredInventory)
    selectedStorage = storage
    return handles
  }

  private func refreshXAppInventory(
    slot: UInt32, stage: WirelessIdentityTrace.Stage
  ) async throws -> [UInt32] {
    _ = try await execute(0x9053, [0, 30_000])
    _ = try await readEvents()
    let count = try await readScalar(0xd620)
    let payload = try await property(0xd621)
    transport.observeIdentity(.init(.galleryHandleValidation, .waiting))
    do {
      let handles = try Self.validateXAppHandles(payload, count: count)
      transport.observeIdentity(.init(.galleryHandleValidation, .completed))
      transport.observeIdentity(.init(stage, .completed, gallerySlot: slot, galleryHandleCount: count))
      return handles
    } catch {
      transport.observeIdentity(.init(.galleryHandleValidation, .failed, failure: .init(error)))
      throw error
    }
  }

  private static func validateXAppHandles(_ payload: Data, count: UInt32) throws -> [UInt32] {
    guard count <= WirelessPTPTransport.maximumObjectsPerStorage,
      payload.count == 4 + Int(count) * 4,
      try Self.scalar(Data(payload.prefix(4))) == count
    else { throw WirelessFailure.malformedData }
    var handles: [UInt32] = []
    var known = Set<UInt32>()
    for offset in stride(from: 4, to: payload.count, by: 4) {
      let handle = try Self.scalar(payload.subdata(in: offset..<(offset + 4)))
      guard handle > 0, handle < UInt32.max, known.insert(handle).inserted else {
        throw WirelessFailure.malformedData
      }
      handles.append(handle)
    }
    return handles
  }
}

#if DEBUG
public enum XAppConnectionDiagnosticResult: Sendable, Equatable {
  case identified(WirelessIdentity)
  case respondingWithoutDeviceInfo
}

public protocol XAppConnectionDiagnostic: Sendable {
  func checkConnection() async throws -> XAppConnectionDiagnosticResult
  /// Return only after the native socket has closed.
  func close() async throws
}

extension XAppTransferAdapter {
  public static func makeConnectionDiagnostic(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data,
    clientName: String
  ) -> any XAppConnectionDiagnostic {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .xApp,
      clientGUID: clientGUID, clientName: clientName)
  }
}

extension CameraHostedTransferSession: XAppGalleryDiagnostic {
  // From the pinned libfuji XApp setup and X-T5 trace. This check ends before any gallery writes.
  func checkXAppStartup(validatesRemoteVersion: Bool = true) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.readXAppStartup(validatesRemoteVersion: validatesRemoteVersion) }
      group.addTask {
        try await Task.sleep(for: WirelessLimits.transactionInactivity)
        throw WirelessFailure.timeout(.transactionInactivity)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    try Task.checkCancellation()
  }

  private func readXAppStartup(validatesRemoteVersion: Bool) async throws {
    do {
      while true {
        let state = try await readEvents()[0xdf00]
        if let state, state != 0 {
          guard state == 6 else { throw WirelessFailure.unsupportedProtocol }
          break
        }
        transport.observeIdentity(.init(.xAppAccess, .waiting))
        try await Task.sleep(for: .milliseconds(100))
      }
      transport.observeIdentity(.init(.xAppAccess, .completed))
    } catch {
      transport.observeIdentity(.init(.xAppAccess, .failed, failure: .init(error)))
      throw error
    }
    guard validatesRemoteVersion else { return }
    do {
      try await requireXAppRemoteVersion()
      transport.observeIdentity(.init(.xAppVersionValidation, .completed))
    } catch {
      transport.observeIdentity(.init(.xAppVersionValidation, .failed, failure: .init(error)))
      throw error
    }
  }
}
#endif
