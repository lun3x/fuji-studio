import CryptoKit
import Foundation

public enum XT5RecipeCodec {
  public static func recipe(
    slot: Int, nameData: Data, properties: [UInt16: Data], context: RecipeCameraContext,
    importedAt: Date
  ) throws -> RecipeSnapshot {
    guard (1...7).contains(slot) else { throw RecipeImportError.invalidSlot }
    let codes = Array(UInt16(0xD18E)...0xD1A4)
    guard Set(properties.keys) == Set(codes) else {
      throw RecipeImportError.incompletePropertyBlock
    }
    guard let name = try PTPDatasets.value(nameData, type: 0xffff).string else {
      throw PTPDatasetError.invalidString
    }
    var imported: [ImportedRecipeProperty] = []
    var canonical = Data("xt5.imported-settings.v1\0".utf8)
    var issues: [RecipeRenderingIssue] = [.conversionProfileUnvalidated]
    for code in codes {
      guard let raw = properties[code], raw.count == 2 else {
        throw RecipeImportError.malformedProperty(code)
      }
      imported.append(ImportedRecipeProperty(code: code, raw: raw))
      canonical.append(contentsOf: [UInt8(truncatingIfNeeded: code), UInt8(code >> 8), 2, 0])
      canonical.append(raw)
      let word = UInt16(raw[raw.startIndex]) | UInt16(raw[raw.startIndex + 1]) << 8
      if [0xD18E, 0xD18F, 0xD1A3, 0xD1A4].contains(code) { issues.append(.unmappedProperty(code)) }
      // Explicit unresolved observations, not approximate film/grain mappings. Other fields
      // remain blocked by conversionProfileUnvalidated until the whole profile is validated.
      if (code == 0xD192 && !(1...20).contains(word)) || (code == 0xD195 && !(1...6).contains(word))
      {
        issues.append(.unsupportedValue(code))
      }
    }
    let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    return RecipeSnapshot(
      id: UUID(), slot: slot, name: name, importedName: nameData, importedSettings: imported,
      settingsDigest: digest, cameraContext: context, importedAt: importedAt,
      renderingIssues: issues)
  }

}
