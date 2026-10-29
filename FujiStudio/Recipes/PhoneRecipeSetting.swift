import Foundation
import FujiCameraCore

extension RecipeSettingID {
  var title: String {
    switch self {
    case .film: "Film simulation"
    case .dynamicRange: "Dynamic range"
    case .grain: "Grain"
    case .colorChrome: "Color Chrome"
    case .colorChromeBlue: "Color Chrome FX Blue"
    case .whiteBalance: "White balance"
    case .whiteBalanceRed: "Red shift"
    case .whiteBalanceBlue: "Blue shift"
    case .kelvin: "Temperature"
    case .highlight: "Highlights"
    case .shadow: "Shadows"
    case .color: "Colour"
    case .sharpness: "Sharpness"
    case .noiseReduction: "Noise reduction"
    case .clarity: "Clarity"
    case .lensOptimizer: "Lens optimizer"
    }
  }
  func label(for value: RecipeSettingValue) -> String {
    guard case .integer(let n) = value else { return value.label }
    if [.highlight, .shadow, .color, .sharpness, .clarity].contains(self) {
      return n % 10 == 0 ? signed(n / 10) : String(format: "%+.1f", Double(n) / 10)
    }
    if [.whiteBalanceRed, .whiteBalanceBlue, .noiseReduction].contains(self) { return signed(n) }
    if self == .dynamicRange { return n == 0 ? "Auto" : "\(n)%" }
    return value.label
  }
  private func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }
}
