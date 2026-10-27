import XCTest
import UIKit
@testable import FujiStudio

@MainActor
final class PhotoGridControllerTests: XCTestCase {
    private func source(_ id: String) -> PhotoSource {
        PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED.RAF", discriminator: "raw"), jpeg: nil), captureDate: nil, location: nil, resourceRevision: "fixture")
    }
    private func host(_ controller: PhotoGridController, height: CGFloat = 400) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return window
    }
    func testRecognizerStatePathReversesAndCancelsWithoutChangingViewedSource() {
        let provider = GridThumbnailSpy(), controller = PhotoGridController(thumbnails: provider)
        let sources = (0..<1000).map { source("source-\($0)") }
        var changes: [Set<SourceID>] = []; var taps: [SourceID] = []
        controller.onCheckedChanged = { changes.append($0) }; controller.onSourceTapped = { taps.append($0) }
        controller.update(sources: sources, checked: ["source-0", "source-1", "source-2", "source-8"], selecting: true, viewed: "source-8", scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        controller.handleSweep(state: .began, viewportLocation: CGPoint(x: 25, y: 25), translation: .zero)
        controller.handleSweep(state: .changed, viewportLocation: CGPoint(x: 300, y: 25), translation: .zero)
        XCTAssertEqual(changes.last, ["source-8"])
        controller.handleSweep(state: .changed, viewportLocation: CGPoint(x: 160, y: 25), translation: .zero)
        XCTAssertEqual(changes.last, ["source-2", "source-8"])
        controller.handleSweep(state: .cancelled, viewportLocation: CGPoint(x: 160, y: 25), translation: .zero)
        XCTAssertEqual(changes.last, ["source-0", "source-1", "source-2", "source-8"])
        XCTAssertTrue(taps.isEmpty)
        XCTAssertEqual(controller.collectionView.cellForItem(at: IndexPath(item: 8, section: 0))?.accessibilityValue, "Checked")
    }
    func testSourceAnchorsSurviveInsertionsAndRemovalAndFinalViewportRevealsMinimum() {
        let controller = PhotoGridController(thumbnails: GridThumbnailSpy())
        let sources = (0..<1000).map { source("source-\($0)") }
        controller.update(sources: sources, checked: [], selecting: false, viewed: "source-20", scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        controller.collectionView.contentOffset.y = 600
        controller.collectionView.layoutIfNeeded()
        let before = controller.collectionView.indexPathsForVisibleItems.sorted().first!
        let anchor = sources[before.item].id
        let delta = controller.collectionView.contentOffset.y - controller.metrics.rect(index: before.item).minY
        let inserted = [source("new-a"), source("new-b"), source("new-c")] + sources
        controller.update(sources: inserted, checked: [], selecting: true, viewed: "source-20", scrollRequest: nil)
        XCTAssertEqual(controller.collectionView.contentOffset.y - controller.metrics.rect(index: before.item + 3).minY, delta, accuracy: 0.01)
        let narrowed = inserted.filter { $0.id != anchor }
        controller.update(sources: narrowed, checked: [], selecting: true, viewed: "source-20", scrollRequest: nil)
        let nextID = sources[before.item + 1].id
        let nextIndex = narrowed.firstIndex { $0.id == nextID }!
        XCTAssertEqual(controller.collectionView.contentOffset.y - controller.metrics.rect(index: nextIndex).minY, delta, accuracy: 0.01)
        let request = GridScrollRequest(sourceID: "source-20", afterViewportHeight: 200)
        controller.update(sources: narrowed, checked: [], selecting: true, viewed: "source-20", scrollRequest: request)
        let expandedOffset = controller.collectionView.contentOffset.y
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.collectionView.contentOffset.y, expandedOffset)
        controller.view.frame.size.height = 200; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let rect = controller.metrics.rect(index: narrowed.firstIndex { $0.id == "source-20" }!)
        XCTAssertEqual(controller.collectionView.contentOffset.y, rect.maxY - 200, accuracy: 0.01)
    }
    func testViewportRelayoutCancelsSweepAndRestoresStartingChecks() {
        let controller = PhotoGridController(thumbnails: GridThumbnailSpy())
        let sources = (0..<120).map { source("source-\($0)") }
        var changes: [Set<SourceID>] = []
        controller.onCheckedChanged = { changes.append($0) }
        controller.update(sources: sources, checked: ["source-8"], selecting: true, viewed: "source-8", scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        controller.handleSweep(state: .began, viewportLocation: CGPoint(x: 25, y: 25), translation: .zero)
        XCTAssertEqual(changes.last, ["source-0", "source-8"])
        controller.view.frame.size.height = 300; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(changes.last, ["source-8"])
        controller.handleSweep(state: .changed, viewportLocation: CGPoint(x: 300, y: 25), translation: .zero)
        XCTAssertEqual(changes.last, ["source-8"])
    }
    func testOverriddenMetricsUseFinalViewportForMinimumRevealAndKeepChecks() {
        let controller = PhotoGridController(thumbnails: GridThumbnailSpy())
        let sources = (0..<120).map { source("source-\($0)") }
        let small = GridMetrics(columns: 6, tileWidth: 59.8333333333, spacing: 3,
            insets: .init(top: 8, left: 8, bottom: 8, right: 8))
        controller.update(sources: sources, checked: ["source-0", "source-20"], selecting: true, viewed: "source-20", scrollRequest: nil, gridMetrics: small)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        XCTAssertEqual(controller.metrics.columns, 6)
        let request = GridScrollRequest(sourceID: "source-20", afterViewportHeight: 138.6666666666)
        controller.update(sources: sources, checked: ["source-0", "source-20"], selecting: true, viewed: "source-20", scrollRequest: request, gridMetrics: small)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.collectionView.contentOffset.y, 0)
        controller.view.frame.size.height = 138.6666666666; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        // Row 3 begins at 196.5; its bottom is 256.3333. Reveal by exactly 117.6667.
        XCTAssertEqual(controller.collectionView.contentOffset.y, 117.6666666666, accuracy: 0.01)
        XCTAssertEqual(controller.collectionView.cellForItem(at: IndexPath(item: 20, section: 0))?.accessibilityValue, "Checked")
        controller.collectionView.contentOffset.y = 0; controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))?.accessibilityValue, "Checked")
    }
    func testLargestNativeTextBadgeStaysInsideSquareAndKeepsSpokenKind() {
        let controller = PhotoGridController(thumbnails: GridThumbnailSpy())
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let raw = source("badge")
        let paired = PhotoSource(id: raw.id, originalResources: .init(raf: raw.originalResources.raf,
            jpeg: .init(assetID: raw.id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg,
                originalFilename: "GENERATED.JPG", discriminator: "jpeg")), captureDate: nil, location: nil, resourceRevision: "fixture")
        controller.update(sources: [paired], checked: [], selecting: false, viewed: "badge", scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        let cell = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))!
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        let badge = cell.contentView.subviews.compactMap { $0 as? UILabel }.first { $0.text == "RAW + JPEG" }!
        XCTAssertTrue(cell.contentView.bounds.contains(badge.frame), "Decorative badge must not spill into another row")
        XCTAssertTrue(cell.accessibilityLabel!.contains("RAW + JPEG"))
        XCTAssertEqual(cell.bounds.width, cell.bounds.height, accuracy: 0.01)
    }
    func testReuseCancelsAndLateCallbackCannotReplaceNewSourceImage() {
        let provider = GridThumbnailSpy(), controller = PhotoGridController(thumbnails: provider)
        controller.update(sources: [source("old")], checked: [], selecting: false, viewed: nil, scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        let oldToken = provider.requests.last!.token
        controller.update(sources: [source("new")], checked: [], selecting: false, viewed: nil, scrollRequest: nil)
        controller.view.layoutIfNeeded()
        let stale = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        provider.requests.first { $0.token == oldToken }!.completion(stale)
        XCTAssertTrue(provider.cancelled.contains(oldToken))
        let cell = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))!
        XCTAssertEqual(cell.accessibilityIdentifier, "grid.new")
        XCTAssertFalse((cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image) === stale)
    }
    func testScrollingPrunesPrefetchOutsideNearbyViewport() {
        let provider = GridThumbnailSpy(), controller = PhotoGridController(thumbnails: provider)
        controller.update(sources: (0..<1000).map { source("source-\($0)") }, checked: [], selecting: false, viewed: nil, scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        controller.collectionView(controller.collectionView, prefetchItemsAt: [IndexPath(item: 15, section: 0)])
        controller.collectionView.contentOffset.y = 4000
        controller.view.layoutIfNeeded()
        XCTAssertFalse(provider.cached.contains("source-15"))
        XCTAssertLessThanOrEqual(provider.cached.count, 120)
    }
    func testReturningRestartsVisibleRequestsAndRejectsEarlierRequestForSameSource() {
        let provider = GridThumbnailSpy(), controller = PhotoGridController(thumbnails: provider)
        controller.update(sources: [source("same")], checked: [], selecting: false, viewed: nil, scrollRequest: nil)
        let window = host(controller); defer { controller.stop(); window.isHidden = true }
        let earlier = provider.requests.last!, count = provider.requests.count
        controller.viewWillDisappear(false)
        XCTAssertTrue(provider.cancelled.contains(earlier.token))
        controller.viewDidAppear(false)
        XCTAssertGreaterThan(provider.requests.count, count)
        let stale = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        earlier.completion(stale)
        let cell = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))!
        XCTAssertFalse((cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image) === stale)
    }
}

@MainActor
private final class GridThumbnailSpy: GridThumbnailProviding {
    struct Request { let token: UUID; let completion: @MainActor (UIImage?) -> Void }
    var requests: [Request] = []
    var cancelled: Set<UUID> = []
    var cached: [SourceID] = []
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let token = UUID(); requests.append(Request(token: token, completion: completion)); return token
    }
    func cancel(_ token: UUID) { cancelled.insert(token) }
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) { cached = sourceIDs }
}
