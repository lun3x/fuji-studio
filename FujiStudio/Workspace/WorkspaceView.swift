import SwiftUI

/// Presentation only. The caller owns the reducer, accessible source index and service effects.
struct WorkspaceView<StatusControl: View, ConnectionControl: View>: View {
    let state: WorkspaceState
    let sources: [PhotoSource]
    let thumbnails: any GridThumbnailProviding
    var imageURL: URL? = nil
    var imageGeometry: ImageGeometry? = nil
    var displayFile: DisplayFileLease? = nil
    var detail: ZoomPhotoView.DetailProvider? = nil
    var imageStatus: String? = nil
    var imageStatusIsFailure = false
    var savedVersions: [SavedVersion] = []
    var preview: CameraJPEG? = nil
    var exportPending = false
    var onAction: (WorkspaceAction) -> Void
    var onRefreshRecipes: () -> Void
    var onExport: () -> Void
    @ViewBuilder var statusControl: () -> StatusControl
    @ViewBuilder var connectionControl: () -> ConnectionControl
    var onViewportChanged: (GridViewport) -> Void = { _ in }
    @State private var drawerHeaderHeight: CGFloat = 0
    @State private var inspectionHeight: CGFloat = 0
    @State private var toolbarHeight: CGFloat = 0
    @State private var recipeFrame: CGRect = .zero
    @State private var versionFrame: CGRect = .zero
    @State private var versionMenuPresented = false
    @State private var scrollRequest: GridScrollRequest?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + safe.leading + safe.trailing, height: proxy.size.height + safe.top + safe.bottom)
            let width = max(1, size.width - safe.leading - safe.trailing)
            let toolbarTop = safe.top + 8
            // Consolidate chrome if the exact preferred rows leave less than a second measured
            // control stack for the photo and inline version/zoom controls.
            let reservedRows = GridGeometry.metrics(width: width).tileHeight + drawerHeaderHeight + safe.top + safe.bottom
            let controlStack = toolbarHeight + recipeFrame.height + 16
            let compactControls = size.height < size.width || dynamicTypeSize.isAccessibilitySize || size.height - reservedRows < controlStack * 2
            let regularPhotoTop = toolbarTop + toolbarHeight + 8
            // Positions come from this layout's current row/stack, never a prior branch's origin.
            // Intrinsic heights remain measured from the actual native controls.
            let recipeHeight = max(44, recipeFrame.height)
            let controlBottom = compactControls
                ? regularPhotoTop + max(recipeHeight, versionFrame.height)
                : regularPhotoTop + recipeHeight
            let controlFrame = CGRect(x: safe.leading + 16, y: toolbarTop, width: max(1, width - 32), height: controlBottom - toolbarTop)
            let photoTop = compactControls ? controlBottom + DrawerGeometry.controlClearance : regularPhotoTop
            // The collapsed viewer owns a real inspection row and image area. Grid adaptation
            // reserves their measured height; expansion covers this same fixed viewer frame.
            let inspectionReserve = compactControls && imageGeometry != nil ? max(44, inspectionHeight) + 8 + 44 : 0
            let available = size.height - safe.bottom - drawerHeaderHeight - controlFrame.maxY - DrawerGeometry.controlClearance - inspectionReserve
            let gridMetrics = DrawerGeometry.gridMetrics(width: width, availableGridHeight: available)
            let detents = DrawerGeometry.detents(container: size, safeArea: safe, headerHeight: drawerHeaderHeight,
                grid: gridMetrics, recipeControlFrame: controlFrame)
            let viewerHeight = max(1, size.height - detents.collapsedHeight - photoTop)
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                viewer(compactControls: compactControls)
                    .frame(width: width, height: viewerHeight)
                    .clipped().offset(x: safe.leading, y: photoTop)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PhotoDrawer(detent: Binding(get: { state.drawerDetent }, set: { onAction(.drawerMoved($0)) }),
                        detents: detents,
                        onHeaderHeightChanged: { drawerHeaderHeight = $0 },
                        onManualCollapse: {
                            if let id = state.viewedSourceID {
                                // Fresh request waits for actual final GRID bounds, including after animated resize.
                                scrollRequest = GridScrollRequest(sourceID: id, afterViewportHeight: detents.collapsedGridHeight)
                            }
                        }, header: { selectionHeader }, grid: {
                            PhotoGrid(sources: sources, checkedSourceIDs: state.checkedSourceIDs, isSelecting: state.isSelecting,
                                viewedSourceID: state.viewedSourceID, thumbnails: thumbnails, scrollRequest: scrollRequest,
                                gridMetrics: gridMetrics, bottomInset: safe.bottom,
                                onSourceTapped: { onAction(.sourceTapped($0)) },
                                onCheckedChanged: { onAction(.checkedSourcesReplaced($0)) }, onViewportChanged: onViewportChanged)
                        })
                        .frame(width: width)
                }.frame(width: width, height: size.height).offset(x: safe.leading)
                GlassEffectContainer(spacing: 8) {
                    toolbar(compact: dynamicTypeSize.isAccessibilitySize)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { toolbarHeight = $0 }
                }.padding(.horizontal, 12).frame(width: width)
                    .offset(x: safe.leading, y: toolbarTop).zIndex(10)
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        recipeControl
                        if compactControls { Spacer(minLength: 0); versionControl }
                    }
                }.padding(.horizontal, 16).frame(width: width, alignment: .leading)
                    .offset(x: safe.leading, y: regularPhotoTop).zIndex(10)
            }
            .coordinateSpace(name: "workspace")
            .frame(width: size.width, height: size.height)
            .offset(x: -safe.leading, y: -safe.top)
        }
    }
    @ViewBuilder private func viewer(compactControls: Bool) -> some View {
        if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
            VStack(spacing: 4) {
                PhotoViewer(sourceID: source.id, version: state.displayedVersion ?? .raw, imageURL: imageURL,
                    geometry: imageGeometry, onVersionSelected: { onAction(.versionSelected($0)) },
                    displayFile: displayFile, detail: detail, status: imageStatus, statusIsFailure: imageStatusIsFailure,
                    inspectionAvailable: state.drawerDetent == .collapsed,
                    onInspectionHeightChanged: { inspectionHeight = $0 })
                if !compactControls {
                    versionList(source: source).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            ContentUnavailableView("Choose a photo", systemImage: "photo.on.rectangle")
        }
    }
    private func toolbar(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            statusControl().buttonStyle(.bordered).frame(minWidth: 44).layoutPriority(-1)
            Spacer(minLength: 0)
            exportButton(compact: compact).fixedSize(horizontal: true, vertical: true)
            connectionControl().buttonStyle(.bordered).fixedSize(horizontal: true, vertical: true)
        }
    }
    private var recipeControl: some View {
        RecipeMenu(current: state.selectedRecipe, snapshots: state.recipes, refreshState: state.recipeRefreshState,
            onSelect: { onAction(.recipeSelected(slot: $0)) }, onRefresh: onRefreshRecipes,
            onControlFrameChanged: { recipeFrame = $0 })
    }
    private func exportButton(compact: Bool) -> some View {
        Button(action: onExport) {
            if compact { Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44) }
            else { Label("Export", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
        }
            .buttonStyle(.glassProminent).disabled(!state.canExport || exportPending)
            .accessibilityLabel("Export").accessibilityIdentifier("workspace.export")
            .accessibilityHint(exportPending ? "Preparing export submission" : state.exportDisabledReason?.message ?? "Export \(state.effectiveSources.count) photos using the selected recipe")
    }
    private func versionList(source: PhotoSource) -> VersionList {
        VersionList(source: source, saved: savedVersions, preview: preview, selected: state.displayedVersion,
            onVersionSelected: { versionMenuPresented = false; onAction(.versionSelected($0)) })
    }
    @ViewBuilder private var versionControl: some View {
        if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
            Button { versionMenuPresented = true } label: {
                Image(systemName: "square.3.layers.3d").frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.glass)
                .accessibilityLabel("Image versions")
                .accessibilityValue(versionList(source: source).entries.first { $0.id == state.displayedVersion }?.label ?? "No image version")
                .accessibilityIdentifier("workspace.versions")
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("workspace")) }) { versionFrame = $0 }
                .onDisappear { versionFrame = .zero; versionMenuPresented = false }
                .popover(isPresented: $versionMenuPresented, arrowEdge: .top) {
                    versionList(source: source).fixedSize(horizontal: false, vertical: true)
                        .frame(idealWidth: 320).padding(.vertical, 8).presentationCompactAdaptation(.popover)
                }
        }
    }
    private var selectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { selectionButton; count; Spacer(minLength: 0); membershipButtons }
            VStack(spacing: 8) {
                HStack { selectionButton; Spacer(minLength: 8); count }
                HStack { Spacer(minLength: 0); membershipButtons; Spacer(minLength: 0) }
            }
        }.font(dynamicTypeSize.isAccessibilitySize ? .caption : .callout)
    }
    private var selectionButton: some View {
        Button { onAction(state.isSelecting ? .done : .select) } label: {
            ZStack {
                Text("Select").fixedSize().hidden(); Text("Done").fixedSize().hidden()
                Text(state.isSelecting ? "Done" : "Select").fixedSize()
            }
        }.buttonStyle(.bordered).accessibilityIdentifier("workspace.select")
    }
    private var membershipButtons: some View {
        HStack(spacing: 8) {
            Button("All") { onAction(.all(accessibleEligibleSourceIDs: state.eligibleSourceIDs)) }
                .accessibilityIdentifier("workspace.all")
            Button("None") { onAction(.none) }.accessibilityIdentifier("workspace.none")
                .disabled(!state.isSelecting)
        }.buttonStyle(.bordered)
    }
    private var count: some View {
        ZStack {
            // Reserve the complete index count before entering Select or choosing All.
            Label("\(sources.count)", systemImage: "checkmark.circle").hidden()
            Label("\(sources.count)", systemImage: "photo").hidden()
            Label("\(state.effectiveSources.count)", systemImage: state.isSelecting ? "checkmark.circle" : "photo")
                .accessibilityLabel(state.isSelecting ? "\(state.effectiveSources.count) selected" : "\(state.effectiveSources.count) photo")
                .accessibilityIdentifier("workspace.count")
        }.font(.caption).monospacedDigit().lineLimit(1).fixedSize()
    }
}
