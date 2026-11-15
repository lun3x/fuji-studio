import Darwin
import Foundation

final class RunDirectory {
  enum Failure: Error {
    case invalidDirectory
    case alreadyUsed
    case invalidCommandFile
    case fileOperationFailed
  }

  private let descriptor: Int32

  init(path: String) throws {
    guard path.hasPrefix("/") else { throw Failure.invalidDirectory }
    let directory = URL(filePath: path, directoryHint: .isDirectory).path
    let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.invalidDirectory }
    do {
      guard Self.isOwnerOnly(fd, type: S_IFDIR, permissions: 0o700) else {
        throw Failure.invalidDirectory
      }
      guard try Self.isEmpty(fd) else { throw Failure.alreadyUsed }
      let marker = openat(fd, ".started", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
      guard marker >= 0 else { throw Failure.alreadyUsed }
      close(marker)
    } catch {
      close(fd)
      throw error
    }
    descriptor = fd
  }

  deinit {
    close(descriptor)
  }

  func nextCommand() throws -> String? {
    // Claim the entry before opening it so rejected entries cannot block the
    // next submission. Moving a symlink does not dereference its target.
    let claimed = ".reading-\(UUID().uuidString)"
    guard renameat(descriptor, "command", descriptor, claimed) == 0 else {
      if errno == ENOENT { return nil }
      throw Failure.fileOperationFailed
    }
    defer { _ = unlinkat(descriptor, claimed, 0) }

    let fd = openat(descriptor, claimed, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.invalidCommandFile }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    guard Self.isOwnerOnly(fd, type: S_IFREG, permissions: 0o600) else {
      throw Failure.invalidCommandFile
    }

    let data = try handle.read(upToCount: 65) ?? Data()
    guard data.count <= 64, let text = String(data: data, encoding: .utf8) else { return "" }
    return text.trimmingCharacters(in: .newlines)
  }

  func write(_ text: String, to name: String) throws {
    try write(Data(text.utf8), to: name)
  }

  func write(_ data: Data, to name: String) throws {
    let temporary = ".writing-\(UUID().uuidString)"
    let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw Failure.fileOperationFailed }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      _ = unlinkat(descriptor, temporary, 0)
    }
    try handle.write(contentsOf: data)
    guard renameat(descriptor, temporary, descriptor, name) == 0 else {
      throw Failure.fileOperationFailed
    }
  }

  private static func isOwnerOnly(_ fd: Int32, type: mode_t, permissions: mode_t) -> Bool {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == type,
      info.st_mode & 0o7777 == permissions, info.st_uid == getuid()
    else { return false }

    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
      acl_free(UnsafeMutableRawPointer(acl))
      return false
    }
    return errno == ENOENT
  }

  private static func isEmpty(_ fd: Int32) throws -> Bool {
    let copy = dup(fd)
    guard copy >= 0 else { throw Failure.invalidDirectory }
    guard let entries = fdopendir(copy) else {
      close(copy)
      throw Failure.invalidDirectory
    }
    defer { closedir(entries) }
    while true {
      errno = 0
      guard let entry = readdir(entries) else {
        if errno != 0 { throw Failure.invalidDirectory }
        return true
      }
      let length = Int(entry.pointee.d_namlen)
      let name = withUnsafeBytes(of: &entry.pointee.d_name) {
        String(decoding: $0.prefix(length), as: UTF8.self)
      }
      if name != ".", name != ".." { return false }
    }
  }
}
