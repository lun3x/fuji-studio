import Testing
import SwiftUI
@testable import FujiStudio

struct DrawerGeometryTests {
    // Omitting the header/safe area or using a prototype drawer height breaks the actual two-row viewport.
    @Test func collapsedViewportContainsExactlyTwoCompleteRows() {
        let grid = GridGeometry.metrics(width: 390)
        let result = DrawerGeometry.detents(container: CGSize(width: 390, height: 844),
            safeArea: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), headerHeight: 88,
            grid: grid, recipeControlFrame: CGRect(x: 16, y: 120, width: 70, height: 44))
        #expect(abs(result.collapsedGridHeight - 264.3333333333) < 0.001)
        #expect(abs(result.collapsedHeight - 386.3333333333) < 0.001)
        #expect(result.expandedTop == 172)
        #expect(result.expandedHeight == 672)
        #expect(result.height(for: .collapsed) == result.collapsedHeight)
        #expect(result.height(for: .expanded) == result.expandedHeight)
    }
    @Test func adaptiveLandscapeRowsClearMeasuredControlsAndHeader() {
        let grid = DrawerGeometry.gridMetrics(width: 800, availableTwoRowHeight: 117)
        // 16 pt insets + 3 gap leaves 98 pt / 2 = 49 pt squares; 16 columns fit.
        #expect(grid.columns == 16)
        #expect(grid.tileWidth == 46.1875)
        #expect(grid.height(rows: 2) == 111.375)
        let result = DrawerGeometry.detents(container: CGSize(width: 800, height: 390),
            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 21, trailing: 0), headerHeight: 100,
            grid: grid, recipeControlFrame: CGRect(x: 16, y: 100, width: 80, height: 44))
        #expect(result.expandedTop >= 152)
        #expect(result.collapsedHeight == 232.375)
        #expect(result.expandedHeight >= result.collapsedHeight)
    }
    @Test func dragClampsAndSnapsWithoutDependingOnPhotoSelection() {
        let result = DrawerGeometry.detents(container: CGSize(width: 390, height: 844), safeArea: .init(),
            headerHeight: 70, grid: GridGeometry.metrics(width: 390), recipeControlFrame: CGRect(x: 0, y: 80, width: 80, height: 44))
        #expect(result.clampedHeight(0) == result.collapsedHeight)
        #expect(result.clampedHeight(10000) == result.expandedHeight)
        #expect(result.destination(height: result.collapsedHeight + 5, predictedTranslation: -500) == .expanded)
        #expect(result.destination(height: result.expandedHeight - 5, predictedTranslation: 500) == .collapsed)
    }
}

import XCTest
import Observation

@MainActor
final class WorkspaceHostingTests: XCTestCase {
    func testGridControllerIdentityAndActualTwoRowsSurviveModesDetentsAndLandscapeLargeText() async throws {
        let store = WorkspaceHostingStore()
        let root = WorkspaceHostingHarness(store: store)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 800, height: 390)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 800, height: 390)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; priorKeyWindow?.makeKeyAndVisible() }
        try await settle(host)
        let grid = try XCTUnwrap(descendants(host).compactMap { $0 as? PhotoGridController }.first)
        let tile = try XCTUnwrap(grid.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let side = tile.frame.width
        XCTAssertEqual(grid.collectionView.bounds.height, side * 2 + 19, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(side, 44)
        let initialSize = grid.collectionView.bounds.size
        store.state.reduce(.select)
        try await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === grid })
        XCTAssertEqual(grid.collectionView.bounds.size, initialSize)
        store.state.reduce(.drawerMoved(.expanded))
        try await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === grid })
        XCTAssertEqual(grid.metrics.tileWidth, side, accuracy: 0.01)
        store.state.reduce(.sourceTapped("source-1"))
        try await settle(host)
        XCTAssertEqual(store.state.drawerDetent, .expanded)
        XCTAssertEqual(store.state.checkedSourceIDs, ["source-0", "source-1"])
        store.state.reduce(.drawerMoved(.collapsed)); store.state.reduce(.done)
        try await settle(host)
        XCTAssertTrue(descendants(host).contains { $0 === grid })
        XCTAssertEqual(grid.collectionView.bounds.size, initialSize)
    }
    func testLiveCompositionRetainsViewerAndGridInstancesAcrossAXSelectionAndDrawer() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); model.send(.sourceTapped("source-0"))
        for _ in 0..<100 where model.displayFile == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.displayFile)
        let host = UIHostingController(rootView: AppWorkspaceView(model: model)
            .environment(\.dynamicTypeSize, .accessibility5).frame(width: 382, height: 710))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; priorKeyWindow?.makeKeyAndVisible() }
        try await settle(host)
        let grid = try XCTUnwrap(descendants(host).compactMap { $0 as? PhotoGridController }.first)
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let viewer = try XCTUnwrap(views(host.view).first { $0.accessibilityIdentifier == "viewer.image" } as? UIScrollView)
        let frame = viewer.convert(viewer.bounds, to: host.view), side = grid.metrics.tileWidth
        XCTAssertGreaterThanOrEqual(side, 44)
        XCTAssertEqual(grid.collectionView.bounds.height, 2 * side + 19, accuracy: 0.5)
        for action: WorkspaceAction in [.select, .drawerMoved(.expanded), .drawerMoved(.collapsed), .done] {
            model.send(action); try await settle(host)
            XCTAssertTrue(descendants(host).contains { $0 === grid })
            XCTAssertTrue(views(host.view).contains { $0 === viewer })
            XCTAssertEqual(viewer.convert(viewer.bounds, to: host.view), frame)
            XCTAssertEqual(grid.metrics.tileWidth, side, accuracy: 0.01)
            if model.state.drawerDetent == .collapsed { XCTAssertEqual(grid.collectionView.bounds.height, 2 * side + 19, accuracy: 0.5) }
        }
        let writes = await f.writer.requests
        XCTAssertTrue(writes.isEmpty)
    }

    private func settle(_ host: UIViewController) async throws {
        // A bounded render turn lets SwiftUI apply measured header/recipe preferences to native views.
        for _ in 0..<4 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    private func descendants(_ controller: UIViewController) -> [UIViewController] {
        controller.children.flatMap { [$0] + descendants($0) }
    }
}

@Observable @MainActor
private final class WorkspaceHostingStore {
    let sources: [PhotoSource] = (0..<120).map { index in
        let id = "source-\(index)"
        return PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
            contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED.RAF", discriminator: "raw"), jpeg: nil),
            captureDate: nil, location: nil, resourceRevision: "generated")
    }
    var state: WorkspaceState
    let thumbnails = HostingThumbnails()
    init() {
        state = WorkspaceState(sources: sources, access: .full)
        state.reduce(.sourceTapped("source-0"))
    }
}
private struct WorkspaceHostingHarness: View {
    let store: WorkspaceHostingStore
    var body: some View {
        WorkspaceView(state: store.state, sources: store.sources, thumbnails: store.thumbnails,
            onAction: { store.state.reduce($0) }, onRefreshRecipes: {}, onExport: {})
    }
}
@MainActor private final class HostingThumbnails: GridThumbnailProviding {
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID { completion(nil); return UUID() }
    func cancel(_ token: UUID) {}
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {}
}

@MainActor
final class RecipeMenuRoutingTests: XCTestCase {
    /// Public responder/action routing only; this does not prove delivery from physical keyboard hardware.
    func testNativeEscapeActionDismissesWithoutSelectionAndReleasesResponderAcrossPresentations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        defer { priorKeyWindow?.makeKeyAndVisible() }
        let store = RecipeRoutingStore()
        let selected = store.state.selectedRecipe?.id
        let first = try await routePresentation(store: store, scene: scene)
        assertInactive(first)
        XCTAssertEqual(store.state.selectedRecipe?.id, selected)
        XCTAssertTrue(store.selections.isEmpty)
        let reopened = try await routePresentation(store: store, scene: scene, lateResponder: first)
        assertInactive(reopened)
        XCTAssertEqual(store.state.selectedRecipe?.id, selected)
        XCTAssertTrue(store.selections.isEmpty)
    }
    private func routePresentation(store: RecipeRoutingStore, scene: UIWindowScene, lateResponder: WeakRecipeResponder? = nil) async throws -> WeakRecipeResponder {
        let menu = RecipeMenu(current: store.state.selectedRecipe, snapshots: store.state.recipes, refreshState: .fresh,
            onSelect: { store.selections.append($0); store.state.reduce(.recipeSelected(slot: $0)) }, onRefresh: {}, initiallyPresented: true)
        let host = UIHostingController(rootView: menu)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { host.presentedViewController?.viewIfLoaded?.window != nil }
        let popup = try XCTUnwrap(host.presentedViewController)
        try await waitUntil { self.views(popup.view).contains(where: \.isFirstResponder) }
        let responder = try XCTUnwrap(views(popup.view).first(where: \.isFirstResponder))
        let command = try XCTUnwrap(responder.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        if let lateResponder {
            if let previous = lateResponder.value {
                let lateAction = try XCTUnwrap(lateResponder.command.action)
                XCTAssertTrue(UIApplication.shared.sendAction(lateAction, to: previous, from: lateResponder.command, for: nil))
                // A late command from the detached first presentation cannot close this presentation.
                XCTAssertTrue(host.presentedViewController === popup)
                XCTAssertTrue(responder.isFirstResponder)
                XCTAssertEqual(store.state.selectedRecipe?.slot, 3)
                XCTAssertTrue(store.selections.isEmpty)
            } else {
                // Deallocation also removes the prior responder's action ownership.
                XCTAssertNil(lateResponder.value)
            }
        }
        let action = try XCTUnwrap(command.action)

        XCTAssertEqual(responder.keyCommands?.count, 1)
        XCTAssertTrue(responder.canPerformAction(action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: responder, from: command, for: nil))
        try await waitUntil { host.presentedViewController == nil }
        XCTAssertFalse(responder.isFirstResponder)
        XCTAssertNil(responder.window)
        XCTAssertEqual(store.state.selectedRecipe?.slot, 3)
        XCTAssertTrue(store.selections.isEmpty)
        return WeakRecipeResponder(responder, command: command)
    }
    private func assertInactive(_ responder: WeakRecipeResponder) {
        // UIKit may retain an inactive view after its owner is released; both outcomes are valid.
        if let view = responder.value {
            XCTAssertFalse(view.isFirstResponder)
            XCTAssertNil(view.window)
            XCTAssertEqual(view.keyCommands?.count, 0)
        } else { XCTAssertNil(responder.value) }
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native popover/responder did not reach its expected lifecycle state")
    }
}
@MainActor private final class WeakRecipeResponder {
    weak var value: UIView?
    let command: UIKeyCommand
    init(_ value: UIView, command: UIKeyCommand) { self.value = value; self.command = command }
}
@MainActor private final class RecipeRoutingStore {
    var state = WorkspaceState()
    var selections: [Int?] = []
    init() {
        let context = RecipeCameraContext(model: "Generated", firmware: "fixture", capability: "fixture", sessionIdentity: UUID(), sessionGeneration: 1)
        let recipes = (1...7).map { slot in
            RecipeSnapshot(id: UUID(), slot: slot, name: "Generated \(slot)", importedName: Data(), importedSettings: [],
                settingsDigest: "generated", cameraContext: context, importedAt: Date(timeIntervalSince1970: 0), renderingIssues: [])
        }
        state.reduce(.recipesRefreshed(recipes)); state.reduce(.recipeSelected(slot: 3))
    }
}
