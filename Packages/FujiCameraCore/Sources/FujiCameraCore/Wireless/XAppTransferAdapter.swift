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
  // Sequence based on libfuji 3b9932a and the GFX100 II 2.30 XApp gallery capture.
  func configureXApp() async throws -> [UInt32] {
    let version = try await readScalar(0xdf24)
    guard (0x20007...0x2000c).contains(version) else { throw WirelessFailure.unsupportedProtocol }
    try await setProperty(0xdf01, 20, width: 2)
    let galleryVersion = try await readScalar(0xdf28)
    guard (1...3).contains(galleryVersion) else { throw WirelessFailure.unsupportedProtocol }
    try await setProperty(0xdf28, galleryVersion, width: 4)
    let storage = try await readScalar(0xd244, widths: [1, 2, 4])
    guard storage == 1 || storage == 2 else { throw WirelessFailure.unsupportedProtocol }
    selectedStorage = storage
    return [storage, storage == 1 ? 2 : 1]
  }

  func observesXAppOriginalSize() async throws -> Bool {
    do {
      return try await readScalar(0xd226, widths: [2, 4]) == 2
    } catch PTPError.responseCode(0x200a) {
      return false
    }
  }

  func configureXAppCard(_ storage: UInt32) async throws -> [UInt32]? {
    if selectedStorage != storage {
      try await setProperty(0xd244, storage, width: 1)
      selectedStorage = nil
    }
    let confirmedStorage = try await readScalar(0xd244, widths: [1, 2, 4])
    guard confirmedStorage == storage else { throw WirelessFailure.unavailableStorage }
    selectedStorage = storage
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
    _ = try await execute(0x9053, [0, 30_000])
    let count = try await readScalar(0xd620)
    let payload = try await property(0xd621)
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
