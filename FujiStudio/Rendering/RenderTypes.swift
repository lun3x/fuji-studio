import Foundation

enum OutputPolicy: String, Sendable, Codable, Hashable { case fullSizeFineRecordedGeometry }
enum CameraJPEGQuality: String, Sendable, Codable, Hashable { case fullResolutionFine }

struct RenderKey: Sendable, Codable, Hashable {
    let sourceID: SourceID, sourceRevision: String, sourceSHA256: String, settingsDigest: String
    let cameraContext: CameraExecutionContext
    let width: Int, height: Int, orientation: Int
    let policy: OutputPolicy
    let quality: CameraJPEGQuality
}

/// Ownership of this single validated file transfers to the caller after confirmed camera cleanup.
/// A completed journal stores provenance, not an additional full-size image copy.
struct CameraJPEG: Sendable, Codable, Equatable {
    let fileURL: URL
    let sourceID: SourceID, sourceRevision: String, sourceSHA256: String
    let recipeSnapshotID: UUID
    let settingsDigest: String
    let cameraContext: CameraExecutionContext
    let operationID: UUID
    let width: Int, height: Int, orientation: Int
    let quality: CameraJPEGQuality
    let effectiveRecipe: EffectiveRecipeReport
    let baselineSHA256: String, candidateSHA256: String, outputSHA256: String
    let key: RenderKey
}

enum RequestedGrain: String, Sendable, Codable, Hashable { case offSmall, offLarge, strongSmall }
enum SupportedFilm: UInt16, Sendable, Codable, Hashable {
    case provia = 1, classicChrome = 11, acros = 12, acrosRed = 14, acrosGreen = 15
}
enum SupportedWhiteBalance: UInt16, Sendable, Codable, Hashable { case auto = 2, temperature = 32775 }

struct NormalizedRecipeSettings: Sendable, Codable, Hashable {
    let supportVersion: String
    let film: SupportedFilm
    let grain: RequestedGrain
    let dynamicRange: Int
    /// Observed 1=OFF, 2=WEAK, 3=STRONG domains, not the older zero-based FX Blue table.
    let colorChrome: Int, colorChromeBlue: Int
    let whiteBalance: SupportedWhiteBalance
    let whiteBalanceRed: Int, whiteBalanceBlue: Int, kelvin: Int
    let highlightTenths: Int, shadowTenths: Int, colorTenths: Int, sharpnessTenths: Int, clarityTenths: Int
    let noiseReduction: Int
    /// Joint profile-class evidence; no individual semantic meaning assigned to these properties.
    let observedOpaqueTuple: [UInt16]
    let lensOptimizerRequested: Bool
    var colorSpace: String { "sRGB" }
}

struct EffectiveRecipeReport: Sendable, Codable, Equatable {
    let supportVersion: String
    let requested: NormalizedRecipeSettings
    let dormantGrainSizeNotSerialized: Bool
    let inactiveKelvinPreserved: Bool
    let lensOptimizerRequested: Bool
    let lensOptimizerEffective: Bool
    let lensOptimizerAdjusted: Bool
    let evidence: String
}

extension CameraJPEG {
    /// Relocation preserves the original render's provenance, even for a renamed frozen job recipe.
    func relocated(to url: URL) -> CameraJPEG {
        CameraJPEG(fileURL: url, sourceID: sourceID, sourceRevision: sourceRevision, sourceSHA256: sourceSHA256,
                   recipeSnapshotID: recipeSnapshotID, settingsDigest: settingsDigest, cameraContext: cameraContext,
                   operationID: operationID, width: width, height: height, orientation: orientation, quality: quality,
                   effectiveRecipe: effectiveRecipe, baselineSHA256: baselineSHA256, candidateSHA256: candidateSHA256,
                   outputSHA256: outputSHA256, key: key)
    }
}
