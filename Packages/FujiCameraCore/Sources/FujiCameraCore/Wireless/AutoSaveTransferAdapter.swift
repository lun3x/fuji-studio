import Foundation

public enum AutoSaveTransferAdapter {
  /// Pass the independently verified DeviceInfo binding for the selected camera.
  public static func makeSession(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data
  ) -> any WirelessTransferSession {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .autoSave, clientGUID: clientGUID)
  }
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

    let remote = try await readScalar(0xdf24)
    try await setProperty(0xdf01, remote == UInt32.max ? 3 : 5, width: 2)
    _ = try await readEvents()
    let autoSaveVersion = try await readScalar(0xdf23)
    guard autoSaveVersion != 0, autoSaveVersion != UInt32.max else {
      throw WirelessFailure.unsupportedProtocol
    }
    try await setProperty(0xdf23, autoSaveVersion, width: 4)
    guard legacyObjectCount != nil else { throw WirelessFailure.unavailableStorage }
    selectedStorage = 0
    return [0]
  }
}
