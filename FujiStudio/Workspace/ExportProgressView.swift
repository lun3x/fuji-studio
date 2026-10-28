import SwiftUI

struct ExportProgressView: View {
    let event: ExportEvent
    let canResume: Bool
    let onCancel: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onReconcile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(event.recipeLabel).font(.headline).accessibilityIdentifier("export.recipe")
            Text(Self.status(event)).accessibilityIdentifier("export.status")
            Text("\(event.summary.completed) saved · \(event.summary.failed) failed · \(event.summary.skipped) cancelled · \(event.summary.unprocessed) remaining · \(event.summary.unresolved) unconfirmed")
                .accessibilityIdentifier("export.counts")
            ForEach(Array(event.failures.enumerated()), id: \.offset) { _, failure in
                Text(Self.failureMessage(failure)).accessibilityIdentifier("export.failure")
            }
            if case .camera(let failure) = event.pauseReason { Text(Self.failureMessage(failure)) }
            if case .persistence = event.pauseReason { Text("The local catalog could not be updated. Recovery records and existing exports are retained.") }
            if !event.terminal {
                ProgressView()
                Button(event.stopRequested ? "Stopping safely…" : "Cancel remaining", action: onCancel).disabled(event.stopRequested)
                    .accessibilityIdentifier("export.cancel")
            } else if event.summary.unresolved > 0 {
                Text("Photos has not confirmed this save. Reconciliation checks the same operation; it does not create a replacement export.")
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
    static func failureMessage(_ failure: ExportFailure) -> String {
        switch failure {
        case .authorization: "Photos access is required. Check Settings before retrying."
        case .inaccessible: "An original photo is no longer accessible. Check your Photos selection."
        case .insufficientStorage: "There is not enough storage. Free some space before retrying."
        case .unsupportedSettings: "The selected recipe has unsupported conversion settings."
        case .transport: "Camera connection interrupted. Check the USB data cable and camera mode."
        case .preparation: "An original could not be prepared. Check its availability and iCloud download, then retry."
        case .unresolvedSave: "Photos has not confirmed this save. Check Photos again before retrying."
        }
    }
    static func status(_ event: ExportEvent) -> String {
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
    var body: some View {
        WorkspaceView(state: model.state, sources: model.sources, thumbnails: model.environment.thumbnails,
            imageURL: model.displayFile?.fileURL, imageGeometry: model.displayFile?.geometry,
            displayFile: model.displayFile, imageIdentity: model.imageIdentity,
            detail: model.detail, imageLoading: model.imageLoading, imageStatus: model.imageStatus,
            imageStatusIsFailure: model.imageStatusIsFailure,
            savedVersions: model.savedVersions, exportPending: model.isSubmitting, previewLoading: model.isLoadingPreview,
            onAction: model.send, onRefreshRecipes: { Task { await model.refreshRecipes() } },
            onExport: { Task { await model.export() } },
            statusControl: { statusButton })
        .sheet(isPresented: $statusPresented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(accessMessage).accessibilityIdentifier("app.access")
                        if model.state.libraryAccess == .limited { Button("Manage Photos", action: model.managePhotos).accessibilityIdentifier("app.managePhotos") }
                        if model.state.libraryAccess == .denied || model.state.libraryAccess == .restricted { Button("Open Settings", action: model.openSettings) }
                        Text(cameraMessage).accessibilityIdentifier("app.camera")
                        if let reason = model.state.exportDisabledReason { Text(reason.message).accessibilityIdentifier("app.exportDisabledReason") }
                        if case .authorizationDenied = model.state.cameraState { Button("Open Settings", action: model.openSettings) }
                        if let message = model.message { Text(message).accessibilityIdentifier("app.error") }
                        if let error = model.connectionError { Text(error).accessibilityIdentifier("app.connectionError") }
                        ForEach(model.progressEvents, id: \.jobID) { event in
                            ExportProgressView(event: event, canResume: !model.isSuspended && !model.isSubmitting && model.state.currentCameraExecutionContext != nil,
                                onCancel: { Task { await model.cancelExport(jobID: event.jobID) } }, onResume: { Task { await model.resumeExport(jobID: event.jobID) } },
                                onRetry: { Task { await model.resumeExport(jobID: event.jobID, retry: true) } }, onReconcile: { Task { await model.reconcile() } })
                                .accessibilityElement(children: .contain).accessibilityIdentifier("export.job.\(event.jobID.uuidString)")
                            Divider()
                        }
                        Button("Reload Photos") { Task { await model.reloadLibrary() } }
                        if model.isLoadingLibrary { ProgressView("Reading Photos…") }
                    }.padding()
                }.navigationTitle("Fuji Studio status")
                    .toolbar { Button("Done") { statusPresented = false } }
            }
        }
    }
    private var statusButton: some View {
        Button { statusPresented = true } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: model.exportEvent == nil ? "info.circle" : "arrow.up.doc")
                    .font(.system(size: 24)).frame(minWidth: 44, minHeight: 44)
            } else {
                Label(statusTitle, systemImage: model.exportEvent == nil ? "info.circle" : "arrow.up.doc")
                    .lineLimit(1).font(.caption).frame(minHeight: 44).contentShape(Rectangle())
            }
        }.accessibilityLabel(statusLabel).accessibilityIdentifier("app.status")
    }
    private var statusTitle: String {
        switch statusLabel {
        case "Photos · Camera disconnected": "Disconnected"
        case "Photos · Camera ready": "Ready"
        default: statusLabel
        }
    }
    private var statusLabel: String {
        if model.isLoadingLibrary { return "Reading Photos…" }
        if let event = model.exportEvent { return "\(event.recipeLabel) · \(event.summary.completed) saved · \(ExportProgressView.status(event))" }
        if model.message != nil || model.connectionError != nil { return "Action needed" }
        if model.state.libraryAccess == .denied || model.state.libraryAccess == .restricted { return "Photos access needed" }
        if model.isRefreshing { return "Importing seven recipes…" }
        switch model.state.cameraState {
        case .authorizationDenied: return "Camera access needed"
        case .wrongMode: return "Check camera USB mode"
        default: break
        }
        if model.isConnecting { return "Looking for camera…" }
        return model.state.currentCameraExecutionContext == nil ? "Photos · Camera disconnected" : "Photos · Camera ready"
    }
    private var accessMessage: String {
        switch model.state.libraryAccess {
        case .full: "Photos access is allowed. Original RAW and RAW + JPEG photos appear here; exports remain separate versions."
        case .limited: "Only selected Photos are accessible. Use Manage Photos to include originals and saved outputs."
        case .denied: "Photos access is denied. Allow access in Settings to browse original photos."
        case .restricted: "Photos access is restricted on this device. Check your device's Settings."
        case .notDetermined: "Allow Photos access to browse original RAW photos."
        }
    }
    private var cameraMessage: String {
        switch model.state.cameraState {
        case .ready: "X-T5 ready for conversion."
        case .busy: "X-T5 is processing the current operation."
        case .authorizationRequired: "Allow camera control to read recipes and convert RAWs over USB. This does not take new pictures."
        case .authorizationDenied: "Camera control is denied. Allow it in Settings, then return to Fuji Studio to connect automatically."
        case .wrongMode: "Set the X-T5 USB connection mode to USB RAW CONV./BACKUP RESTORE. Use a USB data cable."
        case .recoverableError: "Camera connection interrupted. Check its USB mode and data cable. Fuji Studio reconnects automatically."
        case .opening, .discovering, .sessionOpen: "Connecting and verifying the X-T5…"
        case .disconnected: "Plug in an X-T5 with a USB data cable in USB RAW CONV./BACKUP RESTORE mode. Fuji Studio connects automatically and retries every three seconds while active. Browsing originals and saved versions works without the camera."
        }
    }
}
