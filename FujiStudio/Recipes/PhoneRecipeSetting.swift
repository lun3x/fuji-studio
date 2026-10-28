import Foundation

enum PhoneRecipeSetting: String, CaseIterable, Sendable, Identifiable {
    case film, dynamicRange, grain, colorChrome, colorChromeBlue
    case whiteBalance, whiteBalanceRed, whiteBalanceBlue, kelvin
    case highlight, shadow, color, sharpness, noiseReduction, clarity
    var id: String { rawValue }
    struct Choice: Sendable, Identifiable {
        let value: UInt16
        let label: String
        var id: UInt16 { value }
    }
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
        }
    }
    var code: UInt16 {
        switch self {
        case .dynamicRange: 0xD190
        case .film: 0xD192
        case .grain: 0xD195
        case .colorChrome: 0xD196
        case .colorChromeBlue: 0xD197
        case .whiteBalance: 0xD199
        case .whiteBalanceRed: 0xD19A
        case .whiteBalanceBlue: 0xD19B
        case .kelvin: 0xD19C
        case .highlight: 0xD19D
        case .shadow: 0xD19E
        case .color: 0xD19F
        case .sharpness: 0xD1A0
        case .noiseReduction: 0xD1A1
        case .clarity: 0xD1A2
        }
    }
    var choices: [Choice] {
        switch self {
        case .film:
            [(1,"PROVIA / Standard"),(11,"Classic Chrome"),(12,"ACROS"),(14,"ACROS + R"),(15,"ACROS + G")].map { Choice(value: $0.0, label: $0.1) }
        case .dynamicRange: [Choice(value: 100, label: "100%"), Choice(value: 400, label: "400%")]
        case .grain:
            PhoneRecipeGrain.combinations.map { Choice(value: $0.rawValue, label: "\($0.effect.rawValue) · \($0.size.rawValue)") }
        case .colorChrome, .colorChromeBlue:
            [Choice(value: 1, label: "Off"), Choice(value: 2, label: "Weak"), Choice(value: 3, label: "Strong")]
        case .whiteBalance: [Choice(value: 2, label: "Auto"), Choice(value: 32775, label: "Colour temperature")]
        case .whiteBalanceRed, .whiteBalanceBlue: signedChoices(-9...9)
        case .highlight, .shadow: toneChoices(-20...40, step: 5)
        case .color, .sharpness: toneChoices(-40...40, step: 10)
        case .clarity: toneChoices(-50...50, step: 10)
        case .noiseReduction:
            [UInt16(0x8000),0x7000,0x4000,0x3000,0x2000,0x1000,0,0x6000,0x5000].enumerated().map {
                Choice(value: $0.element, label: signedLabel($0.offset - 4))
            }
        case .kelvin: []
        }
    }
    func accepts(_ value: UInt16) -> Bool {
        if self == .grain { return PhoneRecipeGrain(rawValue: value) != nil }
        return self == .kelvin ? (2500...10000).contains(value) : choices.contains { $0.value == value }
    }
    private func signedChoices(_ range: ClosedRange<Int>) -> [Choice] {
        range.map { Choice(value: UInt16(bitPattern: Int16($0)), label: signedLabel($0)) }
    }
    private func toneChoices(_ range: ClosedRange<Int>, step: Int) -> [Choice] {
        stride(from: range.lowerBound, through: range.upperBound, by: step).map {
            let label = $0 % 10 == 0 ? signedLabel($0 / 10) : String(format: "%+.1f", Double($0) / 10)
            return Choice(value: UInt16(bitPattern: Int16($0)), label: label)
        }
    }
    private func signedLabel(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}
