import FujiCameraCore
import SwiftUI
import UIKit

/// A floating trigger and native popover; dismissal never dispatches a selection.
struct RecipeMenu: View {
    let current: RecipeSnapshot?
    let snapshots: [RecipeSnapshot]
    let slots:[RecipeSlot]
    let canImport:Bool
    let executionReason:(RecipeSnapshot)->String?
    let phoneSnapshots: [PhoneRecipe]
    let refreshState: RecipeRefreshState
    let isCameraConnected: Bool
    var onSelect: (Int?) -> Void
    var onSelectPhone: (UUID) -> Void
    var onCopyToPhone: (UUID) async -> Bool
    var onDeletePhone: (UUID) async -> Bool
    var onEditPhone: (PhoneRecipeDraft) async throws -> Void
    var onRefresh: () -> Void
    @State private var presented: Bool
    private enum Collection { case camera, phone }
    @State private var collection: Collection
    @State private var copyingID: UUID?
    @State private var copyFailed = false
    @State private var pendingDeletion: PhoneRecipe?
    @State private var deletionPresented = false
    @State private var deletingID: UUID?
    @State private var deletionFailed = false
    @State private var editingRecipe: PhoneRecipe?
    private var isMutating: Bool { copyingID != nil || deletingID != nil }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceOrientation) private var orientation

    init(current: RecipeSnapshot?, snapshots: [RecipeSnapshot], phoneSnapshots: [PhoneRecipe],
         slots:[RecipeSlot],canImport:Bool,executionReason:@escaping (RecipeSnapshot)->String?,
         refreshState: RecipeRefreshState, isCameraConnected: Bool,
         onSelect: @escaping (Int?) -> Void, onSelectPhone: @escaping (UUID) -> Void,
         onCopyToPhone: @escaping (UUID) async -> Bool, onDeletePhone: @escaping (UUID) async -> Bool,
         onEditPhone: @escaping (PhoneRecipeDraft) async throws -> Void,
         onRefresh: @escaping () -> Void, initiallyPresented: Bool = false) {
        self.current = current; self.snapshots = snapshots; self.refreshState = refreshState
        self.slots=slots;self.canImport=canImport;self.executionReason=executionReason
        self.phoneSnapshots = phoneSnapshots; self.onSelectPhone = onSelectPhone; self.onCopyToPhone = onCopyToPhone
        self.onDeletePhone = onDeletePhone
        self.onEditPhone = onEditPhone
        self.isCameraConnected = isCameraConnected
        self.onSelect = onSelect; self.onRefresh = onRefresh
        _presented = State(initialValue: initiallyPresented)
        _collection = State(initialValue: current?.isPhoneRecipe == true ? .phone : .camera)
    }
    var body: some View {
        Button {
            collection = current?.isPhoneRecipe == true ? .phone : .camera
            copyFailed = false; deletionFailed = false; presented = true
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
        .popover(isPresented: $presented, arrowEdge: orientation.popoverEdge) {
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
        .sheet(item: $editingRecipe) { recipe in
            PhoneRecipeEditor(recipe: recipe, onSave: onEditPhone)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .alert("Delete phone recipe?", isPresented: $deletionPresented, presenting: pendingDeletion) { recipe in
            Button("Delete", role: .destructive) { deleteFromPhone(recipe) }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("“\(recipe.snapshot.name)” will be removed from Phone recipes. Saved photos are kept.")
        }
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
            ForEach(slots) { declared in
                let slot=declared.id
                let recipe = snapshots.first { $0.slot == slot }
                let reason=recipe.flatMap(executionReason)
                HStack(spacing: 0) {
                    Button { choose(slot) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            RecipeSlotBadge(slot: slot)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recipe?.name ?? "Not imported")
                                    .accessibilityLabel("C\(slot) \(recipe?.name ?? "Not imported")")
                                if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            if current?.id == recipe?.id, recipe != nil { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.leading).padding(.vertical, 4).padding(.trailing, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(reason != nil || recipe == nil)
                    .foregroundStyle(isCameraConnected && recipe != nil ? .primary : .tertiary)
                    .accessibilityIdentifier("recipe.slot.\(slot)")
                    .accessibilityAddTraits(current?.id == recipe?.id && recipe != nil ? .isSelected : [])
                    if let recipe {
                        Button { copyToPhone(recipe) } label: {
                            Group {
                                if copyingID == recipe.id { ProgressView() }
                                else { Image(systemName: phoneSnapshots.contains { $0.id == recipe.id } ? "checkmark.circle" : "doc.on.doc") }
                            }.frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.trailing, 8)
                        .disabled(isMutating)
                        .accessibilityLabel("Copy C\(slot) \(recipe.name) to phone")
                        .accessibilityHint(phoneSnapshots.contains { $0.id == recipe.id } ? "Already saved. Shows the Phone tab." : "Saves an independent recipe on your phone.")
                        .accessibilityIdentifier("recipe.copy.\(slot)")
                    }
                }
            }
            Divider()
            row(title: snapshots.isEmpty ? "Import recipes" : "Refresh recipes", selected: false, identifier: "recipe.refresh") {
                presented = false; onRefresh()
            }
            .disabled(!canImport)
            .foregroundStyle(canImport ? .primary : .tertiary)
        }
    }

    private var phoneOptions: some View {
        Group {
            if deletionFailed {
                Text("Couldn’t delete this recipe. Tap the trash icon to try again.")
                    .font(.callout).foregroundStyle(.red).padding()
                    .accessibilityIdentifier("recipe.delete.error")
            }
            if phoneSnapshots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No phone recipes yet").font(.headline).accessibilityIdentifier("recipe.phone.empty")
                    Text("Use the copy icon beside a camera recipe to save it on your phone.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding()
            }
            ForEach(phoneSnapshots) { phoneRow($0) }
            if !phoneSnapshots.isEmpty && !isCameraConnected {
                Text("Connect a camera to use phone recipes.").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func phoneRow(_ recipe: PhoneRecipe) -> some View {
        let reason=executionReason(recipe.snapshot)
        return HStack(spacing: 0) {
            Button { presented = false; onSelectPhone(recipe.id) } label: {
                HStack {
                    Image(systemName: "iphone")
                        .foregroundStyle(isCameraConnected ? .secondary : .tertiary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recipe.snapshot.name)
                        Text(recipe.snapshot.cameraContext.model).font(.caption).foregroundStyle(.secondary)
                        if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    if current?.id == recipe.snapshot.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading).padding(.trailing, 8).padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(reason != nil)
            .foregroundStyle(isCameraConnected ? .primary : .tertiary)
            .accessibilityIdentifier("recipe.phone.\(recipe.id.uuidString)")
            .accessibilityAddTraits(current?.id == recipe.snapshot.id ? .isSelected : [])

            Button { editingRecipe = recipe } label: {
                Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(isMutating)
            .accessibilityLabel("Edit \(recipe.snapshot.name)")
            .accessibilityHint("Change the name and settings, including while offline.")
            .accessibilityIdentifier("recipe.edit.\(recipe.id.uuidString)")

            Button { pendingDeletion = recipe; deletionPresented = true } label: {
                Group {
                    if deletingID == recipe.id { ProgressView() }
                    else { Image(systemName: "trash") }
                }.frame(width: 44, height: 44).padding(.trailing, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.red).disabled(isMutating)
            .accessibilityLabel("Delete \(recipe.snapshot.name) from phone")
            .accessibilityHint("Removes this saved recipe after confirmation. Saved photos are kept.")
            .accessibilityIdentifier("recipe.delete.\(recipe.id.uuidString)")
        }
    }

    private func deleteFromPhone(_ recipe: PhoneRecipe) {
        guard !isMutating else { return }
        deletingID = recipe.id; deletionFailed = false
        Task { @MainActor in
            let deleted = await onDeletePhone(recipe.id)
            deletingID = nil; pendingDeletion = nil
            deletionFailed = !deleted
        }
    }

    private func copyToPhone(_ recipe: RecipeSnapshot) {
        guard !isMutating else { return }
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
