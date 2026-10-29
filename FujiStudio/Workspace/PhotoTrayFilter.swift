import FujiCameraCore
import Foundation

enum PhotoTrayFilter: Sendable, Equatable { case allPhotos, compatibleWithCamera }
enum PhotoTrayAssessment: Sendable, Equatable { case compatible, incompatible, unavailable }

/// Admission results belong to a source revision and a verified set of camera rules,
/// rather than a physical USB attachment or a transient ready/busy state.
struct PhotoTrayFilterCamera: Sendable, Hashable {
    let model: String
    let firmware: String
    let capability: String
    let supportVersion: String
    init(_ support: VerifiedCameraSupport) {
        model = support.model; firmware = support.firmware
        capability = support.capability; supportVersion = support.supportVersion
    }
}

struct PhotoTrayFilterIndex: Sendable {
    private var results: [PhotoTrayFilterCamera: [OriginalIdentity: PhotoTrayAssessment]] = [:]
    func result(for source: PhotoSource, camera: PhotoTrayFilterCamera) -> PhotoTrayAssessment? {
        results[camera]?[OriginalIdentity(source)]
    }
    mutating func record(_ result: PhotoTrayAssessment, source: PhotoSource, camera: PhotoTrayFilterCamera) {
        results[camera, default: [:]][OriginalIdentity(source)] = result
    }
    mutating func retryUnavailable(camera: PhotoTrayFilterCamera) {
        results[camera] = results[camera]?.filter { $0.value != .unavailable }
    }
    mutating func retain(_ sources: [PhotoSource]) {
        let identities = Set(sources.map(OriginalIdentity.init))
        for camera in results.keys { results[camera] = results[camera]?.filter { identities.contains($0.key) } }
    }
}
