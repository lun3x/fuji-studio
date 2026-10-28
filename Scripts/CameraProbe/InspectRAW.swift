import Foundation
import CoreImage
import ImageIO
let context = CIContext(options: [.cacheIntermediates: false])
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    var report: [String:Any] = ["file":url.lastPathComponent]
    if let filter = CIRAWFilter(imageURL: url) {
        report["filterAvailable"] = true
        report["nativeWidth"] = filter.nativeSize.width
        report["nativeHeight"] = filter.nativeSize.height
        filter.orientation = .up
        for scale:Float in [1,0.25] {
            filter.scaleFactor = scale
            let image = filter.outputImage
            report["outputImageAtScale\(scale)"] = image != nil
            if let image {
                report["decodedAtScale\(scale)"] = context.createCGImage(image, from:image.extent) != nil
                report["extentAtScale\(scale)"] = [image.extent.width,image.extent.height]
            }
        }
    } else { report["filterAvailable"] = false }
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),as:UTF8.self))
}
