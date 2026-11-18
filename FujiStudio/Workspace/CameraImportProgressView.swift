import FujiCameraCore
import SwiftUI

struct CameraImportProgressView: View {
    let model: AppModel
    let focusedJobID: UUID?
    let onBack: () -> Void
    let onViewImported: () -> Void

    private var events: [ImportEvent] {
        if let focusedJobID { return model.importEvents.filter { $0.jobID == focusedJobID } }
        return model.importEvents.sorted {
            let lhs = $0.jobContext?.startedAt ?? .distantPast
            let rhs = $1.jobContext?.startedAt ?? .distantPast
            return lhs == rhs ? $0.sequence > $1.sequence : lhs > rhs
        }
    }

    private var preparationLabel: String {
        if model.isWaitingForImportInventory {
            return "Checking the camera card for the remaining originals… \(model.cameraBrowser.captures.count) photos found."
        }
        return model.isFindingCameraMates ? "Looking for matching JPEGs on the camera…" : "Preparing camera originals…"
    }

    var body: some View {
        let events = events
        let shortReferences = Dictionary(grouping: events.compactMap(\.jobID)) { String($0.uuidString.prefix(8)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isPreparingImport {
                    ProgressView(preparationLabel)
                        .accessibilityIdentifier("cameraImport.preparing")
                    if model.isFindingCameraMates {
                        Button("Cancel") { model.cancelFindingCameraMates(); onBack() }
                    }
                }
                if model.importJournalIssue != nil { CameraImportJournalIssue() }
                if let error = model.importActionError {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("cameraImport.error")
                    if model.state.libraryAccess != .full && !events.contains(where: { $0.actions.contains(.managePhotos) }) {
                        Button("Manage Photos") { Task { await model.manageImportPhotos() } }
                            .accessibilityIdentifier("cameraImport.managePhotos")
                        Button("Open Settings", action: model.openSettings)
                            .accessibilityIdentifier("cameraImport.settings")
                    }
                }
                ForEach(events, id: \.jobID) { event in
                    if let jobID = event.jobID {
                        let shortReference = String(jobID.uuidString.prefix(8))
                        let reference = shortReferences[shortReference]?.count == 1 ? shortReference : jobID.uuidString
                        CameraImportJobView(model: model, event: event, jobID: jobID, reference: reference,
                                            onViewImported: onViewImported)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("cameraImport.scroll")
        .navigationTitle("Camera imports")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CameraFlowBackButton(label: "Back from camera imports", identifier: "cameraImport.done", action: onBack)
            }
        }
    }
}

struct CameraImportJournalIssue: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera import recovery required").font(.headline)
            Text("The import journal could not be read or updated. Check available iPhone storage and reopen Fuji Studio to retry recovery. Keep the app installed to preserve retained originals.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cameraImport.journalIssue")
    }
}

private struct CameraImportJobView: View {
    let model: AppModel
    let event: ImportEvent
    let jobID: UUID
    let reference: String
    let onViewImported: () -> Void
    @State private var confirmingDiscard = false

    private var canResume: Bool {
        model.hasResumeConnection(for: event)
    }
    private var canCommand: Bool {
        model.canRunCameraImportCommand
    }
    private var canRetry: Bool {
        canCommand && (!event.needsSession || event.canRetryFromStagedOriginals || canResume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(contextTitle).font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("cameraImport.jobContext")
            if let context = event.jobContext {
                Text("Started \(context.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                if let filename = context.firstFilename {
                    Text("First original \(filename)").foregroundStyle(.secondary)
                }
            }
            Text(status).font(.headline)
                .accessibilityIdentifier("cameraImport.status")
            Text(event.captureCountLabel).accessibilityIdentifier("cameraImport.counts")
            if let component = event.component {
                let componentLabel = component.role == .raf ? "RAW download" : "JPEG download"
                let received = cameraImportByteCount(component.receivedBytes)
                let expected = cameraImportByteCount(component.expectedBytes)
                ProgressView(value: Double(component.receivedBytes), total: Double(max(component.expectedBytes, 1))) {
                    Text(componentLabel)
                } currentValueLabel: {
                    Text("\(received) of \(expected)")
                }
                .accessibilityLabel(componentLabel)
                .accessibilityValue("\(received) of \(expected)")
                .accessibilityIdentifier("cameraImport.progress")
            } else if event.isRunning && event.pauseReason == nil {
                ProgressView().accessibilityLabel(status).accessibilityIdentifier("cameraImport.progress")
            }
            if event.retainedBytes > 0 {
                Text("\(cameraImportByteCount(event.retainedBytes)) retained on this iPhone")
                    .accessibilityIdentifier("cameraImport.retainedBytes")
            }
            if let systemError = event.photoSaveError {
                Text("Photos reported error \(systemError).")
            }
            if let guidance {
                Text(guidance).accessibilityIdentifier("cameraImport.guidance")
            }
            if let failure = event.wirelessFailure {
                Text(failure.connectionGuidance).accessibilityIdentifier("cameraImport.wirelessFailure")
            }
            if event.actions.contains(.resume) && !canResume {
                Text("Open Camera Photos and connect to the Wi-Fi of the camera used for this import.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraImport.job.\(jobID.uuidString)")
        .alert("Discard remaining originals?", isPresented: $confirmingDiscard) {
            Button("Discard remaining", role: .destructive) { Task { await model.discardImport(jobID: jobID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(contextTitle)\n\nThis removes retained files for unfinished photos from this iPhone. Camera files and verified photos stay where they are.")
        }
    }

    private var contextTitle: String {
        guard let context = event.jobContext else { return "Import \(reference)" }
        let modelName = context.cameraModel.rawValue
        let cameraName = if let displayName = context.cameraDisplayName {
            displayName.localizedCaseInsensitiveContains(modelName) ? displayName : "\(displayName) (\(modelName))"
        } else {
            modelName
        }
        return "\(cameraName) · Import \(reference)"
    }

    @ViewBuilder private var actions: some View {
        if event.actions.contains(.cancelRemaining) {
            Button("Cancel", role: .destructive) { Task { await model.cancelImport(jobID: jobID) } }
                .disabled(!event.isRunning && !canCommand)
                .accessibilityHint("Stop after the current camera or Photos operation")
                .accessibilityIdentifier("cameraImport.cancel")
        }
        if event.actions.contains(.pause) {
            Button("Pause") { Task { await model.pauseImport(jobID: jobID) } }
                .accessibilityIdentifier("cameraImport.pause")
        }
        if event.actions.contains(.managePhotos) && model.state.libraryAccess != .full {
            Button("Manage Photos") { Task { await model.manageImportPhotos() } }
                .disabled(!canCommand).accessibilityIdentifier("cameraImport.managePhotos")
            Button("Open Settings", action: model.openSettings)
                .accessibilityIdentifier("cameraImport.settings")
        }
        if event.actions.contains(.resume) {
            Button("Resume remaining") { Task { await model.resumeImport(jobID: jobID) } }
                .buttonStyle(.borderedProminent)
                .disabled(!canCommand || !canResume)
                .accessibilityIdentifier("cameraImport.resume")
        }
        if event.actions.contains(.retryCapture) {
            Button("Retry") { Task { await model.retryImportCapture(jobID: jobID) } }
                .disabled(!canRetry).accessibilityIdentifier("cameraImport.retry")
        }
        if event.actions.contains(.skipCapture) {
            Button("Skip") { Task { await model.skipImportCapture(jobID: jobID) } }
                .disabled(!canCommand).accessibilityIdentifier("cameraImport.skip")
        }
        if event.actions.contains(.discardRemaining) {
            Button("Discard remaining", role: .destructive) { confirmingDiscard = true }
                .disabled(!canCommand).accessibilityIdentifier("cameraImport.discard")
        }
        if !event.receipts.isEmpty {
            Button("View imported") {
                Task {
                    await model.viewImported(jobID: jobID)
                    if model.importActionError == nil,
                       !model.state.checkedSourceIDs.isDisjoint(with: event.receipts.map(\.assetID)) {
                        onViewImported()
                    }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cameraImport.viewImported")
        }
    }

    private var status: String {
        if event.pauseReason == .journalUnavailable { return "Camera import recovery required" }
        if let active = event.activeStatusLabel { return active }
        if event.stage == .savedUnverified && !event.isRunning { return "Photos save unverified" }
        if event.stage == .submitting && !event.isRunning { return "Photos save unconfirmed" }
        if event.pauseReason == .cancelled { return "Import cancelled" }
        if event.captureIndex != nil {
            return event.pauseReason == .captureFailed ? "Photo import failed" : "Import paused"
        }
        if event.receipts.isEmpty { return "No photos imported" }
        return event.receipts.count == event.captureCount ? "Import complete" : "Import finished"
    }

    private var guidance: String? {
        switch event.pauseReason {
        case .unresolvedSave:
            if event.actions.contains(.retryCapture) {
                "Photos has no asset for this save. Tap Retry to save the originals already on this iPhone."
            } else if model.state.libraryAccess == .full {
                "Fuji Studio could not confirm both the save and its original files in Photos. The originals are still on this iPhone. Reopen Fuji Studio to check the same save again."
            } else {
                "Allow Photos access so Fuji Studio can check the same save. The originals are still on this iPhone."
            }
        case .earlierSaveUnresolved:
            "An earlier import of this RAW still has an unverified Photos save. Check that import in Camera imports before retrying. The staged originals remain on this iPhone."
        case .photosAccess:
            "Allow read and write Photos access before retrying the save."
        case .freshSelectionRequired:
            "Camera files changed. Browse the card and select your photos again."
        case .storage:
            "Free iPhone storage before resuming."
        case .journalUnavailable:
            "The import journal needs recovery. Check available iPhone storage and reopen Fuji Studio."
        case .backgrounded, .connectionLost, .interrupted:
            event.retainedBytes > 0
                ? "Resuming may read the retained originals from the card again to verify their contents."
                : "Keep Fuji Studio open while importing over WiFi."
        default:
            nil
        }
    }
}

func cameraImportByteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
