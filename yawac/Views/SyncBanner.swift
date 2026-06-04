import SwiftUI

/// Floating capsule shown over the conversation pane while the app
/// is syncing history, reconnecting, or offline. Non-blocking — sits
/// in an .overlay with hit-testing off so message taps pass through.
enum SyncState: Equatable {
    case idle, syncing, connecting, offline
}

struct SyncBanner: View {
    let state: SyncState
    @State private var spin = false

    private var label: String {
        switch state {
        case .syncing:    return "Syncing history"
        case .connecting: return "Connecting"
        case .offline:    return "Offline"
        case .idle:       return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if state == .offline {
                Circle()
                    .fill(Color(red: 0.91, green: 0.44, blue: 0.40))
                    .frame(width: 7, height: 7)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Theme.accent,
                                style: .init(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 13, height: 13)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                }
                .onAppear {
                    withAnimation(.linear(duration: 0.9)
                                    .repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }
            }
            Text(label)
                .scaledMono(11, weight: .medium)
                .foregroundStyle(Theme.textMuted)
            if state != .offline {
                AnimatedDots()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(
            Capsule().fill(Theme.surfaceAlt)
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct AnimatedDots: View {
    @State private var phase = 0
    // 0.45s is the slowest interval that still reads as "animating" —
    // saves ~2/3 of the wake cycles vs the prior 0.18s pace.
    private let timer = Timer.publish(every: 0.45, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.textMuted)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
