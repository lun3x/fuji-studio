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
    @State private var statusHeight: CGFloat = 0
    @State private var toolbarHeight: CGFloat = 0
    @State private var recipeFrame: CGRect = .zero
    @State private var versionFrame: CGRect = .zero
    @State private var scrollRequest: GridScrollRequest?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + safe.leading + safe.trailing, height: proxy.size.height + safe.top + safe.bottom)
            let width = max(1, size.width - safe.leading - safe.trailing)
            let toolbarTop = safe.top + 8
            let photoTop = toolbarTop + toolbarHeight + 8
            let controlBottom = photoTop + max(44, recipeFrame.height, versionFrame.height)
            let controlFrame = CGRect(x: safe.leading + 16, y: toolbarTop, width: max(1, width - 32), height: controlBottom - toolbarTop)
            // Only a real image-status message reserves space below the image. The two
            // selectors float over it in every layout; there are no version/zoom rows.
            let statusReserve = imageGeometry != nil && imageStatus != nil ? statusHeight + 8 : 0
            let available = size.height - safe.bottom - drawerHeaderHeight - controlFrame.maxY - DrawerGeometry.controlClearance - statusReserve - 44
            let gridMetrics = DrawerGeometry.gridMetrics(width: width, availableGridHeight: available)
            let detents = DrawerGeometry.detents(container: size, safeArea: safe, headerHeight: drawerHeaderHeight,
                grid: gridMetrics, recipeControlFrame: controlFrame)
            let viewerHeight = max(1, size.height - detents.collapsedHeight - photoTop)
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                viewer
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
                        }, grid: {
                            PhotoGrid(sources: sources, checkedSourceIDs: state.checkedSourceIDs, isSelecting: state.isSelecting,
                                viewedSourceID: state.viewedSourceID, thumbnails: thumbnails, scrollRequest: scrollRequest,
                                gridMetrics: gridMetrics, bottomInset: safe.bottom,
                                onSourceTapped: { onAction(.sourceTapped($0)) },
                                onCheckedChanged: { onAction(.checkedSourcesReplaced($0)) }, onViewportChanged: onViewportChanged)
                                .overlay(alignment: .top) { selectionControls.padding(12) }
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
                        Spacer(minLength: 0)
                        versionControl
                    }
                }.padding(.horizontal, 16).frame(width: width, alignment: .leading)
                    .offset(x: safe.leading, y: photoTop).zIndex(10)
            }
            .coordinateSpace(name: "workspace")
            .frame(width: size.width, height: size.height)
            .offset(x: -safe.leading, y: -safe.top)
        }
    }
    @ViewBuilder private var viewer: some View {
        if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
            PhotoViewer(sourceID: source.id, version: state.displayedVersion ?? .raw, imageURL: imageURL,
                geometry: imageGeometry, displayFile: displayFile, detail: detail,
                status: imageStatus, statusIsFailure: imageStatusIsFailure,
                statusVisible: state.drawerDetent == .collapsed,
                onStatusHeightChanged: { statusHeight = $0 })
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
        RecipeMenu(current: state.selectedRecipe, snapshots: state.recipes,
            isCameraConnected: state.isCameraConnected,
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
    @ViewBuilder private var versionControl: some View {
        if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
            VersionMenu(source: source, saved: savedVersions, preview: preview, selected: state.displayedVersion,
                onVersionSelected: { onAction(.versionSelected($0)) }, onControlFrameChanged: { versionFrame = $0 })
        }
    }
    private var selectionControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .top) {
                if state.isSelecting {
                    count.padding(.horizontal, 12).frame(minHeight: 44)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 12)
                selectionButton
            }
        }
    }
    private var selectionButton: some View {
        Button { onAction(state.isSelecting ? .done : .select) } label: {
            Group {
                if state.isSelecting {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                } else {
                    Text("Select").fixedSize().padding(.horizontal, 16).frame(minHeight: 44)
                }
            }
            .font(.callout.weight(.semibold)).contentShape(.capsule)
        }.buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(state.isSelecting ? "Cancel selection" : "Select")
            .accessibilityIdentifier("workspace.select")
    }
    private var count: some View {
        Label("\(state.checkedSourceIDs.count)", systemImage: "checkmark.circle")
            .accessibilityLabel("\(state.checkedSourceIDs.count) selected")
            .accessibilityIdentifier("workspace.count")
            .font(.caption).monospacedDigit().lineLimit(1).fixedSize()
    }
}
