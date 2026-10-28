import Foundation

public struct PTPCommand: Sendable, Equatable {
  public let opcode: UInt16
  public let parameters: [UInt32]
  /// Logical echo/caller identity for ImageCaptureCore; direct transports use this on the wire.
  public let transactionID: UInt32
  public init(opcode: UInt16, parameters: [UInt32], transactionID: UInt32) {
    self.opcode = opcode
    self.parameters = parameters
    self.transactionID = transactionID
  }

}

/// Direct transports independently check a wire ID. ImageCaptureCore correlates its own wire
/// transaction and returns the original logical command through its context-bound callback.
public enum PTPCorrelation: Sendable, Equatable {
  case directWireTransaction
  case imageCaptureCoreCallback(echoedCommand: PTPCommand)
}

/// Payload is the data phase, without a USB data-container header. Raw response is never rewritten.
public struct PTPReply: Sendable, Equatable {
  public let opcode: UInt16
  public let parameters: [UInt32]
  public let logicalTransactionID: UInt32
  /// Observed response field; ImageCaptureCore owns its wire association.
  public let wireTransactionID: UInt32
  public let correlation: PTPCorrelation
  public let responseCode: UInt16
  public let rawResponse: Data
  public let data: Data
  public init(
    opcode: UInt16, parameters: [UInt32], logicalTransactionID: UInt32, wireTransactionID: UInt32,
    correlation: PTPCorrelation, responseCode: UInt16, rawResponse: Data, data: Data
  ) {
    self.opcode = opcode
    self.parameters = parameters
    self.logicalTransactionID = logicalTransactionID
    self.wireTransactionID = wireTransactionID
    self.correlation = correlation
    self.responseCode = responseCode
    self.rawResponse = rawResponse
    self.data = data
  }

}

public enum PTPError: Error, Sendable, Equatable {
  case truncatedContainer
  case oversizedContainer
  case invalidContainerLength
  case unexpectedContainerType(UInt16)
  case callbackCommandMismatch
  case invalidParameters
  case invalidOpcode(UInt16)
  case wrongTransaction(expected: UInt32, actual: UInt32)
  case responseCode(UInt16)
  case payloadTooLarge
  case timeout
  case notConnected
  case busy
  case sessionClosing
  case authorizationDenied
  case wrongMode(String)
  case sessionFailure(String)
}
