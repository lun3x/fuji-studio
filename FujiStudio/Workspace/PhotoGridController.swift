import UIKit

@MainActor
final class PhotoGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
    private let layout = UICollectionViewFlowLayout()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, SourceID>!
    private let thumbnails: any GridThumbnailProviding
    private var sources: [PhotoSource] = []
    private var byID: [SourceID: PhotoSource] = [:]
    private var indices: [SourceID: Int] = [:]
    private var checked: Set<SourceID> = []
    private var selecting = false
    private var viewed: SourceID?
    private(set) var metrics = GridGeometry.metrics(width: 1)
    private var prefetched: Set<SourceID> = []
    private var sweep = RangeSelection()
    private var sweeping = false
    private var finger = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var pendingScroll: GridScrollRequest?
    private var lastScrollID: UUID?
    private var lastViewport: GridViewport?
    private lazy var sweepGesture = UIPanGestureRecognizer(target: self, action: #selector(sweepChanged))
    var onSourceTapped: (SourceID) -> Void = { _ in }
    var onCheckedChanged: (Set<SourceID>) -> Void = { _ in }
    var onViewportChanged: (GridViewport) -> Void = { _ in }

    init(thumbnails: any GridThumbnailProviding) { self.thumbnails = thumbnails; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = collectionView
        collectionView.backgroundColor = .systemBackground
        collectionView.accessibilityIdentifier = "photoGrid"
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self; collectionView.prefetchDataSource = self
        collectionView.register(PhotoGridCell.self, forCellWithReuseIdentifier: "photo")
        dataSource = UICollectionViewDiffableDataSource<Int, SourceID>(collectionView: collectionView) { [weak self] collection, path, id in
            guard let self, let source = self.byID[id], let cell = collection.dequeueReusableCell(withReuseIdentifier: "photo", for: path) as? PhotoGridCell else { return nil }
            self.configure(cell, source: source); return cell
        }
        sweepGesture.delegate = self
        sweepGesture.maximumNumberOfTouches = 1
        collectionView.addGestureRecognizer(sweepGesture)
        collectionView.panGestureRecognizer.require(toFail: sweepGesture)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = GridGeometry.metrics(width: collectionView.bounds.width)
        if next != metrics {
            let anchor = captureAnchor()
            metrics = next; layout.itemSize = CGSize(width: next.tileWidth, height: next.tileHeight)
            layout.minimumInteritemSpacing = next.spacing; layout.minimumLineSpacing = next.spacing
            layout.sectionInset = next.insets
            layout.invalidateLayout(); collectionView.layoutIfNeeded(); restoreAnchor(anchor)
            refreshVisible()
        }
        // Task11 submits a new request with the final collapsed viewport. Use actual bounds here.
        if let request = pendingScroll {
            if let index = indices[request.sourceID] {
                if request.afterViewportHeight.map({ abs($0 - collectionView.bounds.height) < 0.5 }) ?? true {
                    let y = metrics.offsetToReveal(index: index, viewportHeight: collectionView.bounds.height,
                        currentOffset: collectionView.contentOffset.y, itemCount: sources.count)
                    collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    pendingScroll = nil
                }
            } else { pendingScroll = nil }
        }
        publishViewport(); cacheVisible()
    }
    func update(sources: [PhotoSource], checked: Set<SourceID>, selecting: Bool, viewed: SourceID?, scrollRequest: GridScrollRequest?) {
        loadViewIfNeeded()
        let idsChanged = self.sources.map(\.id) != sources.map(\.id)
        let metadataChanged = self.sources != sources
        if sweeping && (idsChanged || !selecting) { finishSweep(cancelled: true) }
        let anchor = idsChanged ? captureAnchor() : nil
        if metadataChanged {
            self.sources = sources
            byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        if idsChanged { indices = Dictionary(sources.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last }) }
        self.checked = checked; self.selecting = selecting; self.viewed = viewed
        if idsChanged {
            prefetched.formIntersection(Set(byID.keys))
            var snapshot = NSDiffableDataSourceSnapshot<Int, SourceID>(); snapshot.appendSections([0]); snapshot.appendItems(sources.map(\.id))
            dataSource.applySnapshotUsingReloadData(snapshot)
            collectionView.layoutIfNeeded(); restoreAnchor(anchor)
        }
        for case let cell as PhotoGridCell in collectionView.visibleCells {
            if let id = cell.sourceID, let source = byID[id] {
                if metadataChanged { configure(cell, source: source) }
                else { cell.membership(selecting: selecting, checked: checked.contains(id), viewed: id == viewed) }
            }
        }
        if let request = scrollRequest, request.id != lastScrollID { lastScrollID = request.id; pendingScroll = request }
        view.setNeedsLayout(); cacheVisible()
    }
    private func configure(_ cell: PhotoGridCell, source: PhotoSource) {
        cell.configure(source: source, selecting: selecting, checked: checked.contains(source.id), viewed: source.id == viewed,
            thumbnails: thumbnails, pixelSize: pixelSize, onTap: { [weak self] in self?.onSourceTapped(source.id) })
    }
    private var pixelSize: CGSize {
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        return CGSize(width: metrics.tileWidth * scale, height: metrics.tileWidth * scale)
    }
    private func refreshVisible() {
        for case let cell as PhotoGridCell in collectionView.visibleCells {
            if let id = cell.sourceID, let source = byID[id] { configure(cell, source: source) }
        }
    }
    private struct Anchor { let candidates: [SourceID]; let delta: CGFloat }
    private func captureAnchor() -> Anchor? {
        collectionView.layoutIfNeeded()
        let paths = collectionView.indexPathsForVisibleItems.sorted()
        guard let path = paths.first, path.item < sources.count else { return nil }
        return Anchor(candidates: Array(sources[path.item...].map(\.id)) + sources[..<path.item].reversed().map(\.id),
                      delta: collectionView.contentOffset.y - metrics.rect(index: path.item).minY)
    }
    private func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let id = anchor.candidates.first(where: { byID[$0] != nil }), let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let maxY = max(0, metrics.height(rows: metrics.contentRows(itemCount: sources.count)) - collectionView.bounds.height)
        collectionView.contentOffset.y = min(maxY, max(0, metrics.rect(index: index).minY + anchor.delta))
    }
    private func publishViewport() {
        let viewport = GridViewport(metrics: metrics, size: collectionView.bounds.size, contentOffset: collectionView.contentOffset,
            visibleSourceIDs: collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) })
        if viewport != lastViewport { lastViewport = viewport; onViewportChanged(viewport) }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publishViewport(); cacheVisible() }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let id = dataSource.itemIdentifier(for: indexPath) { onSourceTapped(id) }
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? PhotoGridCell)?.cancelThumbnail(); cacheVisible()
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        prefetched.formUnion(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }); cacheVisible()
    }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        prefetched.subtract(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }); cacheVisible()
    }
    private func cacheVisible() {
        guard dataSource != nil else { return }
        let visible = collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }
        // UIKit may promote prefetched cells without a cancellation callback. Retire old
        // preheating as the viewport moves, keeping at most one viewport on either side.
        let low = metrics.index(at: CGPoint(x: 0, y: collectionView.contentOffset.y - collectionView.bounds.height), itemCount: sources.count) ?? 0
        let high = metrics.index(at: CGPoint(x: collectionView.bounds.width, y: collectionView.contentOffset.y + 2 * collectionView.bounds.height), itemCount: sources.count) ?? 0
        prefetched = Set(prefetched.filter { id in indices[id].map { (low...high).contains($0) } ?? false })
        let nearby = prefetched.subtracting(visible).sorted { (indices[$0] ?? 0) < (indices[$1] ?? 0) }
        thumbnails.cache(sourceIDs: Array((visible + nearby).prefix(120)), pixelSize: pixelSize)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sweepGesture, selecting, !sources.isEmpty else { return false }
        let v = sweepGesture.velocity(in: collectionView)
        return abs(v.x) > abs(v.y) * 1.5
    }
    @objc private func sweepChanged(_ gesture: UIPanGestureRecognizer) {
        // Keep finger in viewport coordinates while content moves below it.
        var location = gesture.location(in: collectionView); location.y -= collectionView.contentOffset.y
        handleSweep(state: gesture.state, viewportLocation: location, translation: gesture.translation(in: collectionView))
    }
    /// Gesture-state admission and membership path shared by native recognition and lifecycle cancellation.
    func handleSweep(state: UIGestureRecognizer.State, viewportLocation: CGPoint, translation: CGPoint) {
        finger = viewportLocation
        switch state {
        case .began:
            guard selecting else { return }
            let start = CGPoint(x: finger.x, y: finger.y + collectionView.contentOffset.y) - translation
            guard let index = metrics.index(at: start, itemCount: sources.count) else { return }
            sweep.begin(index: index, checked: checked, orderedIDs: sources.map(\.id)); sweeping = true
            updateSweep()
            let link = CADisplayLink(target: self, selector: #selector(edgeTick)); link.add(to: .main, forMode: .common); displayLink = link
        case .changed: updateSweep()
        case .ended: updateSweep(); finishSweep(cancelled: false)
        case .cancelled, .failed: finishSweep(cancelled: true)
        default: break
        }
    }
    private func updateSweep() {
        guard sweeping, let index = metrics.index(at: CGPoint(x: finger.x, y: finger.y + collectionView.contentOffset.y), itemCount: sources.count) else { return }
        let value = sweep.update(index: index)
        if checked != value { checked = value; onCheckedChanged(value); refreshMembership() }
    }
    private func refreshMembership() {
        for case let cell as PhotoGridCell in collectionView.visibleCells {
            cell.membership(selecting: selecting, checked: cell.sourceID.map(checked.contains) ?? false, viewed: cell.sourceID == viewed)
        }
    }
    @objc private func edgeTick(_ link: CADisplayLink) {
        let edge: CGFloat = min(60, collectionView.bounds.height / 4)
        let velocity = finger.y < edge ? -max(0, 1 - finger.y / edge) : finger.y > collectionView.bounds.height - edge ? max(0, 1 - (collectionView.bounds.height - finger.y) / edge) : 0
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset.y = min(maxY, max(0, collectionView.contentOffset.y + velocity * 650 * CGFloat(link.targetTimestamp - link.timestamp)))
        updateSweep()
    }
    private func finishSweep(cancelled: Bool) {
        displayLink?.invalidate(); displayLink = nil
        if sweeping && cancelled { checked = sweep.cancel(); onCheckedChanged(checked); refreshMembership() }
        sweeping = false
    }
    func stop() {
        finishSweep(cancelled: true)
        for case let cell as PhotoGridCell in collectionView.visibleCells { cell.cancelThumbnail() }
        thumbnails.cache(sourceIDs: [], pixelSize: pixelSize)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshVisible(); cacheVisible()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

@MainActor
private final class PhotoGridCell: UICollectionViewCell {
    private let image = UIImageView()
    private let type = UILabel()
    private let mark = UILabel()
    private var provider: (any GridThumbnailProviding)?
    private var token: UUID?
    private var generation = UUID()
    private var tap: () -> Void = {}
    private(set) var sourceID: SourceID?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        type.font = .preferredFont(forTextStyle: .caption2); type.textColor = .white; type.backgroundColor = .black.withAlphaComponent(0.65)
        type.numberOfLines = 3
        type.layer.cornerRadius = 3; type.clipsToBounds = true
        mark.textColor = .white; mark.font = .systemFont(ofSize: 24, weight: .bold)
        for child in [image, type, mark] { child.isAccessibilityElement = false; contentView.addSubview(child) }
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); image.frame = contentView.bounds
        let badge = type.sizeThatFits(CGSize(width: max(1, bounds.width - 16), height: 44))
        type.frame = CGRect(x: 4, y: bounds.height - badge.height - 8,
                            width: min(bounds.width - 8, badge.width + 8), height: badge.height + 4)
        mark.frame = CGRect(x: bounds.width - 34, y: 4, width: 30, height: 30)
    }
    func configure(source: PhotoSource, selecting: Bool, checked: Bool, viewed: Bool, thumbnails: any GridThumbnailProviding, pixelSize: CGSize, onTap: @escaping () -> Void) {
        cancelThumbnail(); sourceID = source.id; provider = thumbnails; tap = onTap
        image.image = UIImage(systemName: "photo")
        image.tintColor = .tertiaryLabel
        accessibilityHint = "Thumbnail unavailable. Activate to view this source."
        var label = source.originalResources.jpeg == nil ? "RAF" : "RAW + JPEG"
        if case .incompatible(let model) = source.compatibility { label += " · \(model): X-T5 conversion unavailable" }
        type.text = label; accessibilityLabel = "Photo, \(source.originalResources.raf.originalFilename), \(label)"
        accessibilityIdentifier = "grid.\(source.id)"
        membership(selecting: selecting, checked: checked, viewed: viewed)
        let expected = generation
        token = thumbnails.request(sourceID: source.id, pixelSize: pixelSize) { [weak self] result in
            guard let self, self.sourceID == source.id, self.generation == expected else { return }
            self.image.image = result ?? UIImage(systemName: "photo")
            self.accessibilityHint = result == nil ? "Thumbnail unavailable. Activate to view this source." : "Activate to view. In Select, activation also toggles selection."
        }
    }
    func membership(selecting: Bool, checked: Bool, viewed: Bool) {
        mark.text = selecting ? (checked ? "☑" : "☐") : nil
        accessibilityValue = selecting ? (checked ? "Checked" : "Unchecked") : (viewed ? "Viewed" : "")
        accessibilityTraits = checked && selecting ? [.button, .selected] : [.button]
        accessibilityCustomActions = selecting ? [UIAccessibilityCustomAction(name: "Toggle selection", target: self, selector: #selector(activate))] : nil
        contentView.layer.borderWidth = viewed ? 2 : 0; contentView.layer.borderColor = UIColor.systemYellow.cgColor
    }
    @objc private func activate() -> Bool { tap(); return true }
    override func accessibilityActivate() -> Bool { activate() }
    func cancelThumbnail() { generation = UUID(); if let token { provider?.cancel(token) }; token = nil }
    override func prepareForReuse() { super.prepareForReuse(); cancelThumbnail(); sourceID = nil; image.image = nil }
}
