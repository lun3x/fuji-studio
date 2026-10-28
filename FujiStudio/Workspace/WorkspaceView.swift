import SwiftUI

/// Presentation only. The caller owns the reducer, accessible source index and service effects.
struct WorkspaceView<StatusControl: View>: View {
    let state: WorkspaceState
    let sources: [PhotoSource]
    let thumbnails: any GridThumbnailProviding
    var imageURL: URL? = nil
    var imageGeometry: ImageGeometry? = nil
    var displayFile: DisplayFileLease? = nil
    var imageIdentity: (sourceID: SourceID, version: VersionID)? = nil
    var detail: ZoomPhotoView.DetailProvider? = nil
    var imageLoading: ImageLoadingState? = nil
    var imageStatus: String? = nil
    var imageStatusIsFailure = false
    var savedVersions: [SavedVersion] = []
    var exportPending = false
    var previewLoading = false
    var onAction: (WorkspaceAction) -> Void
    var onRefreshRecipes: () -> Void
    var onExport: () -> Void
    @ViewBuilder var statusControl: () -> StatusControl
    var onViewportChanged: (GridViewport) -> Void = { _ in }
    @State private var drawerHeaderHeight: CGFloat = 0
    @State private var statusHeight: CGFloat = 0
    @State private var controlHeight: CGFloat = 0
    @State private var scrollRequest: GridScrollRequest?
    @State private var orientation = WorkspaceOrientation.portrait

    var body: some View {
        GeometryReader { proxy in
            let windowSafe = proxy.safeAreaInsets
            let windowSize = CGSize(width: proxy.size.width + windowSafe.leading + windowSafe.trailing,
                height: proxy.size.height + windowSafe.top + windowSafe.bottom)
            let safe = orientation.layoutInsets(windowSafe)
            let size = orientation.layoutSize(windowSize)
            let width = max(1, size.width - safe.leading - safe.trailing)
            // Photos fill the landscape screen; only the floating controls avoid
            // the home indicator. Insetting the whole tray leaves a bottom strip.
            let trayWidth = orientation == .portrait ? width : size.width
            let trayLeading = orientation == .portrait ? safe.leading : 0
            let photoTop = safe.top
            let controlTop = photoTop + 8
            let controlBottom = controlTop + max(44, controlHeight)
            let controlFrame = CGRect(x: safe.leading + 16, y: controlTop, width: max(1, width - 32), height: controlBottom - controlTop)
            // Only a real image-status message reserves space below the image. The two
            // photo controls and camera indicator float over it in every layout.
            let statusReserve = imageGeometry != nil && imageStatus != nil && imageLoading == nil ? statusHeight + 8 : 0
            let available = size.height - safe.bottom - drawerHeaderHeight - controlFrame.maxY - DrawerGeometry.controlClearance - statusReserve - 44
            let gridMetrics = DrawerGeometry.gridMetrics(width: trayWidth, availableGridHeight: available)
            let detents = DrawerGeometry.detents(container: size, safeArea: safe, headerHeight: drawerHeaderHeight,
                grid: gridMetrics, recipeControlFrame: controlFrame)
            let viewerHeight = max(1, size.height - detents.collapsedHeight - photoTop)
            let viewerSize = orientation.layoutSize(CGSize(width: width, height: viewerHeight))
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                viewer
                    .frame(width: viewerSize.width, height: viewerSize.height)
                    .rotationEffect(orientation.contentAngle)
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
                        }, grid: { onDrawerDrag in
                            PhotoGrid(sources: sources, checkedSourceIDs: state.checkedSourceIDs, isSelecting: state.isSelecting,
                                viewedSourceID: state.viewedSourceID, thumbnails: thumbnails, scrollRequest: scrollRequest,
                                gridMetrics: gridMetrics, bottomInset: safe.bottom,
                                contentRotation: orientation.contentRotation, allowsDrawerCollapse: state.drawerDetent == .expanded,
                                onSourceTapped: { onAction(.sourceTapped($0)) },
                                onCheckedChanged: { onAction(.checkedSourcesReplaced($0)) }, onViewportChanged: onViewportChanged,
                                onDrawerDrag: onDrawerDrag)
                                .anchorPreference(key: TrayBoundsKey.self, value: .bounds) { $0 }
                        })
                        .frame(width: trayWidth)
                }.frame(width: trayWidth, height: size.height).offset(x: trayLeading)
            }
            .coordinateSpace(name: "workspace")
            .frame(width: size.width, height: size.height)
            .rotationEffect(orientation.canvasAngle)
            .frame(width: windowSize.width, height: windowSize.height)
            .overlayPreferenceValue(TrayBoundsKey.self) { anchor in
                GeometryReader { overlay in
                    if let anchor {
                        let frame = overlay[anchor]
                        selectionControls.padding(12)
                            .padding(.top, orientation == .portrait ? 0 : windowSafe.top)
                            .padding(.bottom, orientation == .portrait ? 0 : windowSafe.bottom)
                            .frame(width: frame.width, height: frame.height, alignment: orientation.trayControlAlignment)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                let frame = orientation.windowFrame(controlFrame, in: size)
                GlassEffectContainer(spacing: 8) {
                    DeviceAnchoredRow(orientation: orientation, spacing: 8) {
                        statusControl()
                        recipeControl
                        photoActionControl
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { orientation.layoutSize($0.size).height }) { controlHeight = $0 }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
            .environment(\.workspaceOrientation, orientation)
            .offset(x: -windowSafe.leading, y: -windowSafe.top)
        }
        .background { WorkspaceOrientationReader { orientation = $0 } }
    }
    @ViewBuilder private var viewer: some View {
        if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
            PhotoViewer(sourceID: imageIdentity?.sourceID ?? source.id,
                version: imageIdentity?.version ?? state.displayedVersion ?? .raw, imageURL: imageURL,
                geometry: imageGeometry, displayFile: displayFile, detail: detail,
                loading: imageLoading,
                status: imageStatus, statusIsFailure: imageStatusIsFailure,
                statusVisible: state.drawerDetent == .collapsed,
                onStatusHeightChanged: { statusHeight = $0 })
        } else {
            ContentUnavailableView("Choose a photo", systemImage: "photo.on.rectangle")
        }
    }
    private var recipeControl: some View {
        RecipeMenu(current: state.selectedRecipe, snapshots: state.recipes, refreshState: state.recipeRefreshState,
            isCameraConnected: state.isCameraConnected,
            onSelect: { onAction(.recipeSelected(slot: $0)) }, onRefresh: onRefreshRecipes)
    }
    private var exportButton: some View {
        Button(action: onExport) {
            Image(systemName: "square.and.arrow.up").font(.headline)
                .frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
        }
            .buttonStyle(.glassProminent).disabled(!state.canExport || exportPending || previewLoading)
            .accessibilityLabel("Export").accessibilityIdentifier("workspace.export")
            .accessibilityHint(exportPending ? "Preparing export submission" : previewLoading ? "Wait for the photo preview to finish loading" : state.exportDisabledReason?.message ?? "Export \(state.effectiveSources.count) photos using the selected recipe")
    }
    private var photoActionControl: some View {
        Group {
            if state.selectedRecipe != nil {
                exportButton
            } else if let source = sources.first(where: { $0.id == state.viewedSourceID }) {
                VersionMenu(source: source, saved: savedVersions, selected: state.displayedVersion,
                    onVersionSelected: { onAction(.versionSelected($0)) })
            }
        }
    }
    private var selectionControls: some View {
        GlassEffectContainer(spacing: 12) {
            DeviceAnchoredRow(orientation: orientation, spacing: 12, leadingItems: state.isSelecting ? 1 : 0) {
                if state.isSelecting {
                    count.padding(.horizontal, 12).frame(minHeight: 44)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                }
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

private struct TrayBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
