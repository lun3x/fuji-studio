import Foundation

public struct FujiCameraRegistry: Sendable {
  private let adapters: [any FujiCameraAdapter]
  public init(adapters: [any FujiCameraAdapter] = [XT5Adapter()]) { self.adapters = adapters }
  public func adapter(for device: FujiDeviceInfo) throws -> any FujiCameraAdapter {
    guard device.manufacturer == "FUJIFILM" else { throw CameraServiceError.unsupportedContext }
    let matches = adapters.filter { $0.model == device.model }
    guard matches.count == 1, let adapter = matches.first else {
      throw CameraServiceError.unsupportedContext
    }
    return adapter
  }
}
