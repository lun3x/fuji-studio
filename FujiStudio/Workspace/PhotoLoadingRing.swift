import SwiftUI

struct PhotoLoadingRing: View {
    let loading: ImageLoadingState

    private var progress: Double? {
        if case .downloading(let value) = loading { return value }
        return nil
    }

    var body: some View {
        ProgressView(value: progress)
            .progressViewStyle(PhotoLoadingRingStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress == nil ? "Loading preview" : "Downloading original")
            .accessibilityValue(progress.map { Text($0, format: .percent.precision(.fractionLength(0))) }
                ?? Text("Processing photo"))
    }
}

private struct PhotoLoadingRingStyle: ProgressViewStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let progress = configuration.fractionCompleted
        let rotates = progress == nil && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !rotates)) { context in
            let rotation = rotates
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360
                : 0
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.16), lineWidth: 3)
                Circle().trim(from: 0, to: progress ?? 0.24)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(1.5)
                    .rotationEffect(.degrees(rotation - 90))
            }
        }
        .frame(width: 48, height: 48)
    }
}
