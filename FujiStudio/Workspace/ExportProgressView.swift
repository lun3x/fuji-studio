import FujiCameraCore
import SwiftUI

struct ExportProgressView: View {
    let event: ExportEvent
    let canResume: Bool
    let onCancel: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onReconcile: () -> Void
    var canFinishReplacement: Bool = false
    var onFinishReplacement: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event.recipeLabel).font(.headline).accessibilityIdentifier("export.recipe")
            Text(Self.status(event)).accessibilityIdentifier("export.status")
            Text(countDescription)
                .accessibilityIdentifier("export.counts")
            ForEach(Array(event.failures.enumerated()), id: \.offset) { _, failure in
                Text(Self.failureMessage(failure)).accessibilityIdentifier("export.failure")
            }
            if case .camera(let failure) = event.pauseReason { Text(Self.failureMessage(failure)) }
            if case .persistence = event.pauseReason { Text("The local catalog could not be updated. Recovery records and existing exports are retained.") }
            if !event.terminal {
                ProgressView(value: event.summary.fractionCompleted)
                    .accessibilityLabel("Export progress")
                    .accessibilityValue("\(event.summary.processed) of \(event.summary.total) processed")
                    .accessibilityIdentifier("export.progress")
                Button(event.stopRequested ? "Stopping safely…" : "Cancel remaining", action: onCancel).disabled(event.stopRequested)
                    .accessibilityIdentifier("export.cancel")
            } else if event.summary.unresolved > 0 {
                if event.summary.replacementCleanup > 0 {
                    if event.summary.unprocessed > 0 && event.summary.unresolved == event.summary.replacementCleanup {
                        Text("Verified RAW+JPEG pairs are retained. Resume finishes the remaining exports before removing the old RAW assets together.")
                        Button("Resume", action: onResume).disabled(!canResume).accessibilityIdentifier("export.resume")
                        Button("Cancel remaining", action: onCancel).accessibilityIdentifier("export.cancel")
                    } else {
                        Text("The RAW+JPEG pair is verified. Finish replacement removes the old RAW-only asset and its previous Photos edits. The unchanged RAW and exported JPEG remain in the pair.")
                        Button("Finish replacement", action: onFinishReplacement).disabled(!canFinishReplacement)
                            .accessibilityIdentifier("export.finishReplacement")
                    }
                } else {
                    Text("Photos has not confirmed this save. Reconciliation checks the same operation; it does not create a replacement export.")
                }
                Button("Check Photos again", action: onReconcile).accessibilityIdentifier("export.reconcile")
            } else {
                if event.summary.unprocessed > 0 {
                    Button("Resume", action: onResume).disabled(!canResume).accessibilityIdentifier("export.resume")
                }
                if event.summary.failed + event.summary.skipped > 0 {
                    Button("Retry remaining", action: onRetry).disabled(!canResume).accessibilityIdentifier("export.retry")
                }
            }
            Text("Keep Fuji Studio open while exporting over USB. Returning to the app checks interrupted work before you resume.").font(.footnote)
        }
    }
    private var countDescription: String {
        let summary = event.summary
        let cleanup = summary.replacementCleanup > 0 ? " · \(summary.replacementCleanup) awaiting cleanup" : ""
        return "\(summary.completed) saved\(cleanup) · \(summary.failed) failed · \(summary.skipped) cancelled · \(summary.unprocessed) remaining · \(summary.unconfirmed) unconfirmed"
    }
    static func failureMessage(_ failure: ExportFailure) -> String {
        switch failure {
        case .authorization: "Photos access is required. Check Settings before retrying."
        case .inaccessible: "An original photo is no longer accessible. Check your Photos selection."
        case .insufficientStorage: "There is not enough storage. Free some space before retrying."
        case .unsupportedSettings: "The selected recipe has unsupported conversion settings."
        case .unsupportedSource: "An original photo cannot be converted by the connected camera."
        case .transport: "Camera connection interrupted. Check the USB data cable and camera mode."
        case .preparation: "An original could not be prepared. Check its availability and iCloud download, then retry."
        case .unresolvedSave: "Photos has not confirmed this save. Check Photos again before retrying."
        }
    }
    static func status(_ event: ExportEvent) -> String {
        if !event.terminal, !event.stopRequested, event.summary.unprocessed == 0,
           event.summary.replacementCleanup > 0, event.summary.replacementCleanup == event.summary.unresolved {
            return "Finishing original cleanup in Photos"
        }
        if event.terminal, event.summary.replacementCleanup > 0,
           event.summary.replacementCleanup == event.summary.unresolved {
            return event.summary.unprocessed > 0 ? "Export paused — resume when ready" : "RAW+JPEG saved — removal pending"
        }
        if event.stage == .unresolved || (event.terminal && event.summary.unresolved > 0) { return "Save unconfirmed" }
        if event.stopRequested { return "Stopping after the current operation" }
        switch event.stage {
        case .queued: return event.terminal ? "Export paused — resume when ready" : "Waiting to export"
        case .preparing: return "Preparing original"
        case .converting: return "Converting on camera"
        case .pendingSave: return "Saving to Photos"
        case .saved: return event.summary.unprocessed + event.summary.failed + event.summary.skipped == 0 ? "Export saved" : "Export stopped"
        case .paused: return "Export paused — resume when ready"
        case .unresolved: return "Save unconfirmed"
        case .failed: return "Export finished with failures"
        case .cancelled: return "Export cancelled"
        case .unprocessed: return "Photos remain to export"
        }
    }
}

struct AppWorkspaceView: View {
    let model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var statusPresented = false
    @State private var statusPath: [StatusDestination] = []
    @State private var connection = PresentedCameraConnection()

    @State private var cameraMode = false
    @State private var handoffPresented = false
    @State private var cameraPhotoError: String?
    @State private var cameraPreview: DisplayFileLease?
    @State private var viewerFile: ViewerFile?
    @State private var viewedRequest: CameraBrowserModel.ViewerRequest?
    @State private var viewerFailure: String?

    private var browser: CameraBrowserModel { model.cameraBrowser }
    private var state: WorkspaceState { cameraMode ? browser.workspace : model.state }
    private var request: CameraBrowserModel.ViewerRequest? { cameraMode ? browser.viewerRequest : nil }
    private var displayFile: DisplayFileLease? {
        cameraMode ? (viewedRequest == request ? (viewerFile?.lease ?? cameraPreview) : nil) : model.displayFile
    }
    private var galleryMessage: String? {
        guard cameraMode, browser.traySources.isEmpty else { return nil }
        return browser.isLoading ? "Reading camera photos…" : "No RAW photos on the camera"
    }

    private enum StatusDestination: Hashable { case cameraBrowser, autoSave, cameraImports }

    private var imageLoading: ImageLoadingState? {
        if !cameraMode { return model.imageLoading }
        guard let request, viewerFailure == nil else { return nil }
        let ready = request.original == nil ? cameraPreview != nil : viewerFile != nil
        return viewedRequest == request && ready ? nil : .loading
    }

    private var workspace: some View {
        let provider: any GridThumbnailProviding = cameraMode ? model.environment.wireless.trayThumbnails : model.environment.thumbnails
        let action: (WorkspaceAction) -> Void = { event in
            if cameraMode { browser.apply(event) } else { model.send(event) }
        }
        let save: (() -> Void)? = cameraMode ? { saveCameraPhotos() } : nil
        return WorkspaceView(state: state, sources: cameraMode ? browser.traySources : model.sources,
            thumbnails: provider,
            imageURL: displayFile?.fileURL, imageGeometry: displayFile?.geometry,
            displayFile: displayFile, imageIdentity: cameraMode ? nil : model.imageIdentity,
            detail: cameraMode ? nil : model.detail,
            imageLoading: imageLoading,
            imageStatus: cameraMode ? viewerFailure : model.imageStatus,
            imageStatusIsFailure: cameraMode ? viewerFailure != nil : model.imageStatusIsFailure,
            savedVersions: cameraMode ? [] : model.savedVersions, exportPending: model.isSubmitting, previewLoading: model.isLoadingPreview,
            onSaveCameraPhotos: save,
            canSaveCameraPhotos: cameraMode && browser.canSaveWorkspaceSelection && !model.cameraImportActive && model.importJournalIssue == nil,
            showingCameraThumbnailOnly: cameraMode && request?.original == nil,
            cameraGalleryMessage: galleryMessage, reservesCameraButtonSpace: showsCameraPhotos,
            onAction: action, onRefreshRecipes: { Task { await model.refreshRecipes() } },
            onCopyRecipeToPhone: model.copyRecipeToPhone,
            onDeletePhoneRecipe: model.deletePhoneRecipe,
            onEditPhoneRecipe: model.updatePhoneRecipe,
            onExport: { Task { await model.export() } },
            statusControl: { statusButton })
    }

    var body: some View {
        workspace.id(cameraMode)
        .task(id: request) { await loadViewedOriginal(request) }
        .overlay(alignment: .bottom) { cameraPhotosButton.padding(.bottom, 8) }
        .onChange(of: model.wirelessState.wifi) { _, phase in
            if phase == .ready { cameraMode = true }
            if phase == .idle { cameraMode = false }
        }
        .onChange(of: model.wirelessState.manualNetwork) { _, network in handoffPresented = network != nil }
        .sheet(isPresented: Binding(get: { handoffPresented && !statusPresented }, set: { handoffPresented = $0 })) {
            handoffSheet
        }
        .alert("Camera Photos", isPresented: Binding(get: { cameraPhotoError != nil }, set: { if !$0 { cameraPhotoError = nil } })) {
            Button("OK") { cameraPhotoError = nil }
        } message: { Text(cameraPhotoError ?? "") }
        .sheet(isPresented: Binding(get: { statusPresented }, set: { presented in
            if presented { statusPresented = true } else { closeStatus() }
        })) { statusSheet }
    }

    private var statusSheet: some View {
            NavigationStack(path: $statusPath) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.wirelessAvailable {
                            if model.importJournalIssue != nil { CameraImportJournalIssue() }
                            if let error = model.importActionError {
                                Text(error).foregroundStyle(.red).accessibilityIdentifier("app.importError")
                            }
                            if model.isPreparingImport || !model.importEvents.isEmpty || model.importActionError != nil {
                                Button("Camera imports") { statusPath.append(.cameraImports) }
                                    .accessibilityIdentifier("cameraImport.open")
                            }
                            CameraConnectionSection(model: model, connection: connection,
                                onBrowse: { statusPath.append(.cameraBrowser) },
                                onSetUpAutoSave: { statusPath.append(.autoSave) })
                            Divider()
                        }
                        Text(accessMessage).accessibilityIdentifier("app.access")
                        if model.state.libraryAccess == .limited { Button("Manage Photos", action: model.managePhotos).accessibilityIdentifier("app.managePhotos") }
                        if model.state.libraryAccess == .denied || model.state.libraryAccess == .restricted { Button("Open Settings", action: model.openSettings) }
                        Text(cameraMessage).accessibilityIdentifier("app.camera")
                        if let error = model.cameraError {
                            Text(error).foregroundStyle(.red).accessibilityIdentifier("app.cameraError")
                        }
                        if let error = model.cameraResetError {
                            Text(error).foregroundStyle(.red).accessibilityIdentifier("app.cameraResetError")
                        }
                        Button {
                            Task { await model.resetCameraConnection() }
                        } label: {
                            HStack {
                                if model.isResettingCamera { ProgressView() }
                                Text(model.isResettingCamera ? "Resetting camera connection…" : "Reset camera connection")
                            }
                        }
                        .disabled(!model.canResetCameraConnection)
                        .accessibilityIdentifier("app.resetCamera")
                        if let reason = model.state.exportDisabledReason {
                            Text(reason.message).accessibilityIdentifier("app.exportDisabledReason")
                        }
                        if case .authorizationDenied = model.state.cameraState { Button("Open Settings", action: model.openSettings) }
                        if let message = model.message { Text(message).accessibilityIdentifier("app.error") }
                        if let error = model.connectionError { Text(error).accessibilityIdentifier("app.connectionError") }
                        ForEach(model.progressEvents, id: \.jobID) { event in
                            ExportProgressView(event: event, canResume: !model.isSuspended && !model.isSubmitting && !model.isResettingCamera && model.cameraError == nil && model.cameraResetError == nil && model.state.currentCameraExecutionContext != nil && model.state.isCameraReady,
                                onCancel: { Task { await model.cancelExport(jobID: event.jobID) } }, onResume: { Task { await model.resumeExport(jobID: event.jobID) } },
                                onRetry: { Task { await model.resumeExport(jobID: event.jobID, retry: true) } }, onReconcile: { Task { await model.reconcile() } },
                                canFinishReplacement: model.canFinishReplacements,
                                onFinishReplacement: { Task { await model.finishReplacement(jobID: event.jobID) } })
                                .accessibilityElement(children: .contain).accessibilityIdentifier("export.job.\(event.jobID.uuidString)")
                            Divider()
                        }
                        Button("Reload Photos") { Task { await model.reloadLibrary() } }
                        if model.isLoadingLibrary { ProgressView("Reading Photos…") }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Settings").font(.headline)
                            Toggle(isOn: Binding(get: { model.settings.updateOriginalInPhotos },
                                                 set: { model.settings.updateOriginalInPhotos = $0 })) {
                                Text("Update original in Photos").foregroundStyle(.red)
                            }
                            .tint(.red)
                            .accessibilityIdentifier("settings.updateOriginalInPhotos")
                            Text("RAW-only photos become a new RAW+JPEG pair; the old asset is removed after verification. Existing pairs preserve their originals and support Revert to Original in Photos. Only the latest edit appears in image versions. Applies to new export jobs.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.updateOriginalExplanation")
                        }
                    }.padding()
                }
                    .accessibilityIdentifier("app.statusScroll")
                    .navigationTitle("Status & settings")
                    .toolbar { Button("Done", action: closeStatus) }
                    .navigationDestination(for: StatusDestination.self) { destination in
                        switch destination {
                        case .cameraBrowser:
                            CameraBrowserView(model: model, onBack: popStatus, onImport: {
                                statusPath.append(.cameraImports)
                                Task { await model.importSelectedCaptures() }
                            }, onSetUpAutoSave: setUpAutoSaveFromBrowser)
                        case .autoSave:
                            AutoSaveSetupView(model: model, connection: connection, onBack: popStatus, onBrowse: { statusPath = [.cameraBrowser] })
                        case .cameraImports:
                            CameraImportProgressView(model: model, onBack: popStatus, onViewImported: { cameraMode = false; closeStatus() })
                        }
                    }
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .sheet(isPresented: $handoffPresented) { handoffSheet }
    }

    @ViewBuilder private var handoffSheet: some View {
        if let network = model.wirelessState.manualNetwork {
            CameraNetworkInstructions(network: network, connection: model.environment.wireless.connection,
                                      openSettings: model.openSettings)
        }
    }

    private var showsCameraPhotos: Bool {
        let wireless = model.wirelessState
        return wireless.bluetooth == .ready || wireless.manualNetwork != nil || wireless.wifi == .ready
    }

    @ViewBuilder private var cameraPhotosButton: some View {
        let wireless = model.wirelessState
        if showsCameraPhotos {
            Button {
                if wireless.wifi == .ready { cameraMode.toggle() }
                else if wireless.manualNetwork != nil { handoffPresented = true }
                else {
                    Task {
                        await model.connectCameraWiFi()
                        if model.wirelessState.wifi != .ready { cameraPhotoError = model.wirelessState.transferFailureGuidance }
                    }
                }
            } label: {
                Label(cameraMode ? "Phone Photos" : "Camera Photos", systemImage: cameraMode ? "iphone" : "camera")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .disabled(wireless.manualNetwork == nil && wireless.wifi != .idle && wireless.wifi != .ready)
            .accessibilityIdentifier("workspace.cameraPhotos")
        }
    }

    private func loadViewedOriginal(_ request: CameraBrowserModel.ViewerRequest?) async {
        viewerFile = nil
        cameraPreview = nil
        viewerFailure = nil
        viewedRequest = request
        guard let request else { return }
        if let original = request.original, let file = browser.alreadyViewed(original) {
            viewerFile = file
            return
        }
        if let capture = browser.capture(for: request.id), let previewObject = request.thumbnail,
           let data = await browser.thumbnail(for: capture) {
            let preview = await Task.detached { try? DisplayFileLease.cameraPreview(data, object: previewObject) }.value
            guard !Task.isCancelled, self.request == request else { return }
            cameraPreview = preview
        }
        guard !Task.isCancelled else { return }
        guard let object = request.original else {
            if cameraPreview == nil { viewerFailure = "Choose RAW in Image versions to load this photo." }
            return
        }
        do {
            let file = try await browser.viewerFile(for: object)
            guard !Task.isCancelled, self.request == request else { return }
            viewerFile = file
            cameraPreview = nil
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            cameraPreview = nil
            viewerFailure = (error as? WirelessFailure)?.connectionGuidance ?? "Couldn’t load this original from the camera."
        }
    }

    private func saveCameraPhotos() {
        do { try browser.selectWorkspacePhotos() }
        catch {
            cameraPhotoError = "These originals can’t be saved together. Check the card for ambiguous file matches."
            return
        }
        statusPath = [.cameraImports]
        statusPresented = true
        Task { await model.importSelectedCaptures() }
    }

    private var statusButton: some View {
        CameraStatusControl(state: CameraIndicatorState(camera: model.state.cameraState,
            refreshingRecipes: model.isRefreshing || model.isResettingCamera,
            hasError: model.cameraError != nil || model.cameraResetError != nil), label: statusLabel,
            exportProgress: model.exportEvent?.activeProgress, wireless: wirelessStatus, bluetooth: model.wirelessState.bluetooth) {
            statusPath.removeAll()
            statusPresented = true
        }
    }
    private func popStatus() {
        if !statusPath.isEmpty { statusPath.removeLast() }
    }
    private func closeStatus() {
        connection.cancel { pending in await model.cancelWirelessConnection(draining: pending) }
        statusPresented = false
    }
    private func setUpAutoSaveFromBrowser() {
        Task {
            await model.disconnectCameraWiFi()
            if statusPresented, statusPath.last == .cameraBrowser {
                statusPath = model.wirelessState.hasTransferLease ? [] : [.autoSave]
            }
        }
    }
    private var wirelessStatus: WirelessStatusSummary? {
        guard model.wirelessAvailable else { return nil }
        return WirelessStatusSummary(state: model.wirelessState, activeImport: model.activeCameraImport,
                                     preparingImport: model.isPreparingImport)
    }
    private var statusLabel: String {
        if model.isResettingCamera { return "Resetting camera connection…" }
        if model.cameraError != nil || model.cameraResetError != nil { return "Camera error" }
        if model.cameraImportActive, let wirelessStatus { return wirelessStatus.label }
        if model.wirelessState.bluetooth == .ready, let wirelessStatus { return wirelessStatus.label }
        if model.isLoadingLibrary { return "Reading Photos…" }
        if let event = model.exportEvent {
            let count = event.summary.replacementCleanup > 0 ? "\(event.summary.exported) exported" : "\(event.summary.completed) saved"
            return "\(event.recipeLabel) · \(count) · \(ExportProgressView.status(event))"
        }
        if model.message != nil || model.connectionError != nil { return "Action needed" }
        if model.state.libraryAccess == .denied || model.state.libraryAccess == .restricted { return "Photos access needed" }
        if model.isRefreshing { return "Importing camera recipes…" }
        switch model.state.cameraState {
        case .authorizationDenied: return "Camera access needed"
        case .wrongMode: return "Check camera USB mode"
        default: break
        }
        if model.isConnecting { return "Looking for camera…" }
        if let wirelessStatus { return wirelessStatus.label }
        return model.state.currentCameraExecutionContext == nil ? "Photos · Camera disconnected" : "Photos · Camera ready"
    }
    private var accessMessage: String {
        switch model.state.libraryAccess {
        case .full: "Photos access is allowed. Original RAW and RAW + JPEG photos appear here."
        case .limited: "Only selected Photos are accessible. Use Manage Photos to include originals and saved outputs."
        case .denied: "Photos access is denied. Allow access in Settings to browse original photos."
        case .restricted: "Photos access is restricted on this device. Check your device's Settings."
        case .notDetermined: "Allow Photos access to browse original RAW photos."
        }
    }
    private var cameraMessage: String {
        if model.state.wirelessRestrictsUSB {
            return "USB conversion is unavailable while WiFi import uses the camera."
        }
        let manualUSBConnection = model.wirelessAvailable
            && (!model.wirelessState.hasLoadedSavedCameraPreference || model.wirelessState.selectedCameraID != nil)
        if manualUSBConnection, case .disconnected = model.state.cameraState {
            return "For USB conversion, plug in a data cable, select USB RAW CONV./BACKUP RESTORE on the camera and tap Reset camera connection."
        }
        return switch model.state.cameraState {
        case .ready: "\(model.state.currentCameraExecutionContext?.model ?? "Camera") ready for conversion over USB."
        case .busy: "The USB camera is processing the current operation."
        case .attentionRequired: "Camera connection needs attention. Reset the connection to try again."
        case .authorizationRequired: "Allow camera control to read recipes and convert RAWs over USB. This does not take new pictures."
        case .authorizationDenied: manualUSBConnection
            ? "Camera control is denied. Allow it in Settings, then tap Reset camera connection."
            : "Camera control is denied. Allow it in Settings, then return to Fuji Studio to connect automatically."
        case .wrongMode: "Set the camera USB connection mode to USB RAW CONV./BACKUP RESTORE. Use a USB data cable."
        case .recoverableError: manualUSBConnection
            ? "Camera connection interrupted. Check its USB mode and data cable, then tap Reset camera connection."
            : "Camera connection interrupted. Check its USB mode and data cable. Fuji Studio reconnects automatically."
        case .opening, .discovering, .sessionOpen: "Connecting and verifying the USB camera…"
        case .disconnected: "Plug in a supported Fujifilm camera with a USB data cable in USB RAW CONV./BACKUP RESTORE mode. Fuji Studio connects automatically and retries every three seconds while active. Browsing originals and saved versions works without the camera."
        }
    }
}
