import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct PhotoTrayFilterTests {
    @Test(arguments: [false, true])
    func replacingTheSameCameraSessionKeepsCompatibleCheckedPhotos(attention: Bool) throws {
        let f = try FilterFixture(); var state = f.state()
        for source in [f.one, f.two] {
            state.reduce(.photoFilterAssessed(source, camera: f.camera, result: .compatible))
        }
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        state.reduce(.select); state.reduce(.checkedSourcesReplaced(["one", "two"]))
        let context = CameraExecutionContext(model: f.context.model, firmware: f.context.firmware,
            capability: f.context.capability, supportVersion: f.context.supportVersion,
            sessionIdentity: UUID(), generation: f.context.generation + 1)
        let session = CameraSession(generation: context.generation, connection: f.session.connection)
        state.reduce(.cameraChanged(attention ? .attentionRequired(session, message: "Unexpected output.") : .ready(session), context: context))
        state.reduce(.cameraSupportVerified(context, f.support))
        #expect(state.checkedSourceIDs == ["one", "two"])
        #expect(state.visibleSourceIDs == ["one", "two"])
    }

    @Test func filterIsOptionalAndUnknownPhotosStayHiddenUntilAssessed() throws {
        let f = try FilterFixture()
        var state = f.state()
        #expect(state.photoFilter == .allPhotos)
        #expect(state.visibleSourceIDs == ["one", "two"])
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        #expect(state.photoFilterCamera?.model == "X-T5")
        #expect(state.visibleSourceIDs.isEmpty)
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        #expect(state.visibleSourceIDs == ["one"])
        #expect(state.photoFilterPendingCount == 1)
        state.reduce(.photoFilterAssessed(f.two, camera: f.camera, result: .unavailable))
        #expect(state.photoFilterPendingCount == 0)
        #expect(state.photoFilterUnavailableCount == 1)
        state.reduce(.photoFilterSelected(.allPhotos))
        #expect(state.visibleSourceIDs == ["one", "two"])
    }

    @Test func filteringPrunesHiddenChecksPreservesViewerAndBlocksStaleRangeCallbacks() throws {
        let f = try FilterFixture(); var state = f.state()
        state.reduce(.sourceTapped("two")); let version = state.displayedVersion
        state.reduce(.select); state.reduce(.checkedSourcesReplaced(["one", "two"]))
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        #expect(state.checkedSourceIDs == ["one"])
        #expect(state.viewedSourceID == "two")
        #expect(state.displayedVersion == version)
        state.reduce(.checkedSourcesReplaced(["one", "two"]))
        #expect(state.checkedSourceIDs == ["one"])
        state.reduce(.sourceTapped("two"))
        #expect(state.checkedSourceIDs == ["one"])
        state.reduce(.done); state.reduce(.select)
        #expect(state.checkedSourceIDs.isEmpty)
    }

    @Test func assessmentsRejectWrongCameraAndOldOriginalRevisions() throws {
        let f = try FilterFixture(); var state = f.state()
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        let other = try fixtureCameraSupport(fixtureCollection([try fixtureXE3Recipe()], slots: [.init(id: 4, label: "C4")]).context)
        state.reduce(.photoFilterAssessed(f.one, camera: PhotoTrayFilterCamera(other), result: .compatible))
        #expect(state.visibleSourceIDs.isEmpty)
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        let revised = f.source("one", revision: "v2")
        state.reduce(.libraryUpdated(sources: [revised, f.two], access: .limited))
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        #expect(state.visibleSourceIDs.isEmpty)
        #expect(state.photoFilterPendingCount == 2)
        state.reduce(.photoFilterAssessed(revised, camera: f.camera, result: .compatible))
        #expect(state.visibleSourceIDs == ["one"])
    }

    @Test func switchingCamerasChangesOptionAndDisconnectDoesNotReenableOnReconnect() throws {
        let f = try FilterFixture(); var state = f.state()
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        let receipt = fixtureCollection([try fixtureXE3Recipe()], slots: [.init(id: 4, label: "C4")])
        let session = CameraSession(generation: receipt.context.generation, connection: f.session.connection)
        state.reduce(.cameraChanged(.ready(session), context: receipt.context))
        state.reduce(.cameraSupportVerified(receipt.context, receipt.support))
        #expect(state.photoFilter == .compatibleWithCamera)
        #expect(state.photoFilterCamera?.model == "X-E3")
        #expect(state.visibleSourceIDs.isEmpty)
        state.reduce(.photoFilterAssessed(f.one, camera: f.camera, result: .compatible))
        #expect(state.visibleSourceIDs.isEmpty)
        state.reduce(.cameraChanged(.busy(session), context: receipt.context))
        #expect(state.photoFilterCamera?.model == "X-E3")
        state.reduce(.cameraChanged(.disconnected, context: nil))
        #expect(state.photoFilter == .allPhotos)
        #expect(state.visibleSourceIDs == ["one", "two"])
        state.reduce(.cameraChanged(.ready(session), context: receipt.context))
        state.reduce(.cameraSupportVerified(receipt.context, receipt.support))
        #expect(state.photoFilter == .allPhotos)
    }

    @Test func unverifiedCameraCannotEnableFilter() throws {
        let f = try FilterFixture(); var state = WorkspaceState(sources: [f.one], access: .full)
        state.reduce(.photoFilterSelected(.compatibleWithCamera))
        #expect(state.photoFilter == .allPhotos)
    }
}

private struct FilterFixture {
    let context: CameraExecutionContext
    let support: VerifiedCameraSupport
    let session = CameraSession(generation: 1, connection: .init(name: "Filter fixture", usbVendorID: 0, usbProductID: 0))
    init() throws { context = try RenderFixture().context; support = try fixtureCameraSupport(context) }
    var camera: PhotoTrayFilterCamera { PhotoTrayFilterCamera(support) }
    var one: PhotoSource { source("one") }
    var two: PhotoSource { source("two") }
    func source(_ id: String, revision: String = "v1") -> PhotoSource {
        PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
            contentTypeIdentifier: "com.fuji.raw-image", format: .raf, originalFilename: "test.RAF",
            discriminator: "raw", sourceRevision: revision)), resourceRevision: revision)
    }
    func state() -> WorkspaceState {
        var state = WorkspaceState(sources: [one, two], access: .full)
        state.reduce(.cameraChanged(.ready(session), context: context))
        state.reduce(.cameraSupportVerified(context, support))
        return state
    }
}
