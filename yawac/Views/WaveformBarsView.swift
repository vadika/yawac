import SwiftUI

/// WhatsApp-style amplitude view for a voice note. Paints the raw bytes
/// the proto ships (`AudioMessage.Waveform` — 64 values 0-100) as 64
/// vertical capsules sized to each amplitude. The capsules left of the
/// playhead are tinted `tintPlayed`; the rest stay `tintUnplayed`.
///
/// `bytes` is expected to be 64 bytes but the view is defensive — it
/// reads whatever length it gets and divides the available width
/// evenly. Empty `bytes` collapses to a zero-bar HStack so the caller
/// can fall back to a plain ProgressView at the same slot.
struct WaveformBarsView: View {
    /// Raw amplitude bytes (0-100 each). 64 values for WhatsApp voice
    /// notes, but anything non-empty renders.
    let bytes: Data
    /// Playback progress in `[0, 1]`. Bars whose normalized index is
    /// `<= progress` paint with `tintPlayed`.
    let progress: Double
    /// Color for the portion left of the playhead.
    let tintPlayed: Color
    /// Color for the portion right of the playhead.
    let tintUnplayed: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(bytes.enumerated()), id: \.offset) { idx, byte in
                    let h = max(2, CGFloat(byte) / 100.0 * geo.size.height)
                    let denom = Double(max(1, bytes.count - 1))
                    let frac = Double(idx) / denom
                    let played = frac <= progress
                    Capsule()
                        .fill(played ? tintPlayed : tintUnplayed)
                        .frame(width: 2, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 24)
    }
}
