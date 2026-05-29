import SwiftUI

/// Replaces the composer's input row while a voice note is recording.
/// Reads `recorder.elapsed` / `recorder.levels` directly so the parent
/// composer body doesn't churn 20×/sec — Button gestures inside the
/// composer get corrupted when their host re-renders during their
/// dispatch on macOS 26.
struct RecordingBar: View {
    let recorder: VoiceRecorder
    let cancelHint: Bool

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot()
            Text(format(recorder.elapsed))
                .scaledMono(12)
                .foregroundStyle(Theme.text)
                .frame(width: 44, alignment: .leading)

            WaveformStrip(levels: recorder.levels)
                .frame(maxWidth: .infinity, maxHeight: 22)

            Text(cancelHint ? "Release to cancel" : "Slide up to cancel")
                .scaledUI(11)
                .foregroundStyle(cancelHint ? Color.red.opacity(0.85) : Theme.textMuted)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.pillRadius)
                .stroke(cancelHint ? Color.red.opacity(0.6) : Theme.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: cancelHint)
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(on ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

private struct WaveformStrip: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.suffix(60).enumerated()), id: \.offset) { _, lvl in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2,
                               height: max(2, CGFloat(lvl) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
