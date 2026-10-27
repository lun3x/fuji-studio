import SwiftUI
import UIKit

/// A floating trigger and native popover; dismissal never dispatches a selection.
struct RecipeMenu: View {
    let current: RecipeSnapshot?
    let snapshots: [RecipeSnapshot]
    let refreshState: RecipeRefreshState
    var onSelect: (Int?) -> Void
    var onRefresh: () -> Void
    var onControlFrameChanged: (CGRect) -> Void = { _ in }
    @State private var presented: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    init(current: RecipeSnapshot?, snapshots: [RecipeSnapshot], refreshState: RecipeRefreshState,
         onSelect: @escaping (Int?) -> Void, onRefresh: @escaping () -> Void,
         onControlFrameChanged: @escaping (CGRect) -> Void = { _ in }, initiallyPresented: Bool = false) {
        self.current = current; self.snapshots = snapshots; self.refreshState = refreshState
        self.onSelect = onSelect; self.onRefresh = onRefresh; self.onControlFrameChanged = onControlFrameChanged
        _presented = State(initialValue: initiallyPresented)
    }
    var body: some View {
        Button { presented = true } label: {
            Group {
                if let current { Text("C\(current.slot)").font(.headline.monospacedDigit()) }
                else { Image(systemName: "camera.filters").font(.headline) }
            }.frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .foregroundStyle(.primary)
        .background {
            if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .overlay { if contrast == .increased { Capsule().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel(current.map { "C\($0.slot) \($0.name)" } ?? "No recipe selected")
        .accessibilityHint("Choose a cached camera recipe or import recipes")
        .accessibilityIdentifier("recipe.control")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("workspace")) }, action: onControlFrameChanged)
        .popover(isPresented: $presented, arrowEdge: .top) {
            options.environment(\.dynamicTypeSize, dynamicTypeSize)
                .background { RecipeEscapeHandler(onDismiss: { presented = false }).frame(width: 1, height: 1) }
                .presentationCompactAdaptation(.popover)
        }
    }
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Camera recipes").font(.headline).padding()
                if case .stale(let message) = refreshState {
                    Label("Cached recipes · \(message)", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.callout).padding(.horizontal).padding(.bottom, 8)
                        .accessibilityIdentifier("recipe.stale")
                }
                row(title: "No recipe", selected: current == nil, identifier: "recipe.none") { choose(nil) }
                ForEach(1...7, id: \.self) { slot in
                    let recipe = snapshots.first { $0.slot == slot }
                    Button { choose(slot) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("C\(slot) \(recipe?.name ?? "Not imported")")
                                if let recipe, case .unsupported = recipe.renderingSupport {
                                    Text("Cached · conversion unsupported").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if current?.slot == slot { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .buttonStyle(.plain).disabled(recipe == nil)
                    .accessibilityIdentifier("recipe.slot.\(slot)")
                    .accessibilityAddTraits(current?.slot == slot ? .isSelected : [])
                }
                Divider()
                row(title: snapshots.isEmpty ? "Import recipes" : "Refresh recipes", selected: false, identifier: "recipe.refresh") {
                    presented = false; onRefresh()
                }
            }
        }
        .accessibilityIdentifier("recipe.options")
        .frame(idealWidth: 320, maxHeight: 520)
    }
    private func choose(_ slot: Int?) { presented = false; onSelect(slot) }
    private func row(title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(minLength: 8); if selected { Image(systemName: "checkmark").accessibilityHidden(true) } }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.buttonStyle(.plain).accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Scoped to the presented popover. SwiftUI's scroll view does not necessarily acquire keyboard
/// focus on iOS. A native responder handles only Escape and leaves all other keys to the system.
private struct RecipeEscapeHandler: UIViewRepresentable {
    var onDismiss: () -> Void
    func makeUIView(context: Context) -> RecipeEscapeView { RecipeEscapeView(onDismiss: onDismiss) }
    func updateUIView(_ view: RecipeEscapeView, context: Context) { view.onDismiss = onDismiss }
    static func dismantleUIView(_ view: RecipeEscapeView, coordinator: ()) {
        view.resignFirstResponder(); view.onDismiss = {}
    }
}
private final class RecipeEscapeView: UIView {
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
