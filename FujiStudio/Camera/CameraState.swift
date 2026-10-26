import Foundation

struct CameraConnection: Sendable, Equatable {
    let name: String
    let usbVendorID: Int
    let usbProductID: Int
}

struct CameraSession: Sendable, Equatable {
    let generation: UInt64
    let connection: CameraConnection
}

enum CameraState: Sendable, Equatable {
    case disconnected
    case discovering
    case authorizationRequired
    case authorizationDenied
    case opening
    /// Public USB PTP session only. RAW conversion mode, firmware and model remain unverified.
    case sessionOpen(CameraSession)
    /// Reserved for the higher camera service after it verifies conversion capability.
    case ready(CameraSession)
    case busy(CameraSession)
    case wrongMode(String)
    case recoverableError(PTPError)
}
