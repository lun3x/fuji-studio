import Foundation

/// Extracts only bank settings and their selected shared WB dependency. Private camera
/// identifiers and unrelated backup contents never become part of a recipe snapshot.
public enum XE3BackupRecipeCodec {
  public static func decode(
    _ backup: Data, context: RecipeCameraContext, importedAt: Date
  ) throws -> DecodedRecipeCollection {
    guard backup.count == 5660, backup.prefix(8) == Data("FUJIFILM".utf8),
      backup[20..<52].prefix(while: { $0 != 0 }) == Data("X-E3".utf8)
    else { throw RecipeImportError.incompletePropertyBlock }
    let offsets = [0: 433, 1: 443, 2: 445, 3: 447, 4: 449, 5: 451, 6: 453, 7: 455, 8: 441]
    let recipes = try (0..<7).map { index -> RecipeSnapshot in
      let base = 3909 + 256 * index
      let name = Data(backup[(base + 69)..<(base + 85)])
      guard name.contains(0) else { throw RecipeImportError.incompletePropertyBlock }
      var fields: [UInt16: Data] = [:]
      for (id, offset) in [
        (1, 0), (2, 3), (3, 12), (4, -33), (7, -32), (8, 10), (9, 11), (10, 7), (11, 9), (12, -7),
      ] {
        fields[UInt16(id)] = Data([backup[base + offset]])
      }
      if let offset = offsets[Int(backup[base - 33])] {
        fields[5] = Data([backup[offset]])
        fields[6] = Data([backup[offset + 1]])
        fields[13] = Data([UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8)])
      } else {
        // An unknown mode has no established selected pair. Keep the table as opaque
        // evidence instead of inventing neutral shifts or custom measured WB gains.
        fields[14] = Data(backup[433..<457])
      }
      return try XE3RecipeCodec.recipe(
        slot: index + 1, nameData: name, properties: fields, context: context,
        importedAt: importedAt)
    }
    return .init(recipes: recipes, declaredSlots: XE3Capabilities.measured.bankSlots)
  }
}
