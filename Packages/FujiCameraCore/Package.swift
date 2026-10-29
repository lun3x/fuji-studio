// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FujiCameraCore", platforms: [.iOS("27.0"), .macOS("27.0")], products: [.library(name: "FujiCameraCore", targets: ["FujiCameraCore"])], targets: [.target(name: "FujiCameraCore"), .testTarget(name: "FujiCameraCoreTests", dependencies: ["FujiCameraCore"], resources: [.copy("Fixtures")])])
