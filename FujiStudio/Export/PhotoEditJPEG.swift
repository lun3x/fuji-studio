import FujiCameraCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoEditJPEG {
    /// PhotoKit requires upright pixels and orientation 1 for content-editing output.
    static func write(_ jpeg: CameraJPEG, to destination: URL) throws {
        guard jpeg.fileURL.isFileURL,
              let source = CGImageSourceCreateWithURL(jpeg.fileURL as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let geometry = try? ImageGeometry.read(jpeg.fileURL),
              geometry.encoded == PixelSize(width: jpeg.width, height: jpeg.height),
              geometry.orientation == jpeg.orientation, (1...8).contains(jpeg.orientation) else {
            throw PhotoLibraryWriteError.invalidOutput("The camera JPEG is unavailable or has invalid geometry.")
        }
        do {
            if jpeg.orientation == 1 {
                try FileManager.default.copyItem(at: jpeg.fileURL, to: destination)
                return
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(jpeg.width, jpeg.height)]
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  upright.width == geometry.upright.width, upright.height == geometry.upright.height,
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PhotoLibraryWriteError.invalidOutput("The camera JPEG could not be oriented for Photos.")
            }
            var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = upright.width
            properties[kCGImagePropertyPixelHeight] = upright.height
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1; properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            CGImageDestinationAddImage(output, upright, properties as CFDictionary)
            guard CGImageDestinationFinalize(output) else {
                throw PhotoLibraryWriteError.invalidOutput("The upright JPEG could not be written.")
            }
        } catch let error as PhotoLibraryWriteError { throw error }
        catch {
            let failure = PhotoLibraryWriter.failure(error as NSError)
            throw PhotoLibraryWriteError.rejected(failure)
        }
    }
}
