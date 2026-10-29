import Foundation
import Testing

@testable import FujiCameraLaptop

struct LaptopArgumentsTests {
  @Test func laptopFilesUsePrivatePOSIXPermissionsAndExclusiveIntent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let policy = MacJournalFilePolicy()
    try policy.createFreshDirectory(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("intent.json")
    try policy.write(Data([1]), to: file, exclusive: true)
    #expect(throws: (any Error).self) { try policy.write(Data([2]), to: file, exclusive: true) }
    #expect(try Data(contentsOf: file) == Data([1]))
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(directoryMode?.intValue == 0o700 && fileMode?.intValue == 0o600)
  }
  @Test(arguments: [
    [], ["render"],
    ["render", "--raw", "a.RAF", "--slot", "1", "--recipe-file", "r.json", "--output", "fresh"],
    ["import-recipes", "--output", "x", "--output", "y"],
    ["render", "--raw", "a.RAF", "--slot", "0", "--output", "fresh"],
  ])
  func invalidArgumentsNeverStartDiscovery(_ arguments: [String]) async {
    let probe = LaptopStartProbe()
    await #expect(throws: (any Error).self) {
      try await LaptopRunner.run(
        arguments: arguments,
        makeRuntime: { _ in
          await probe.started()
          throw LaptopError.invalidArguments
        })
    }
    #expect(await probe.starts == 0)
  }
  @Test func existingOutputDirectoryIsNotOverwritten() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data("retain".utf8)
    let file = directory.appendingPathComponent("retained")
    try original.write(to: file)
    let probe = LaptopStartProbe()
    await #expect(throws: (any Error).self) {
      try await LaptopRunner.run(
        arguments: ["import-recipes", "--output", directory.path],
        makeRuntime: { _ in
          await probe.started()
          throw LaptopError.invalidArguments
        })
    }
    #expect(try Data(contentsOf: file) == original)
    #expect(await probe.starts == 0)
  }
}
actor LaptopStartProbe {
  var starts = 0
  func started() { starts += 1 }
}
