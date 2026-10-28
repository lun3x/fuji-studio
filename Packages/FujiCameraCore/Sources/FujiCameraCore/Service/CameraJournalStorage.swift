import Foundation

public protocol CameraJournalFilePolicy: Sendable {
  func createDirectory(at url: URL) throws
  func write(_ data: Data, to url: URL, exclusive: Bool) throws
}
