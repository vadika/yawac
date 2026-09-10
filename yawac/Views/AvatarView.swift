import SwiftUI

struct AvatarView: View {
    let jid: String
    let name: String
    let size: CGFloat
    @Environment(SessionViewModel.self) private var session
    @State private var loadedKey: String?
    @State private var loadedImage: NSImage?
    @State private var invalidation = 0

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
        let key = cacheKey
        let client = session.client
        let image = ThumbnailCache.shared.avatarImage(forCacheKey: key)
            ?? (loadedKey == key ? loadedImage : nil)
        Group {
            if let img = image {
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
        .task(id: "\(key)|\(invalidation)|\(client != nil)") {
            guard let client else { return }
            let image = await ThumbnailCache.shared.loadAvatar(key: key) {
                await AvatarCache.shared.ensure(jid: key, using: client)
            }
            guard !Task.isCancelled else { return }
            loadedKey = key
            loadedImage = image
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .avatarCacheInvalidated)) { note in
            guard let invalid = note.userInfo?["jid"] as? String,
                  JIDNormalize.same(invalid, jid, client: session.client)
            else { return }
            loadedImage = nil
            loadedKey = nil
            invalidation += 1
        }
    }

    private func initialFor(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        return String(first).uppercased()
    }
}
