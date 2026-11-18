import CoreImage
import FujiCameraCore
import ImageIO

struct CameraThumbnail: Sendable {
    let image: CGImage

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func decode(_ data: Data, object: WirelessObjectDescriptor? = nil,
                       maxPixelSize: Int = 288) -> Self? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
                let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
                let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary) else { return nil }

            // X-T5 GetThumb fits the encoded frame inside a fixed 4:3 canvas.
            // Crop in sensor coordinates before applying the separate ObjectInfo orientation.
            var image = decoded
            if width * 3 == height * 4, let size = object?.dimensions, size.width > 0, size.height > 0 {
                let scale = min(Double(decoded.width) / Double(size.width), Double(decoded.height) / Double(size.height))
                let w = max(1, Int((Double(size.width) * scale).rounded()))
                let h = max(1, Int((Double(size.height) * scale).rounded()))
                if w != decoded.width || h != decoded.height {
                    let rect = CGRect(x: (decoded.width - w) / 2, y: (decoded.height - h) / 2, width: w, height: h)
                    guard let cropped = decoded.cropping(to: rect) else { return nil }
                    image = cropped
                }
            }

            let orientation = object?.orientation ?? properties[kCGImagePropertyOrientation] as? Int ?? 1
            guard (2...8).contains(orientation) else { return Self(image: image) }
            let upright = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
            return context.createCGImage(upright, from: upright.extent).map { Self(image: $0) }
        }
    }
}
