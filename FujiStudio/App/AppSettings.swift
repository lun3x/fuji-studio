import Foundation
import Observation

@MainActor @Observable final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let updateOriginalKey = "updateOriginalInPhotos"

    var updateOriginalInPhotos: Bool {
        didSet { defaults.set(updateOriginalInPhotos, forKey: Self.updateOriginalKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        updateOriginalInPhotos = defaults.bool(forKey: Self.updateOriginalKey)
    }
}
