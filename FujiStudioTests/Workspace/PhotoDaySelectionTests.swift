import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct PhotoDaySelectionTests {
    private func source(_ id: String) -> PhotoSource {
        PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
            contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED.RAF", discriminator: "raw"),
            jpeg: nil), captureDate: nil, location: nil, resourceRevision: "fixture")
    }

    @Test func dayCheckboxStartsSelectionWithoutSelectingViewedPhotoOrChangingPreview() {
        var state = WorkspaceState(sources: [source("viewed"), source("a"), source("b")], access: .full)
        state.reduce(.sourceTapped("viewed"))
        let version = state.displayedVersion
        #expect(state.reduce(.daySelectionToggled(["a", "b", "missing"])).isEmpty)
        #expect(state.isSelecting)
        #expect(state.checkedSourceIDs == ["a", "b"])
        #expect(state.viewedSourceID == "viewed")
        #expect(state.displayedVersion == version)
    }

    @Test func partialDaySelectsRemainingPhotosAndFullDayDeselectsOnlyThatDay() {
        var state = WorkspaceState(sources: [source("other-day"), source("a"), source("b")], access: .full)
        state.reduce(.select)
        state.reduce(.checkedSourcesReplaced(["other-day", "a"]))
        state.reduce(.daySelectionToggled(["a", "b"]))
        #expect(state.checkedSourceIDs == ["other-day", "a", "b"])
        state.reduce(.daySelectionToggled(["a", "b"]))
        #expect(state.checkedSourceIDs == ["other-day"])
        #expect(state.isSelecting)
    }

    @Test func unavailableDayDoesNotStartSelection() {
        var state = WorkspaceState(sources: [source("a")], access: .full)
        state.reduce(.daySelectionToggled(["removed"]))
        #expect(!state.isSelecting)
        #expect(state.checkedSourceIDs.isEmpty)
    }
}
