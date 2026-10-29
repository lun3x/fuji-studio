import FujiCameraCore
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
    private var contentRotation: CGFloat = 0
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
    private var suppliedMetrics: GridMetrics?
    private var layoutSize: CGSize = .zero
    private var allowsDrawerCollapse = false
    private var drawerPanOrigin: CGFloat?
    private var pullingDrawer = false
    private lazy var sweepGesture = UIPanGestureRecognizer(target: self, action: #selector(sweepChanged))
    var onSourceTapped: (SourceID) -> Void = { _ in }
    var onCheckedChanged: (Set<SourceID>) -> Void = { _ in }
    var onViewportChanged: (GridViewport) -> Void = { _ in }
    var onDrawerDrag: (DrawerScrollDrag) -> Void = { _ in }

    init(thumbnails: any GridThumbnailProviding) { self.thumbnails = thumbnails; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = collectionView
        collectionView.backgroundColor = .systemBackground
        collectionView.accessibilityIdentifier = "photoGrid"
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        // Our tray supplies its own glass controls. Automatic scroll-edge blur can
        // cover an entire row of photos when the collection view is rotated.
        for edge in [collectionView.topEdgeEffect, collectionView.bottomEdgeEffect,
                     collectionView.leftEdgeEffect, collectionView.rightEdgeEffect] { edge.isHidden = true }
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
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(scrollPanChanged))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if layoutSize != .zero && layoutSize.width != size.width { cancelDrawerPan() }
        if layoutSize != .zero && layoutSize != size { finishSweep(cancelled: true) }
        layoutSize = size
        let next = suppliedMetrics ?? GridGeometry.metrics(width: size.width)
        if next != metrics {
            finishSweep(cancelled: true)
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
                    let y = metrics.offsetToReveal(index: index, viewportHeight: max(1, collectionView.bounds.height - collectionView.contentInset.bottom),
                        currentOffset: collectionView.contentOffset.y, itemCount: sources.count)
                    collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    pendingScroll = nil
                }
            } else { pendingScroll = nil }
        }
        publishViewport(); cacheVisible()
    }
    func update(sources: [PhotoSource], checked: Set<SourceID>, selecting: Bool, viewed: SourceID?, scrollRequest: GridScrollRequest?, gridMetrics: GridMetrics? = nil, bottomInset: CGFloat = 0, contentRotation: CGFloat = 0, allowsDrawerCollapse: Bool = false) {
        loadViewIfNeeded()
        if self.contentRotation != contentRotation {
            cancelDrawerPan()
            finishSweep(cancelled: true)
        }
        self.contentRotation = contentRotation
        suppliedMetrics = gridMetrics
        collectionView.contentInset.bottom = max(0, bottomInset)
        collectionView.verticalScrollIndicatorInsets.bottom = max(0, bottomInset)
        let idsChanged = self.sources.map(\.id) != sources.map(\.id)
        if idsChanged || !allowsDrawerCollapse { cancelDrawerPan() }
        self.allowsDrawerCollapse = allowsDrawerCollapse
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
                cell.contentView.transform = CGAffineTransform(rotationAngle: contentRotation)
                if metadataChanged { configure(cell, source: source) }
                else { cell.membership(selecting: selecting, checked: checked.contains(id), viewed: id == viewed) }
            }
        }
        if let request = scrollRequest, request.id != lastScrollID { lastScrollID = request.id; pendingScroll = request }
        view.setNeedsLayout(); cacheVisible()
    }
    private func configure(_ cell: PhotoGridCell, source: PhotoSource) {
        cell.contentView.transform = CGAffineTransform(rotationAngle: contentRotation)
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
        let maxY = max(0, metrics.height(rows: metrics.contentRows(itemCount: sources.count)) - collectionView.bounds.height + collectionView.contentInset.bottom)
        collectionView.contentOffset.y = min(maxY, max(0, metrics.rect(index: index).minY + anchor.delta))
    }
    private func publishViewport() {
        let viewport = GridViewport(metrics: metrics, size: collectionView.bounds.size, contentOffset: collectionView.contentOffset,
            visibleSourceIDs: collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) })
        if viewport != lastViewport { lastViewport = viewport; onViewportChanged(viewport) }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pinGridDuringDrawerPull()
        publishViewport(); cacheVisible()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        handleScrollPan(state: .began, translation: scrollView.panGestureRecognizer.translation(in: view.window))
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if pullingDrawer { targetContentOffset.pointee.y = -scrollView.adjustedContentInset.top }
    }
    @objc private func scrollPanChanged(_ gesture: UIPanGestureRecognizer) {
        // The grid's origin moves with the drawer. Window coordinates keep this translation
        // independent of the resize, so finger movement is consumed exactly once.
        if gesture.state != .began {
            handleScrollPan(state: gesture.state, translation: gesture.translation(in: view.window), velocity: gesture.velocity(in: view.window))
        }
    }
    func handleScrollPan(state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint = .zero) {
        // Keep the stable window-space measurement, but consume movement along the
        // device's portrait axis when the tray opens sideways in landscape.
        let toCanvas = CGAffineTransform(rotationAngle: contentRotation)
        let translation = translation.applying(toCanvas), velocity = velocity.applying(toCanvas)
        switch state {
        case .began:
            cancelDrawerPan()
            guard allowsDrawerCollapse, !sweeping else { return }
            drawerPanOrigin = translation.y + max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        case .changed, .ended:
            guard let origin = drawerPanOrigin else { return }
            let excess = translation.y - origin
            if !pullingDrawer && excess > 0 && collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5 {
                pullingDrawer = true
            }
            guard pullingDrawer else {
                if state == .ended { drawerPanOrigin = nil }
                return
            }
            if excess < 0 {
                // The tray is fully expanded again. Consume the remaining upward movement
                // in the grid, then let UIKit own further scrolling and its momentum.
                pullingDrawer = false
                collectionView.contentOffset.y = -collectionView.adjustedContentInset.top - excess
                onDrawerDrag(.changed(translation: 0))
                onDrawerDrag(.ended(translation: 0, velocity: 0))
                if state == .ended { drawerPanOrigin = nil }
                return
            }
            pinGridDuringDrawerPull()
            if state == .ended {
                drawerPanOrigin = nil; pullingDrawer = false
                onDrawerDrag(.ended(translation: excess, velocity: velocity.y))
            } else { onDrawerDrag(.changed(translation: excess)) }
        case .cancelled, .failed: cancelDrawerPan()
        default: break
        }
    }
    private func pinGridDuringDrawerPull() {
        let top = -collectionView.adjustedContentInset.top
        if pullingDrawer && collectionView.contentOffset.y != top {
            collectionView.contentOffset.y = top
        }
    }
    private func cancelDrawerPan() {
        let wasPulling = pullingDrawer
        drawerPanOrigin = nil; pullingDrawer = false
        if wasPulling { onDrawerDrag(.cancelled) }
    }
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
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom)
        collectionView.contentOffset.y = min(maxY, max(0, collectionView.contentOffset.y + velocity * 650 * CGFloat(link.targetTimestamp - link.timestamp)))
        updateSweep()
    }
    private func finishSweep(cancelled: Bool) {
        displayLink?.invalidate(); displayLink = nil
        if sweeping && cancelled { checked = sweep.cancel(); onCheckedChanged(checked); refreshMembership() }
        sweeping = false
    }
    func stop() {
        cancelDrawerPan()
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
    private let selectionShade = UIView()
    private let type = UILabel()
    private let mark = UIImageView()
    private var provider: (any GridThumbnailProviding)?
    private var token: UUID?
    private var generation = UUID()
    private var tap: () -> Void = {}
    private(set) var sourceID: SourceID?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 2
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        image.contentMode = .scaleAspectFill; image.clipsToBounds = true
        // The decorative kind badge stays compact; the cell speaks its complete kind/status.
        type.maximumContentSizeCategory = .extraExtraExtraLarge
        type.font = .preferredFont(forTextStyle: .caption2, compatibleWith: type.traitCollection)
        type.adjustsFontForContentSizeCategory = true
        type.adjustsFontSizeToFitWidth = true; type.minimumScaleFactor = 0.7
        type.textColor = .white; type.backgroundColor = .black.withAlphaComponent(0.65)
        type.numberOfLines = 1; type.lineBreakMode = .byTruncatingTail
        type.layer.cornerRadius = 3; type.clipsToBounds = true
        selectionShade.backgroundColor = UIColor.systemGray.withAlphaComponent(0.45)
        selectionShade.isUserInteractionEnabled = false
        let colors = UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
        mark.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: colors)
        mark.contentMode = .scaleAspectFit
        for child in [image, selectionShade, type, mark] { child.isAccessibilityElement = false; contentView.addSubview(child) }
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); image.frame = contentView.bounds; selectionShade.frame = contentView.bounds
        let badgeWidth = max(0, bounds.width - 8 - (mark.isHidden ? 0 : 32))
        let badge = type.sizeThatFits(CGSize(width: max(1, badgeWidth - 8), height: 44))
        let badgeHeight = min(max(0, bounds.height - 8), ceil(badge.height) + 4)
        type.frame = CGRect(x: 4, y: bounds.height - badgeHeight - 4,
                            width: min(badgeWidth, ceil(badge.width) + 8), height: badgeHeight)
        mark.frame = CGRect(x: bounds.width - 30, y: bounds.height - 30, width: 24, height: 24)
    }
    func configure(source: PhotoSource, selecting: Bool, checked: Bool, viewed: Bool, thumbnails: any GridThumbnailProviding, pixelSize: CGSize, onTap: @escaping () -> Void) {
        cancelThumbnail(); sourceID = source.id; provider = thumbnails; tap = onTap
        image.image = UIImage(systemName: "photo")
        image.tintColor = .tertiaryLabel
        accessibilityHint = "Thumbnail unavailable. Activate to view this source."
        var label = source.originalResources.jpeg == nil ? "RAF" : "RAW + JPEG"
        if case .incompatible(let model) = source.compatibility { label += " · \(model): camera conversion unavailable" }
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
        let selected = selecting && checked
        selectionShade.isHidden = !selected
        mark.isHidden = !selected
        setNeedsLayout()
        isSelected = selected
        accessibilityValue = selecting ? (checked ? "Checked" : "Unchecked") : (viewed ? "Viewed" : "")
        accessibilityTraits = checked && selecting ? [.button, .selected] : [.button]
        accessibilityCustomActions = selecting ? [UIAccessibilityCustomAction(name: "Toggle selection", target: self, selector: #selector(activate))] : nil
        contentView.layer.borderWidth = viewed && !selecting ? 2 : 0; contentView.layer.borderColor = UIColor.systemBlue.cgColor
    }
    @objc private func activate() -> Bool { tap(); return true }
    override func accessibilityActivate() -> Bool { activate() }
    func cancelThumbnail() { generation = UUID(); if let token { provider?.cancel(token) }; token = nil }
    override func prepareForReuse() { super.prepareForReuse(); cancelThumbnail(); sourceID = nil; image.image = nil }
}
