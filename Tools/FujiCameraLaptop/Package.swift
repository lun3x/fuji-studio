// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"FujiCameraLaptop",platforms:[.macOS("27.0")],products:[.executable(name:"FujiCameraLaptop",targets:["FujiCameraLaptop"])],dependencies:[.package(path:"../../Packages/FujiCameraCore")],targets:[.executableTarget(name:"FujiCameraLaptop",dependencies:[.product(name:"FujiCameraCore",package:"FujiCameraCore")]),.testTarget(name:"FujiCameraLaptopTests",dependencies:["FujiCameraLaptop"])])
