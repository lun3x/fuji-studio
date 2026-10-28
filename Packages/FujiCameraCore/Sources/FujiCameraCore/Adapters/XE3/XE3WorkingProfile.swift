import Foundation

public enum XE3WorkingProfile {
  public static let writableOffsets = [
    533, 541, 545, 553, 557, 561, 565, 569, 573, 577, 581, 585, 589,
  ]
  public static func make(baseline: Data, settings: RecipeSettings, source: RAWMetadata) throws
    -> PreparedConversion
  {
    try XE3SourceRules.validate(source)
    try XE3Capabilities.validate(settings)
    guard baseline.count == 601, baseline.prefix(3) == Data([23, 0, 8]),
      baseline.subdata(in: 3..<19) == Data("FF129505".utf16.flatMap { [UInt8($0), 0] }),
      baseline[19..<513].allSatisfy({ $0 == 0 })
    else { throw CameraServiceError.unsupportedProfile }
    func word(_ offset: Int) -> Int32 {
      Int32(
        bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(baseline[offset + $1]) << ($1 * 8) })
    }
    for (offset, value): (Int, Int32) in [
      (513, 2), (517, 7), (521, 7), (525, 2), (529, 0), (537, 0), (549, 1), (553, 1), (557, 0),
      (569, 0), (597, 1),
    ] { guard word(offset) == value else { throw CameraServiceError.unsupportedProfile } }
    guard [100, 200, 400].contains(word(533)), (1...15).contains(word(541)),
      (1...3).contains(word(545)), (-9...9).contains(word(561)), (-9...9).contains(word(565)),
      [1, 2].contains(word(593))
    else { throw CameraServiceError.unsupportedProfile }
    guard let film = FujiRenderingValues.films.first(where: { $0.value == settings.film })?.key,
      let wb = FujiRenderingValues.whiteBalances.first(where: { $0.value == settings.whiteBalance }
      )?.key,
      let nr = FujiRenderingValues.noise.first(where: { $0.value == settings.noiseReduction })?.key
    else { throw CameraServiceError.unsupportedSettings }
    var output = baseline
    func put(_ value: Int, _ offset: Int) {
      let word = UInt32(bitPattern: Int32(value))
      output.replaceSubrange(
        offset..<offset + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
    }
    let grain: [GrainStrength: Int] = [.off: 1, .weak: 2, .strong: 3]
    for (offset, value) in [
      (533, settings.dynamicRange), (541, Int(film)), (545, grain[settings.grain.strength]!),
      (553, 2), (557, Int(wb)), (561, settings.whiteBalanceRed), (565, settings.whiteBalanceBlue),
      (573, settings.highlightTenths), (577, settings.shadowTenths), (581, settings.colorTenths),
      (585, settings.sharpnessTenths), (589, Int(nr)),
    ] { put(value, offset) }
    if settings.whiteBalance == .temperature, let kelvin = settings.kelvin { put(kelvin, 569) }
    return .init(
      bytes: output, requested: settings, source: source, supportVersion: XE3Support.identifier,
      expectedLensOptimizer: word(593) == 1, baselineSHA256: ResourceChecksum.sha256(baseline),
      candidateSHA256: ResourceChecksum.sha256(output))
  }
}
