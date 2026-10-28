import FujiCameraCore
import Foundation

/// Phone snapshots retain both components, including dormant size while the effect is off.
struct PhoneRecipeGrain: Sendable, Equatable {
    enum Effect: String, CaseIterable, Sendable, Identifiable {
        case off = "Off", weak = "Weak", strong = "Strong"
        var id: Self { self }
    }
    enum Size: String, CaseIterable, Sendable, Identifiable {
        case small = "Small", large = "Large"
        var id: Self { self }
    }
    let effect: Effect
    let size: Size

    init(effect: Effect, size: Size) { self.effect = effect; self.size = size }
    init?(rawValue: UInt16) {
        switch rawValue {
        case 1, 6: self.init(effect: .off, size: .small)
        case 7: self.init(effect: .off, size: .large)
        case 2: self.init(effect: .weak, size: .small)
        case 3: self.init(effect: .strong, size: .small)
        case 4: self.init(effect: .weak, size: .large)
        case 5: self.init(effect: .strong, size: .large)
        default: return nil
        }
    }
    var rawValue: UInt16 {
        switch (effect, size) {
        case (.off, .small): 6
        case (.off, .large): 7
        case (.weak, .small): 2
        case (.weak, .large): 4
        case (.strong, .small): 3
        case (.strong, .large): 5
        }
    }
    static var combinations: [Self] {
        Effect.allCases.flatMap { effect in Size.allCases.map { Self(effect: effect, size: $0) } }
    }
}
