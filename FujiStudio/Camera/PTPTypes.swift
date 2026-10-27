import Foundation

struct PTPCommand: Sendable, Equatable {
    let opcode: UInt16
    let parameters: [UInt32]
    /// Logical echo/caller identity for ImageCaptureCore; direct transports use this on the wire.
    let transactionID: UInt32
}

/// Direct transports independently check a wire ID. ImageCaptureCore correlates its own wire
/// transaction and returns the original logical command through its context-bound callback.
enum PTPCorrelation: Sendable, Equatable {
    case directWireTransaction
    case imageCaptureCoreCallback(echoedCommand: PTPCommand)
}

/// Payload is the data phase, without a USB data-container header. Raw response is never rewritten.
struct PTPReply: Sendable, Equatable {
    let opcode: UInt16
    let parameters: [UInt32]
    let logicalTransactionID: UInt32
    /// Observed response field; ImageCaptureCore owns its wire association.
    let wireTransactionID: UInt32
    let correlation: PTPCorrelation
    let responseCode: UInt16
    let rawResponse: Data
    let data: Data
}

enum PTPError: Error, Sendable, Equatable {
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
