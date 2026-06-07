import SwiftUI

struct AvatarView: View {
    let jid: String
    let name: String
    let size: CGFloat
    @Environment(SessionViewModel.self) private var session

    /// JIDs from group participants come back in `@lid` form while the
    /// same person's 1:1 chat may be opened under the canonical PN form
    /// (`requestSelectChat` calls `JIDNormalize.canonical`). Without
    /// matching cache keys, the hero re-fetches from server while the
    /// participant row sits on the existing file. Canonicalize once here
    /// so all AvatarView call sites share one cache entry per person.
    private var cacheKey: String {
        JIDNormalize.canonical(jid, client: session.client)
    }

    var body: some View {
        // Read `ThumbnailCache.revision` so the body re-runs when the
        // shared 50ms-coalesced bump fires — that's how cold avatars
        // appear without a per-instance `@State` flip + `.task(id:)`
        // (which flashed the placeholder on every disk hit).
        let cache = ThumbnailCache.shared
        let _ = cache.revision
        let key = cacheKey
        // Capture the MainActor-isolated client ONCE so the detached
        // fetcher closure doesn't reach back into session state from a
        // background thread.
        let client = session.client
        Group {
            if let img = cache.avatarImage(forCacheKey: key, fetcher: {
                guard let client else { return nil }
                return await AvatarCache.shared.ensure(jid: key, using: client)
            }) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.gray.opacity(0.3))
                    Text(initialFor(name))
                        .scaledUI(size * 0.4, weight: .bold)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .onReceive(NotificationCenter.default.publisher(
            for: .avatarCacheInvalidated)) { note in
            guard let invalid = note.userInfo?["jid"] as? String,
                  JIDNormalize.same(invalid, jid, client: session.client)
            else { return }
            AvatarLog.write("[avatar-view size=\(Int(size))] invalidated by \(invalid) → reset jid=\(jid)")
            // Drop the in-memory NSImage so the next body eval misses
            // and the load path re-runs; revision bump wakes observers.
            ThumbnailCache.shared.invalidateAvatar(forCacheKey: key)
        }
    }

    private func initialFor(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        return String(first).uppercased()
    }
}
