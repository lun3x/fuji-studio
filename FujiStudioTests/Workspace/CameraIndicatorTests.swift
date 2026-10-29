@testable import FujiCameraCore
import Testing
@testable import FujiStudio

private let indicatorSession = CameraSession(generation: 1,
    connection: CameraConnection(name: "X-T5", usbVendorID: 0, usbProductID: 0))

struct CameraIndicatorTests {
    @Test(arguments: [false, true])
    func cameraAttentionRemainsAnErrorDuringRecipeImport(_ refreshing: Bool) {
        let state = CameraIndicatorState(camera: .attentionRequired(indicatorSession, message: "Unexpected photo dimensions"), refreshingRecipes: refreshing)
        #expect(state.rawValue == "Camera error")
    }

    @Test(arguments: [CameraState.ready(indicatorSession), .busy(indicatorSession)])
    func connectedSessionStaysPreparingUntilRecipeImportFinishes(_ camera: CameraState) {
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: true) == .preparing)
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: false) == .ready)
    }

    @Test(arguments: [CameraState.disconnected,
        .authorizationRequired, .authorizationDenied, .wrongMode("USB mode"), .recoverableError(.notConnected)])
    func unavailableCameraOverridesAnUnfinishedRecipeImport(_ camera: CameraState) {
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: true) == .disconnected)
        #expect(CameraIndicatorState(camera: camera, refreshingRecipes: false) == .disconnected)
    }
    @Test(arguments:[CameraState.opening,.discovering,.sessionOpen(indicatorSession)])
    func ownedReopenStaysPreparingWhileImportOwnsSession(_ camera:CameraState) {
        #expect(CameraIndicatorState(camera:camera,refreshingRecipes:true) == .preparing)
        #expect(CameraIndicatorState(camera:camera,refreshingRecipes:false) == .disconnected)
    }
}
