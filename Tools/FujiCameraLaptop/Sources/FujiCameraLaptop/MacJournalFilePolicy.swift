import Darwin
import Foundation
import FujiCameraCore

struct MacJournalFilePolicy: CameraJournalFilePolicy {
  func createFreshDirectory(at url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else {
      throw errno == EEXIST ? LaptopError.outputExists : LaptopError.storage(errno)
    }
  }
  func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
  func write(_ data: Data, to url: URL, exclusive: Bool) throws {
    if exclusive {
      let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard descriptor >= 0 else { throw LaptopError.storage(errno) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } else {
      let temporary = url.deletingLastPathComponent().appendingPathComponent(
        ".\(UUID().uuidString).partial")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try write(data, to: temporary, exclusive: true)
      guard rename(temporary.path, url.path) == 0 else { throw LaptopError.storage(errno) }
    }
  }
}
