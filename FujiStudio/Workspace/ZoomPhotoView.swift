import SwiftUI
import UIKit
import ImageIO

@MainActor
final class ZoomControl {
    fileprivate var inspection: ZoomInspection?
    func forgetOtherSource(_ sourceID: SourceID) {
        if inspection?.sourceID != sourceID { inspection = nil }
    }
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var fit: (() -> Void)?
}

private struct ZoomInspection {
    let sourceID: SourceID
    let geometry: ImageGeometry
    let center: CGPoint
    let magnification: CGFloat
}

struct ZoomPhotoView: UIViewRepresentable {
    typealias DetailProvider = @Sendable (_ topLeftRegion: CGRect, _ maximumDimension: Int) async throws -> DisplayFileLease
    let sourceID: SourceID
    let version: VersionID
    let imageURL: URL
    let geometry: ImageGeometry
    var displayFile: DisplayFileLease? = nil
    var detail: DetailProvider? = nil
    var control: ZoomControl? = nil

    func makeUIView(context: Context) -> InspectionScrollView {
        let view = InspectionScrollView()
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: InspectionScrollView, context: Context) {
        context.coordinator.update(self)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: InspectionScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        private weak var scroll: InspectionScrollView?
        private let canvas = UIView()
        private let image = UIImageView()
        private let detailImage = UIImageView()
        private var input: ZoomPhotoView?
        private var load: Task<Void, Never>?
        private var detailTask: Task<Void, Never>?
        private var ownedFile: DisplayFileLease?
        private var ownedDetail: DisplayFileLease?
        private let jpegRenderer = JPEGDetailRenderer()
        private var generation: UInt64 = 0
        private var detailGeneration: UInt64 = 0
        private var changingLayout = false
        private var viewport = CGSize.zero
        private var center = CGPoint(x: 0.5, y: 0.5)
        private var magnification: CGFloat = 1

        func attach(_ scroll: InspectionScrollView) {
            self.scroll = scroll
            scroll.delegate = self
            scroll.backgroundColor = .black
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
            scroll.bouncesZoom = false; scroll.bounces = false
            canvas.addSubview(image); canvas.addSubview(detailImage); scroll.addSubview(canvas)
            image.contentMode = .scaleToFill; detailImage.contentMode = .scaleToFill
            image.isAccessibilityElement = false; detailImage.isAccessibilityElement = false
            scroll.isAccessibilityElement = true
            scroll.accessibilityIdentifier = "viewer.image"
            scroll.accessibilityLabel = "Photo, pinch to zoom and drag to inspect"
            scroll.accessibilityTraits = [.adjustable]
            scroll.onLayout = { [weak self] in self?.layout() }
            scroll.increment = { [weak self] in self?.step(2) }
            scroll.decrement = { [weak self] in self?.step(0.5) }
            scroll.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Fit photo", actionHandler: { [weak self] _ in self?.setZoom(1); return true }),
                UIAccessibilityCustomAction(name: "Inspect left", actionHandler: { [weak self] _ in self?.pan(dx: -0.15, dy: 0); return true }),
                UIAccessibilityCustomAction(name: "Inspect right", actionHandler: { [weak self] _ in self?.pan(dx: 0.15, dy: 0); return true }),
                UIAccessibilityCustomAction(name: "Inspect up", actionHandler: { [weak self] _ in self?.pan(dx: 0, dy: -0.15); return true }),
                UIAccessibilityCustomAction(name: "Inspect down", actionHandler: { [weak self] _ in self?.pan(dx: 0, dy: 0.15); return true })]
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        }

        func update(_ next: ZoomPhotoView) {
            next.control?.zoomIn = { [weak self] in self?.step(2) }
            next.control?.zoomOut = { [weak self] in self?.step(0.5) }
            next.control?.fit = { [weak self] in self?.setZoom(1) }
            let previous = input
            input = next
            guard previous?.sourceID != next.sourceID || previous?.version != next.version || previous?.imageURL != next.imageURL || previous?.geometry != next.geometry else { return }
            let preserve = previous?.sourceID == next.sourceID && previous?.geometry.matchesInspection(next.geometry) == true
            generation &+= 1; let token = generation
            load?.cancel(); cancelDetail()
            ownedFile = nil; image.image = nil
            if !preserve {
                if previous == nil, let retained = next.control?.inspection, retained.sourceID == next.sourceID,
                   retained.geometry.matchesInspection(next.geometry) {
                    center = retained.center; magnification = retained.magnification
                } else { center = CGPoint(x: 0.5, y: 0.5); magnification = 1 }
            }
            layout(force: true)
            load = Task { [weak self] in
                do {
                    // The supplied lease is captured through the asynchronous copy/decode boundary.
                    let supplied = next.displayFile
                    let file = try await Task.detached {
                        if let supplied { return supplied }
                        return try DisplayFileLease.copy(from: next.imageURL)
                    }.value
                    let pixels = try await Task.detached { try DecodedViewerImage.read(file.fileURL, maximumDimension: 2048) }.value
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.ownedFile = file; self.image.image = UIImage(cgImage: pixels.image)
                    self.scroll?.accessibilityLabel = "Photo, pinch to zoom and drag to inspect"
                    self.requestDetail()
                } catch {
                    guard let self, self.generation == token else { return }
                    self.scroll?.accessibilityLabel = "Image unavailable: \(error.localizedDescription)"
                }
            }
        }

        private func layout(force: Bool = false) {
            guard let scroll, let input, scroll.bounds.width > 0, scroll.bounds.height > 0,
                  force || scroll.bounds.size != viewport else { return }
            changingLayout = true
            viewport = scroll.bounds.size
            let size = CGSize(width: input.geometry.upright.width, height: input.geometry.upright.height)
            let fit = min(viewport.width / size.width, viewport.height / size.height)
            scroll.minimumZoomScale = min(fit, scroll.minimumZoomScale)
            scroll.maximumZoomScale = max(fit * 8, scroll.maximumZoomScale)
            scroll.zoomScale = 1
            canvas.transform = .identity; canvas.frame = CGRect(origin: .zero, size: size)
            image.frame = canvas.bounds
            scroll.contentSize = size
            scroll.minimumZoomScale = fit; scroll.maximumZoomScale = fit * 8
            scroll.zoomScale = fit * magnification
            centerContent()
            restoreCenter()
            changingLayout = false
            measure()
            requestDetail()
        }
        private func centerContent() {
            guard let scroll else { return }
            scroll.contentInset = UIEdgeInsets(top: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2), left: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2), bottom: 0, right: 0)
        }
        private func restoreCenter() {
            guard let scroll else { return }
            let x = center.x * scroll.contentSize.width - scroll.bounds.width / 2
            let y = center.y * scroll.contentSize.height - scroll.bounds.height / 2
            scroll.contentOffset = CGPoint(x: min(max(x, -scroll.contentInset.left), max(-scroll.contentInset.left, scroll.contentSize.width - scroll.bounds.width)),
                y: min(max(y, -scroll.contentInset.top), max(-scroll.contentInset.top, scroll.contentSize.height - scroll.bounds.height)))
        }
        private func measure() {
            guard !changingLayout, let scroll, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
            magnification = scroll.zoomScale / scroll.minimumZoomScale
            center = CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width,
                             y: (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height)
            if let input {
                input.control?.inspection = ZoomInspection(sourceID: input.sourceID, geometry: input.geometry,
                    center: center, magnification: magnification)
            }
            #if DEBUG
            scroll.accessibilityValue = String(format: "%.5f,%.5f,%.5f,%.5f,%.5f", magnification, center.x, center.y, scroll.bounds.width, scroll.bounds.height)
            #else
            scroll.accessibilityValue = String(format: "%.1f times fit", magnification)
            #endif
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { guard !changingLayout else { return }; centerContent(); measure() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { measure() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { measure(); requestDetail() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { requestDetail() } }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { requestDetail() }
        private func step(_ factor: CGFloat) { setZoom(magnification * factor) }
        private func setZoom(_ amount: CGFloat) {
            guard let scroll else { return }
            changingLayout = true
            magnification = min(8, max(1, amount))
            scroll.zoomScale = scroll.minimumZoomScale * magnification
            centerContent(); restoreCenter(); changingLayout = false; measure(); requestDetail()
        }
        private func pan(dx: CGFloat, dy: CGFloat) { center.x += dx / magnification; center.y += dy / magnification; restoreCenter(); measure(); requestDetail() }
        @objc private func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll else { return }
            if magnification > 1.01 { setZoom(1); return }
            let point = recognizer.location(in: canvas), scale = scroll.minimumZoomScale * 2
            scroll.zoom(to: CGRect(x: point.x - scroll.bounds.width / scale / 2, y: point.y - scroll.bounds.height / scale / 2,
                                  width: scroll.bounds.width / scale, height: scroll.bounds.height / scale), animated: false)
            measure(); requestDetail()
        }
        private func cancelDetail() {
            detailGeneration &+= 1; detailTask?.cancel(); detailTask = nil
            detailImage.image = nil; ownedDetail = nil
        }
        private func requestDetail() {
            guard !changingLayout else { return }
            cancelDetail()
            guard magnification > 1.01, let scroll, let file = ownedFile, let input else { return }
            let rect = CGRect(x: scroll.contentOffset.x / scroll.contentSize.width, y: scroll.contentOffset.y / scroll.contentSize.height,
                width: scroll.bounds.width / scroll.contentSize.width, height: scroll.bounds.height / scroll.contentSize.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isEmpty else { return }
            let token = generation, detailToken = detailGeneration, renderer = jpegRenderer
            let dimension = min(4096, Int(max(scroll.bounds.width, scroll.bounds.height) * scroll.traitCollection.displayScale))
            let provider = input.detail
            // A RAW fit file is never promoted to fake detail. Its injected provider owns the pool lease.
            if input.version == .raw && provider == nil { scroll.accessibilityLabel = "Photo, RAW detail unavailable"; return }
            scroll.accessibilityLabel = "Photo, loading detail"
            detailTask = Task { [weak self] in
                do {
                    let detail: DisplayFileLease
                    if let provider { detail = try await provider(rect, dimension) }
                    else { detail = try await renderer.detail(file: file, topLeftRegion: rect, maximumDimension: dimension) }
                    try Task.checkCancellation()
                    let pixels = try await Task.detached { try DecodedViewerImage.read(detail.fileURL, maximumDimension: dimension) }.value
                    guard !Task.isCancelled, let self, self.generation == token, self.detailGeneration == detailToken else { return }
                    self.ownedDetail = detail
                    self.detailImage.frame = CGRect(x: rect.minX * self.canvas.bounds.width, y: rect.minY * self.canvas.bounds.height,
                        width: rect.width * self.canvas.bounds.width, height: rect.height * self.canvas.bounds.height)
                    self.detailImage.image = UIImage(cgImage: pixels.image)
                    self.scroll?.accessibilityLabel = "Photo, detail loaded"
                } catch {
                    guard !Task.isCancelled, let self, self.generation == token, self.detailGeneration == detailToken else { return }
                    self.scroll?.accessibilityLabel = "Photo, detail unavailable"
                }
            }
        }
        func stop() { load?.cancel(); cancelDetail(); ownedFile = nil; input = nil }
    }
}

@MainActor
final class InspectionScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    var increment: (() -> Void)?
    var decrement: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func accessibilityIncrement() { increment?() }
    override func accessibilityDecrement() { decrement?() }
}

/// CGImage is immutable; decode occurs off the main actor, UIImage stays on the main actor.
private struct DecodedViewerImage: @unchecked Sendable {
    let image: CGImage
    static func read(_ url: URL, maximumDimension: Int) throws -> DecodedViewerImage {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ViewerError.invalidImage }
            return DecodedViewerImage(image: image)
        }
    }
}
