import Foundation
import UIKit
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct ThumbnailRefreshTests {
    @Test func editedAssetRefreshesExistingCellAndRejectsAnEarlierImage() throws {
        let loader = RefreshThumbnailLoader(), provider = ThumbnailProvider(loader: loader)
        let a = imageView("a", provider: provider), b = imageView("b", provider: provider)
        defer { provider.cancel(a.request); provider.cancel(b.request) }
        let red = image(.red), green = image(.green), blue = image(.blue)
        loader.deliver(0, red); loader.deliver(1, green)
        #expect(a.view.image === red)
        #expect(b.view.image === green)

        provider.invalidate(sourceIDs: ["a"])
        #expect(loader.requests.map(\.sourceID) == ["a", "b", "a"])
        #expect(loader.invalidated == [["a"]])
        guard loader.requests.count == 3 else { return }
        loader.deliver(2, blue)
        loader.deliver(0, red) // A canceled PhotoKit callback can still arrive later.
        #expect(a.view.image === blue)
        #expect(b.view.image === green)
    }

    @Test func invalidationDoesNotRestartCancelledOrUnrelatedRequests() {
        let loader = RefreshThumbnailLoader(), provider = ThumbnailProvider(loader: loader)
        var received = 0
        let token = provider.request(sourceID: "a", pixelSize: .init(width: 100, height: 100)) { _ in received += 1 }
        provider.cancel(token)
        provider.invalidate(sourceIDs: ["a", "offscreen"])
        loader.deliver(0, image(.red))
        #expect(loader.requests.count == 1)
        #expect(received == 0)
        #expect(loader.invalidated == [["a", "offscreen"]])
    }

    @Test func immediateDeliveryCannotReplaceTheHandleForANewerRefresh() {
        let loader = RefreshThumbnailLoader(), provider = ThumbnailProvider(loader: loader)
        let red = image(.red), blue = image(.blue)
        loader.immediate = red
        var received: [UIImage?] = []
        let token = provider.request(sourceID: "a", pixelSize: .init(width: 100, height: 100)) { result in
            received.append(result)
            if received.count == 1 { provider.invalidate(sourceIDs: ["a"]) }
        }
        defer { provider.cancel(token) }
        #expect(loader.requests.count == 2)
        guard loader.requests.count == 2 else { return }
        loader.deliver(1, blue); loader.deliver(0, red)
        #expect(received.count == 2)
        #expect(received.last.flatMap { $0 } === blue)
        provider.cancel(token)
        #expect(loader.cancelled == Set(loader.requests.map(\.id)))
    }

    @Test func photosEditNotificationRefreshesTheTrayWithoutChangingRAWIdentity() async throws {
        let f = try await FixtureEnvironment.make(), original = f.environment
        let loader = RefreshThumbnailLoader(), provider = ThumbnailProvider(loader: loader)
        let environment = AppEnvironment(reader: original.reader, camera: original.camera, catalog: original.catalog,
            originals: original.originals, preview: original.preview, resolver: original.resolver,
            exports: original.exports, cache: original.cache, thumbnails: provider, platform: original.platform)
        let model = AppModel(environment: environment)
        await model.start(automaticallyConnect: false)
        model.send(.sourceTapped("source-0"))
        let source = try #require(model.sources.first { $0.id == "source-0" })
        let thumbnail = imageView(source.id, provider: provider)
        defer { provider.cancel(thumbnail.request) }
        let red = image(.red), blue = image(.blue)
        loader.deliver(0, red)
        let recipe = try #require(model.state.recipes.first)
        await f.reader.addOriginalEdit(.init(operationID: UUID(), sourceID: source.id, recipe: recipe))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while loader.requests.count == 1 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loader.requests.count == 2)
        guard loader.requests.count == 2 else { return }
        loader.deliver(1, blue)
        #expect(thumbnail.view.image === blue)
        #expect(model.sources.first { $0.id == source.id }?.resourceRevision == source.resourceRevision)
        #expect(model.state.viewedSourceID == source.id)
    }

    private func imageView(_ id: String, provider: ThumbnailProvider) -> (view: UIImageView, request: UUID) {
        let view = UIImageView()
        let request = provider.request(sourceID: id, pixelSize: .init(width: 100, height: 100)) { view.image = $0 }
        return (view, request)
    }
    
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { context in
            color.setFill(); context.fill(.init(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

@MainActor final class RefreshThumbnailLoader: ThumbnailImageLoading {
    struct Request {
        let id: UUID
        let sourceID: SourceID
        let completion: @MainActor (UIImage?) -> Void
    }
    var requests: [Request] = []
    var invalidated: [Set<SourceID>] = []
    var cancelled: Set<UUID> = []
    var immediate: UIImage?
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let id = UUID(); requests.append(.init(id: id, sourceID: sourceID, completion: completion))
        if let image = immediate { immediate = nil; completion(image) }
        return id
    }
    func cancel(_ id: UUID) { cancelled.insert(id) }
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {}
    func invalidate(sourceIDs: Set<SourceID>) { invalidated.append(sourceIDs) }
    func deliver(_ index: Int, _ image: UIImage?) { requests[index].completion(image) }
}
