import Foundation

/// Borrowed access expires and drains before its owner releases the whole-operation permit.
/// Public methods expose reads. The importer bridge permits only the declared temporary selector.
public actor CameraOperationIO {
  typealias Action = @Sendable (UInt16, [UInt32], Data?) async throws -> PTPReply
  private let action: Action
  private let wait: @Sendable (Duration) async throws -> Void
  private let temporarySelector: TemporaryBankSelector?
  private var active = true
  private var pending = 0
  private var drain: [CheckedContinuation<Void, Never>] = []
  private var backupAttempted = false
  init(
    temporarySelector: TemporaryBankSelector?,
    settle: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    action: @escaping Action
  ) {
    self.temporarySelector = temporarySelector
    self.action = action
    self.wait = settle
  }
  func settle(_ duration: Duration) async throws {
    try validateActive()
    try await wait(duration)
    try validateActive()
  }
  public func readDeviceInfo() async throws -> FujiDeviceInfo {
    try PTPDatasets.deviceInfo(await read(0x1001, []))
  }
  public func readProperty(_ code: UInt16) async throws -> Data {
    try await read(0x1015, [UInt32(code)])
  }
  public func readPropertyDescriptor(_ code: UInt16) async throws -> Data {
    try await read(0x1014, [UInt32(code)])
  }
  public func readSettingsBackup() async throws -> Data {
    guard !backupAttempted else { throw CameraServiceError.unsupportedContext }
    backupAttempted = true
    let info = try FujiConversionCodec.objectInfo(await read(0x1008, [0]))
    guard info.format == 0x5000, info.byteCount > 0, info.byteCount <= 1_048_576 else {
      throw CameraServiceError.unsupportedContext
    }
    let bytes = try await read(0x1009, [0])
    guard bytes.count == info.byteCount else { throw CameraServiceError.invalidOutput }
    return bytes
  }
  public func validateActive() throws { guard active else { throw CameraServiceError.cancelled } }
  private func read(_ opcode: UInt16, _ parameters: [UInt32]) async throws -> Data {
    try await restricted(opcode, parameters, nil).data
  }
  func finish() async {
    active = false
    if pending > 0 { await withCheckedContinuation { drain.append($0) } }
  }
  func temporarySelectorTransport() throws -> any PTPTransport {
    guard active, temporarySelector != nil else { throw CameraServiceError.unsupportedContext }
    return ImportTransport { command, data in
      try await self.restricted(command.opcode, command.parameters, data)
    }
  }

  private func restricted(_ opcode: UInt16, _ parameters: [UInt32], _ data: Data?) async throws
    -> PTPReply
  {
    try validateActive()
    let readOnly =
      data == nil
      && ((opcode == 0x1001 && parameters.isEmpty)
        || ([UInt16(0x1014), 0x1015].contains(opcode) && parameters.count == 1
          && parameters[0] <= UInt16.max)
        || ([UInt16(0x1008), 0x1009].contains(opcode) && parameters == [0]))
    let selector: Bool
    if let declaration = temporarySelector, let data, data.count == 2 {
      let value = UInt16(data[0]) | UInt16(data[1]) << 8
      selector =
        opcode == 0x1016 && parameters == [UInt32(declaration.property)]
        && declaration.slots.contains(value)
    } else {
      selector = false
    }
    guard readOnly || selector else { throw CameraServiceError.unsupportedContext }
    pending += 1
    defer {
      pending -= 1
      if pending == 0 {
        drain.forEach { $0.resume() }
        drain = []
      }
    }
    let reply = try await action(opcode, parameters, data)
    try validateActive()
    return reply
  }
}
private struct ImportTransport: PTPTransport {
  let action: @Sendable (PTPCommand, Data?) async throws -> PTPReply
  func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
    try await action(command, data)
  }
}
