import SwiftUI

struct PairingStep<Content: View>: View {
    let number: Int
    let content: Content

    init(_ number: Int, @ViewBuilder content: () -> Content) {
        self.number = number
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            content
        }
    }
}

struct PairingInstructions: View {
    let steps: [String]
    let startingAt: Int
    let identifier: String

    init(_ steps: [String], startingAt: Int = 1, identifier: String) {
        self.steps = steps
        self.startingAt = startingAt
        self.identifier = identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                PairingStep(startingAt + index) { Text(steps[index]) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(identifier).\(startingAt + index)")
            }
        }
        .font(.subheadline)
    }
}
