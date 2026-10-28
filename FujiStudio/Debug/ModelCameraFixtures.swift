import FujiCameraCore

#if DEBUG
  import Foundation

  func fixtureXE3Snapshots() throws -> [RecipeSnapshot] {
    let context = RecipeCameraContext(
      model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
      sessionGeneration: 1)
    let fields: [UInt16: Data] = [
      1: Data([13]), 2: Data([3]), 3: Data([1]), 4: Data([8]), 5: Data([13]), 6: Data([11]),
      7: Data([6]), 8: Data([5]), 9: Data([2]), 10: Data([7]), 11: Data([4]), 12: Data([0]),
      13: Data([0xb9, 1]),
    ]
    return try (1...7).map { slot in
      try XE3RecipeCodec.recipe(
        slot: slot, nameData: Data("X-E3 look \(slot)\0".utf8), properties: fields,
        context: context, importedAt: Date(timeIntervalSince1970: 0))
    }
  }
#endif
