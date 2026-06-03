import Foundation

/// View-once envelope reveal — flip the persisted message into its
/// locked terminal state and best-effort delete the on-disk media file
/// so the bytes can't be re-rendered after the user looks at them.
///
/// WhatsApp's view-once protocol is a sender-side promise (the bridge
/// strips the cipher key after a single decrypt). We honour the same
/// contract on the local row: once revealed, the path is cleared,
/// `viewOnceLocked` is set, and `viewOnceRevealedAt` is stamped.
enum ViewOnceReveal {
    /// Lock the message in-place and delete the on-disk media file
    /// (best-effort). Idempotent — calling on an already-locked
    /// message is a no-op (still ensures `viewOnceLocked == true`).
    @MainActor
    static func reveal(_ msg: PersistedMessage) {
        guard msg.isViewOnce, !msg.viewOnceLocked else {
            msg.viewOnceLocked = true
            return
        }
        if let path = msg.mediaPath, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        msg.mediaPath = nil
        msg.mediaCaption = nil
        msg.viewOnceLocked = true
        msg.viewOnceRevealedAt = Date()
    }
}
