import Darwin
import Foundation

struct RunDirectory {
  enum Failure: Error {
    case invalidDirectory
    case alreadyUsed
    case invalidPermissions
  }

  let url: URL

  init(path: String) throws {
    var info = stat()
    guard path.hasPrefix("/"), lstat(path, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700,
      info.st_uid == getuid()
    else { throw Failure.invalidDirectory }

    url = URL(filePath: path, directoryHint: .isDirectory)
    let marker = url.appending(path: ".started").path
    let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw Failure.alreadyUsed }
    close(fd)
  }

  func nextCommand() throws -> String? {
    let file = url.appending(path: "command")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 65) ?? Data()
    try FileManager.default.removeItem(at: file)
    guard data.count <= 64, let text = String(data: data, encoding: .utf8) else { return "" }
    return text.trimmingCharacters(in: .newlines)
  }

  func write(_ text: String, to name: String) throws {
    try write(Data(text.utf8), to: name)
  }

  func write(_ data: Data, to name: String) throws {
    let file = url.appending(path: name)
    try data.write(to: file, options: .atomic)
    guard chmod(file.path, 0o600) == 0 else { throw Failure.invalidPermissions }
  }
}
