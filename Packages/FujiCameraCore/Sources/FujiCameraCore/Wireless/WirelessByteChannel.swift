import Foundation

/// A single-use, ordered byte stream for the selected camera command socket.
public protocol WirelessByteChannel: Sendable {
  /// Returns at most the requested number of bytes. An empty result indicates EOF.
  func read(maximumBytes: Int) async throws -> Data
  func write(_ data: Data) async throws
  /// Stops I/O, unblocks outstanding operations and waits for native cleanup.
  func close() async
}
