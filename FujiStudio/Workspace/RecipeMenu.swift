import SwiftUI
import UIKit

/// A floating trigger and native popover; dismissal never dispatches a selection.
struct RecipeMenu: View {
    let current: RecipeSnapshot?
    let snapshots: [RecipeSnapshot]
    let phoneSnapshots: [RecipeSnapshot]
    let refreshState: RecipeRefreshState
    let isCameraConnected: Bool
    var onSelect: (Int?) -> Void
    var onSelectPhone: (UUID) -> Void
    var onCopyToPhone: (UUID) async -> Bool
    var onRefresh: () -> Void
    var onControlFrameChanged: (CGRect) -> Void = { _ in }
    @State private var presented: Bool
    private enum Collection { case camera, phone }
    @State private var collection: Collection
    @State private var copyingID: UUID?
    @State private var copyFailed = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    init(current: RecipeSnapshot?, snapshots: [RecipeSnapshot], phoneSnapshots: [RecipeSnapshot],
         refreshState: RecipeRefreshState, isCameraConnected: Bool,
         onSelect: @escaping (Int?) -> Void, onSelectPhone: @escaping (UUID) -> Void,
         onCopyToPhone: @escaping (UUID) async -> Bool, onRefresh: @escaping () -> Void,
         onControlFrameChanged: @escaping (CGRect) -> Void = { _ in }, initiallyPresented: Bool = false) {
        self.current = current; self.snapshots = snapshots; self.refreshState = refreshState
        self.phoneSnapshots = phoneSnapshots; self.onSelectPhone = onSelectPhone; self.onCopyToPhone = onCopyToPhone
        self.isCameraConnected = isCameraConnected
        self.onSelect = onSelect; self.onRefresh = onRefresh; self.onControlFrameChanged = onControlFrameChanged
        _presented = State(initialValue: initiallyPresented)
        _collection = State(initialValue: current?.isPhoneRecipe == true ? .phone : .camera)
    }
    var body: some View {
        Button {
            collection = current?.isPhoneRecipe == true ? .phone : .camera
            copyFailed = false; presented = true
        } label: {
            Group {
                if current?.isPhoneRecipe == true { Image(systemName: "iphone").font(.headline) }
                else if let current { Text("C\(current.slot)").font(.headline.monospacedDigit()) }
                else { Image(systemName: "camera.filters").font(.headline) }
            }.frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .foregroundStyle(.primary)
        .background {
            if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .overlay { if contrast == .increased { Capsule().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel(current?.displayLabel ?? "No recipe selected")
        .accessibilityHint("Choose camera or phone recipes, or copy a camera recipe to your phone")
        .accessibilityIdentifier("recipe.control")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("workspace")) }, action: onControlFrameChanged)
        .popover(isPresented: $presented, arrowEdge: .top) {
            options.environment(\.dynamicTypeSize, dynamicTypeSize)
                .background { PopoverEscapeHandler(onDismiss: { presented = false }).frame(width: 1, height: 1) }
                .presentationCompactAdaptation(.popover)
        }
    }
    private var options: some View {
        VStack(spacing: 0) {
            Picker("Recipe collection", selection: $collection) {
                Text("Camera").tag(Collection.camera)
                Text("Phone").tag(Collection.phone)
            }
            .pickerStyle(.segmented).padding()
            .accessibilityIdentifier("recipe.collection")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(title: "No recipe", selected: current == nil, identifier: "recipe.none") { choose(nil) }
                    if collection == .camera { cameraOptions }
                    else { phoneOptions }
                }
            }
            .accessibilityIdentifier("recipe.options")
        }
        .frame(idealWidth: 340, maxHeight: 520)
    }

    private var cameraOptions: some View {
        Group {
            if case .stale(let message) = refreshState {
                Label(message, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.callout).padding(.horizontal).padding(.bottom, 8)
                    .accessibilityIdentifier("recipe.stale")
            }
            if copyFailed {
                Text("Couldn’t save this recipe. Tap the copy icon to try again.")
                    .font(.callout).foregroundStyle(.red).padding()
                    .accessibilityIdentifier("recipe.copy.error")
            }
            ForEach(1...7, id: \.self) { slot in
                let recipe = snapshots.first { $0.slot == slot }
                HStack(spacing: 0) {
                    Button { choose(slot) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("C\(slot) \(recipe?.name ?? "Not imported")")
                                if let recipe, case .unsupported = recipe.renderingSupport {
                                    Text("Cached · conversion unsupported").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if current?.id == recipe?.id, recipe != nil { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.leading).padding(.vertical, 4).padding(.trailing, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!isCameraConnected || recipe == nil)
                    .foregroundStyle(isCameraConnected && recipe != nil ? .primary : .tertiary)
                    .accessibilityIdentifier("recipe.slot.\(slot)")
                    .accessibilityAddTraits(current?.id == recipe?.id && recipe != nil ? .isSelected : [])
                    if let recipe {
                        Button { copyToPhone(recipe) } label: {
                            Group {
                                if copyingID == recipe.id { ProgressView() }
                                else { Image(systemName: phoneSnapshots.contains { $0.copiedFromRecipeID == recipe.id } ? "checkmark.circle" : "doc.on.doc") }
                            }.frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.trailing, 8)
                        .disabled(copyingID != nil)
                        .accessibilityLabel("Copy C\(slot) \(recipe.name) to phone")
                        .accessibilityHint(phoneSnapshots.contains { $0.copiedFromRecipeID == recipe.id } ? "Already saved. Shows the Phone tab." : "Saves an independent recipe on your phone.")
                        .accessibilityIdentifier("recipe.copy.\(slot)")
                    }
                }
            }
            Divider()
            row(title: snapshots.isEmpty ? "Import recipes" : "Refresh recipes", selected: false, identifier: "recipe.refresh") {
                presented = false; onRefresh()
            }
            .disabled(!isCameraConnected)
            .foregroundStyle(isCameraConnected ? .primary : .tertiary)
        }
    }

    private var phoneOptions: some View {
        Group {
            if phoneSnapshots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No phone recipes yet").font(.headline).accessibilityIdentifier("recipe.phone.empty")
                    Text("Use the copy icon beside a camera recipe to save it on your phone.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding()
            }
            ForEach(phoneSnapshots) { recipe in
                Button { presented = false; onSelectPhone(recipe.id) } label: {
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.name)
                            if case .unsupported = recipe.renderingSupport {
                                Text("Conversion unsupported").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if current?.id == recipe.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recipe.phone.\(recipe.id.uuidString)")
                .accessibilityAddTraits(current?.id == recipe.id ? .isSelected : [])
            }
            if !phoneSnapshots.isEmpty && !isCameraConnected {
                Text("Connect a camera to preview and export.").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func copyToPhone(_ recipe: RecipeSnapshot) {
        guard copyingID == nil else { return }
        copyingID = recipe.id; copyFailed = false
        Task { @MainActor in
            let saved = await onCopyToPhone(recipe.id)
            copyingID = nil
            if saved { collection = .phone }
            else { copyFailed = true }
        }
    }
    private func choose(_ slot: Int?) { presented = false; onSelect(slot) }
    private func row(title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(minLength: 8); if selected { Image(systemName: "checkmark").accessibilityHidden(true) } }
                .frame(maxWidth: .infinity, alignment: .leading).padding().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Scoped to the presented popover. SwiftUI's scroll view does not necessarily acquire keyboard
/// focus on iOS. A native responder handles only Escape and leaves all other keys to the system.
struct PopoverEscapeHandler: UIViewRepresentable {
    var onDismiss: () -> Void
    func makeUIView(context: Context) -> PopoverEscapeView { PopoverEscapeView(onDismiss: onDismiss) }
    func updateUIView(_ view: PopoverEscapeView, context: Context) { view.onDismiss = onDismiss }
    static func dismantleUIView(_ view: PopoverEscapeView, coordinator: ()) {
        view.resignFirstResponder(); view.onDismiss = {}
    }
}
final class PopoverEscapeView: UIView {
    var onDismiss: () -> Void
    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss; super.init(frame: .zero)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                if let self, self.window != nil { self.becomeFirstResponder() }
            }
        } else { resignFirstResponder() }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard window != nil else { return [] }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissMenu(_:)))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }
    @objc private func dismissMenu(_ sender: UIKeyCommand) {
        guard window != nil, isFirstResponder else { return }
        resignFirstResponder(); onDismiss()
    }
}
