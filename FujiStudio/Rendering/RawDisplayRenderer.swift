import FujiCameraCore
import Foundation
import CoreImage
import ImageIO

enum RawDisplayError: Error, Sendable, Equatable { case unavailable, invalidDetail, storage }

/// Real RAW pixels only. Actor isolation and synchronous render ownership allow one active
/// full-detail decode; Core Image intermediates are released after writing each file.
actor RawDisplayRenderer {
    private let directory: URL
    private let maximumDimension: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var currentDisplay: URL?, currentDetail: URL?

    init(directory: URL, displayMaximumDimension: Int = 2048) throws {
        guard displayMaximumDimension > 0 else { throw RawDisplayError.invalidDetail }
        self.directory = directory; maximumDimension = displayMaximumDimension
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Caller must hold an OriginalResourcePool lease for the entire await.
    func render(_ raw: PreparedRAW) async throws -> URL {
        try write(raw, region: nil, maximumDimension: maximumDimension)
    }

    /// Region is in normalized, upright image coordinates (Core Image's bottom-left origin).
    /// Request on zoom only; the previously generated detail file is replaced after success.
    func renderDetail(_ raw: PreparedRAW, region: CGRect, maximumDimension: Int) async throws -> URL {
        guard maximumDimension > 0, region.width > 0, region.height > 0,
              region.minX >= 0, region.minY >= 0, region.maxX <= 1, region.maxY <= 1,
              [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite) else { throw RawDisplayError.invalidDetail }
        return try write(raw, region: region, maximumDimension: maximumDimension)
    }

    private func write(_ raw: PreparedRAW, region: CGRect?, maximumDimension: Int) throws -> URL {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: raw.fileURL),
                  let orientation = CGImagePropertyOrientation(rawValue: UInt32(raw.metadata.orientation)) else { throw RawDisplayError.unavailable }
            defer { context.clearCaches() }
            filter.orientation = .up
            let native = filter.nativeSize, recorded = raw.metadata.recordedGeometry, container = raw.metadata.containerGeometry
            let crop: CGRect
            if Int(native.width) == recorded.width && Int(native.height) == recorded.height {
                crop = CGRect(origin: .zero, size: native)
            } else if Int(native.width) == container.width && Int(native.height) == container.height {
                crop = CGRect(x: raw.metadata.cropLeft, y: container.height - raw.metadata.cropTop - recorded.height, width: recorded.width, height: recorded.height)
            } else { throw RawDisplayError.unavailable }
            // A detail request decodes native detail on demand; fit requests ask the RAW decoder
            // for reduced resolution before rendering. No embedded or paired JPEG fallback exists.
            let scale = region == nil ? min(1, Double(maximumDimension) / max(crop.width, crop.height)) : 1
            filter.scaleFactor = Float(scale)
            guard var image = filter.outputImage else { throw RawDisplayError.unavailable }
            image = image.cropped(to: crop.applying(CGAffineTransform(scaleX: scale, y: scale)))
                .oriented(orientation)
            if let region {
                let bounds = image.extent
                image = image.cropped(to: CGRect(x: bounds.minX + region.minX * bounds.width,
                    y: bounds.minY + region.minY * bounds.height, width: region.width * bounds.width, height: region.height * bounds.height).integral)
            }
            let bounds = image.extent
            guard !bounds.isEmpty, !bounds.isInfinite else { throw RawDisplayError.unavailable }
            image = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            let outputScale = min(1, Double(maximumDimension) / max(bounds.width, bounds.height))
            image = image.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))
            let partial = directory.appendingPathComponent(UUID().uuidString + ".partial")
            let output = directory.appendingPathComponent(UUID().uuidString + ".JPG")
            defer { try? FileManager.default.removeItem(at: partial) }
            do {
                try context.writeJPEGRepresentation(of: image, to: partial, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithURL(partial as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      let width = properties[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
                      let height = properties[kCGImagePropertyPixelHeight as String] as? Int, height > 0 else { throw RawDisplayError.unavailable }
                try FileManager.default.moveItem(at: partial, to: output)
            } catch is CancellationError { throw CancellationError() }
            catch let error as RawDisplayError { throw error }
            catch { throw RawDisplayError.unavailable }
            if region == nil {
                if let currentDisplay { try? FileManager.default.removeItem(at: currentDisplay) }
                currentDisplay = output
                if let currentDetail { try? FileManager.default.removeItem(at: currentDetail) }; currentDetail = nil
            } else {
                if let currentDetail { try? FileManager.default.removeItem(at: currentDetail) }; currentDetail = output
            }
            return output
        }
    }
}
