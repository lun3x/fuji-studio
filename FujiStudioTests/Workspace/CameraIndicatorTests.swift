import Testing
@testable import FujiStudio

private let indicatorSession = CameraSession(generation: 1,
    connection: CameraConnection(name: "X-T5", usbVendorID: 0, usbProductID: 0))

struct CameraIndicatorTests {
    @Test(arguments: [CameraState.ready(indicatorSession), .busy(indicatorSession)])
    func connectedSessionStaysPreparingUntilRecipeImportFinishes(_ camera: CameraState) {
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: true) == .preparing)
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: false) == .ready)
    }

    @Test(arguments: [CameraState.disconnected, .discovering, .opening, .sessionOpen(indicatorSession),
        .authorizationRequired, .authorizationDenied, .wrongMode("USB mode"), .recoverableError(.notConnected)])
    func unavailableCameraOverridesAnUnfinishedRecipeImport(_ camera: CameraState) {
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: true) == .disconnected)
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: false) == .disconnected)
    }
}
