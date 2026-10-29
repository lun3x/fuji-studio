import Foundation

/// One-way conversion at storage-open time. Normal DTO decoders accept only the current schema.
public enum RecipePayloadUpgrade {
  public static func convert(_ data: Data) throws -> Data {
    var changed = false
    func visit(_ value: Any) throws -> Any {
      if let array = value as? [Any] { return try array.map(visit) }
      guard var object = value as? [String: Any] else { return value }
      if object.count == 1, object["xt5"] is [String: Any] {
        changed = true
        return ["supported": ["model": "X-T5"]]
      }
      if var requested = object["requested"] as? [String: Any],
        requested["observedOpaqueTuple"] != nil
      {
        guard let film = requested["film"] as? Int,
          let semanticFilm = FujiRenderingValues.films[UInt16(exactly: film) ?? 0],
          let wb = requested["whiteBalance"] as? Int,
          let semanticWB = FujiRenderingValues.whiteBalances[UInt16(exactly: wb) ?? 0],
          let grain = requested["grain"] as? String, let chrome = requested["colorChrome"] as? Int,
          let semanticChrome = FujiRenderingValues.effects[UInt16(exactly: chrome) ?? 0],
          let blue = requested["colorChromeBlue"] as? Int,
          let semanticBlue = FujiRenderingValues.effects[UInt16(exactly: blue) ?? 0]
        else { throw CameraServiceError.unsupportedSettings }
        let grains: [String: GrainSettings] = [
          "offSmall": .init(strength: .off, size: .small),
          "offLarge": .init(strength: .off, size: .large),
          "strongSmall": .init(strength: .strong, size: .small),
        ]
        guard let semanticGrain = grains[grain] else {
          throw CameraServiceError.unsupportedSettings
        }
        requested["film"] = semanticFilm.rawValue
        requested["whiteBalance"] = semanticWB.rawValue
        requested["colorChrome"] = semanticChrome.rawValue
        requested["colorChromeBlue"] = semanticBlue.rawValue
        requested["grain"] = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(semanticGrain))
        requested.removeValue(forKey: "observedOpaqueTuple")
        requested.removeValue(forKey: "supportVersion")
        // Prove the current decoder accepts the complete result before returning any bytes.
        _ = try JSONDecoder().decode(
          RecipeSettings.self, from: JSONSerialization.data(withJSONObject: requested))
        object["requested"] = requested
        changed = true
      }
      for key in Array(object.keys) { object[key] = try visit(object[key]!) }
      return object
    }
    let root = try JSONSerialization.jsonObject(with: data)
    let result = try visit(root)
    guard changed else { return data }
    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  }
}
