import Darwin
import Foundation

@main
@MainActor
private struct RunDirectoryTests {
  private static let files = FileManager.default

  static func main() throws {
    umask(0o077)
    let temporary = URL(filePath: "/tmp").appending(path: "fuji-mac-file-tests-\(UUID())")
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }

    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
      if !condition { failures.append(message) }
    }

    let (aclRun, aclPath) = try fixture("acl-directory", in: temporary)
    try addACL("everyone allow add_file,search", to: aclPath)
    expect(rejects { _ = try RunDirectory(path: aclPath) }, "run directory grants access through ACL")
    try Data("phase=idle\n".utf8).write(to: aclRun.appending(path: "status"))
    expect(
      try run(CommandLine.arguments[1], [aclPath, "discover"]) != 0,
      "controller accepts a directory with an ACL grant")

    let (preexistingRun, preexistingPath) = try fixture("preexisting", in: temporary)
    try Data("discover\n".utf8).write(to: preexistingRun.appending(path: "command"))
    expect(rejects { _ = try RunDirectory(path: preexistingPath) }, "run directory contains a staged command")

    let (run, path) = try fixture("commands", in: temporary)
    let directory = try RunDirectory(path: path)
    let commandFile = run.appending(path: "command")

    try directory.write("discover\n", to: "command")
    expect(try directory.nextCommand() == "discover", "valid command was not accepted")
    expect(try directory.nextCommand() == nil, "valid command was not removed")

    try directory.write("discover\n", to: "command")
    try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: commandFile.path)
    expect(rejects { _ = try directory.nextCommand() }, "command with mode 0644 was accepted")
    if files.fileExists(atPath: commandFile.path) { try files.removeItem(at: commandFile) }

    let target = run.appending(path: "other")
    try directory.write("discover\n", to: "other")
    try files.createSymbolicLink(at: commandFile, withDestinationURL: target)
    expect(rejects { _ = try directory.nextCommand() }, "symbolic link command was accepted")
    if files.fileExists(atPath: commandFile.path) { try files.removeItem(at: commandFile) }

    try directory.write("discover\n", to: "command")
    try addACL("everyone allow read", to: commandFile.path)
    expect(rejects { _ = try directory.nextCommand() }, "command with an ACL grant was accepted")
    expect(!files.fileExists(atPath: commandFile.path), "rejected command was left in the inbox")

    precondition(mkfifo(commandFile.path, 0o600) == 0, "Could not create test FIFO")
    expect(rejects { _ = try directory.nextCommand() }, "FIFO command was accepted")
    expect(!files.fileExists(atPath: commandFile.path), "FIFO was left in the inbox")

    try directory.write("phase=idle\n", to: "status")
    expect(try self.run(CommandLine.arguments[1], [path, "discover"]) == 0, "controller could not queue command")
    expect(try self.run(CommandLine.arguments[1], [path, "pair"]) != 0, "controller overwrote queued command")
    expect(try directory.nextCommand() == "discover", "probe could not read controller command")

    let relocated = temporary.appending(path: "relocated")
    try files.moveItem(at: run, to: relocated)
    try files.createDirectory(at: run, withIntermediateDirectories: false)
    try directory.write("protected", to: "private-bluetooth-model.json")
    expect(!files.fileExists(atPath: run.appending(path: "private-bluetooth-model.json").path),
      "private evidence followed a replaced run-directory path")
    var evidence = stat()
    let file = relocated.appending(path: "private-bluetooth-model.json")
    expect(stat(file.path, &evidence) == 0 && evidence.st_mode & 0o777 == 0o600,
      "private evidence was not written with mode 0600")

    if failures.isEmpty {
      print("Run directory permission checks passed.")
    } else {
      for failure in failures { print("FAIL: \(failure)") }
      exit(1)
    }
  }

  private static func fixture(_ name: String, in temporary: URL) throws -> (URL, String) {
    let directory = temporary.appending(path: name)
    try files.createDirectory(at: directory, withIntermediateDirectories: false)
    return (directory, directory.path)
  }

  private static func rejects(_ action: () throws -> Void) -> Bool {
    do {
      try action()
      return false
    } catch {
      return true
    }
  }

  private static func addACL(_ entry: String, to path: String) throws {
    let status = try run("/bin/chmod", ["+a", entry, path])
    precondition(status == 0, "Could not apply test ACL")
  }

  private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
