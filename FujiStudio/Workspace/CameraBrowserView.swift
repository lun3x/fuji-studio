import FujiCameraCore
import ImageIO
import SwiftUI
import UIKit

struct CameraBrowserView: View {
    let model: AppModel
    let onBack: () -> Void
    let onImport: () -> Void
    let onSetUpAutoSave: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectionError: String?

    private var browser: CameraBrowserModel { model.cameraBrowser }
    private var isConnected: Bool { model.wirelessState.wifi == .ready && !model.isDisconnectingWireless }
    private var isLocked: Bool { model.cameraImportActive || browser.thumbnailsSuspended }
    private var canSelect: Bool {
        isConnected && !isLocked && !model.isSuspended && browser.canSelectOriginals && !browser.isLoading
    }
    private var isXE3: Bool {
        model.wirelessState.savedCameras.contains {
            $0.id == model.wirelessState.selectedCameraID && $0.model == .xe3
        }
    }
    private var inlineActions: Bool { typeSize.isAccessibilitySize || verticalSizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if inlineActions { selectionActions }
                browserStatus
                captureGroups
            }
        }
        .accessibilityIdentifier("cameraBrowser.scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !inlineActions {
                selectionActions.background(.bar)
            }
        }
        .navigationTitle("Camera photos")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CameraFlowBackButton(label: "Back to camera connection", identifier: "cameraBrowser.done", action: onBack)
            }
        }
    }

    private var captureGroups: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(browser.dayGroups) { group in
                Section {
                    ForEach(group.captures, id: \.rowID) { capture in
                        CameraCaptureRow(browser: browser, capture: capture, canSelect: canSelect) { policy in
                            select(capture, policy: policy)
                        }
                        Divider().padding(.leading)
                    }
                } header: {
                    Text(group.label)
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("cameraBrowser.day.\(group.day ?? "unknown")")
                }
            }
        }
    }

    @ViewBuilder private var browserStatus: some View {
        if model.importJournalIssue != nil {
            CameraImportJournalIssue().padding()
        }
        if !isConnected || browser.requiresFreshSession {
            Text((browser.failure ?? model.wirelessState.wifiFailure)?.connectionGuidance
                 ?? "Connect over WiFi in Status & settings to browse the camera again.")
                .padding().accessibilityIdentifier("cameraBrowser.connectionStatus")
        } else if browser.isLoading {
            ProgressView("Reading camera files…").padding()
                .accessibilityIdentifier("cameraBrowser.loading")
        } else if browser.inventory.rawExposure == .unavailable || !browser.canSelectOriginals && !browser.captures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RAW unavailable").font(.headline).accessibilityIdentifier("cameraBrowser.rawUnavailable")
                if isXE3 {
                    Text("The current camera connection does not expose verified original RAW files.")
                } else {
                    Text((browser.originalSizeFailure ?? .originalSizeUnavailable).connectionGuidance)
                }
                if isXE3 {
                    Button("Set up RAW transfer", action: onSetUpAutoSave)
                        .disabled(model.cameraImportActive)
                        .accessibilityIdentifier("cameraBrowser.autoSave")
                }
            }
            .padding()
        } else if browser.captures.isEmpty {
            Text("No photos found on the camera.").padding()
        }
        if let selectionError {
            Text(selectionError).foregroundStyle(.red).padding()
                .accessibilityIdentifier("cameraBrowser.error")
        }
    }

    private var selectionActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(browser.selectedCount == 1 ? "1 photo selected" : "\(browser.selectedCount) photos selected")
                .font(.headline).accessibilityIdentifier("cameraBrowser.selection")
            if browser.selectedCount > 0 {
                Text("Estimated size \(cameraImportByteCount(browser.knownByteEstimate))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cameraBrowser.bytes")
            }
            Button(action: onImport) {
                Text(browser.selectedCount == 1 ? "Import 1 photo" : "Import \(browser.selectedCount) photos")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSelect || browser.selectedCount == 0 || model.importJournalIssue != nil)
            .accessibilityIdentifier("cameraBrowser.import")
        }
        .padding()
    }

    private func select(_ capture: CameraCapture, policy: ImportPolicy) {
        guard canSelect else { return }
        selectionError = nil
        if browser.selectedPolicy(for: capture.id) == policy {
            browser.deselect(capture.id)
        } else {
            do { try browser.select(capture.id, policy: policy) }
            catch CameraBrowserSelectionError.ambiguousCapture {
                selectionError = "Multiple card files match this photo. Select an unambiguous original."
            } catch let failure as WirelessFailure {
                selectionError = failure.connectionGuidance
            } catch {
                selectionError = "This original cannot be selected. Wait for the camera files to finish checking."
            }
        }
    }
}

private struct CameraCaptureRow: View {
    let browser: CameraBrowserModel
    let capture: CameraCapture
    let canSelect: Bool
    let onSelect: (ImportPolicy) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnail: Thumbnail?

    private struct Thumbnail {
        let object: WirelessObjectDescriptor
        let image: UIImage
    }

    private struct ThumbnailRequest: Equatable {
        let object: WirelessObjectDescriptor?
        let suspended: Bool
    }

    private var policy: ImportPolicy? { browser.selectedPolicy(for: capture.id) }
    private var verified: Bool { browser.importReceiptStatus(for: capture) == .verified }
    private var captureDay: String { capture.timestamp?.calendarDay ?? "Capture date unknown" }
    private var rowIdentifier: String { "\(capture.rowID.storageID).\(capture.rowID.handle)" }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        let request = ThumbnailRequest(object: capture.thumbnailObject, suspended: browser.thumbnailsSuspended)
        layout {
            preview
            VStack(alignment: .leading, spacing: 6) {
                if capture.availability == .pair {
                    pairButton
                } else {
                    rowText
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("cameraBrowser.format.\(rowIdentifier)")
                }
                if capture.raw != nil && (capture.availability == .rawOnly || capture.availability == .ambiguous) && !verified {
                    Button {
                        onSelect(.rawOnly)
                    } label: {
                        Label("Import RAW only", systemImage: policy == .rawOnly ? "checkmark.circle.fill" : "circle")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canSelect || !browser.permitsSelection(for: capture.id, policy: .rawOnly))
                    .accessibilityLabel("Import RAW only")
                    .accessibilityValue(policy == .rawOnly ? "Selected" : "Not selected")
                    .accessibilityHint("\(capture.rowID.filename), \(captureDay)")
                    .accessibilityAddTraits(policy == .rawOnly ? .isSelected : [])
                    .accessibilityIdentifier("cameraBrowser.rawOnly.\(rowIdentifier)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .task(id: request) {
            guard !request.suspended, let object = request.object, thumbnail?.object != object,
                  let data = await browser.thumbnail(for: capture), !Task.isCancelled else { return }
            let preview = await Task.detached { CameraThumbnail.decode(data) }.value
            guard !Task.isCancelled, let preview else { return }
            thumbnail = Thumbnail(object: object, image: UIImage(cgImage: preview.image))
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground))
            if let thumbnail, thumbnail.object == capture.thumbnailObject {
                Image(uiImage: thumbnail.image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 54)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var rowText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.rowID.filename).font(.body)
            Text(capture.availability.formatLabel).font(.subheadline).foregroundStyle(.secondary)
            if verified {
                Label("Imported", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(captureDay).font(.subheadline).foregroundStyle(.secondary)
            if capture.availability == .jpegOnly || capture.availability == .unsupported {
                Text("Camera import requires an original RAF.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var pairButton: some View {
        Button { onSelect(.pair) } label: {
            HStack(alignment: .top, spacing: 10) {
                rowText
                Spacer(minLength: 0)
                if !verified {
                    Image(systemName: policy == .pair ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(policy == .pair ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect || (verified && policy == nil) || !browser.permitsSelection(for: capture.id, policy: .pair))
        .accessibilityLabel("\(capture.rowID.filename), \(capture.availability.formatLabel), \(captureDay)")
        .accessibilityValue(verified ? "Imported" : policy == .pair ? "Selected" : "Not selected")
        .accessibilityAddTraits(policy == .pair ? .isSelected : [])
        .accessibilityIdentifier("cameraBrowser.select.\(rowIdentifier)")
    }
}

// CGImage is immutable. Keep the decode off the main actor and create UIImage in the row.
struct CameraThumbnail: @unchecked Sendable {
    let image: CGImage

    static func decode(_ data: Data) -> Self? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
                let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 288,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary) else { return nil }
            return CameraThumbnail(image: image)
        }
    }
}

private extension CaptureAvailability {
    var formatLabel: String {
        switch self {
        case .checking: "Checking files"
        case .pair: "RAW+JPEG"
        case .rawOnly: "RAW"
        case .jpegOnly: "JPEG only"
        case .rawUnavailable: "RAW unavailable"
        case .ambiguous: "File pairing unclear"
        case .unsupported: "Unsupported format"
        }
    }
}

struct CameraFlowBackButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "chevron.backward") }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
