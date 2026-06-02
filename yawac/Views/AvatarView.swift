import SwiftUI

struct AvatarView: View {
    let jid: String
    let name: String
    let size: CGFloat
    @Environment(SessionViewModel.self) private var session
    @State private var imageURL: URL?
    /// Bumped by AvatarCache.invalidate broadcasts so `.task(id:)`
    /// re-runs and the view picks up the newly-fetched file.
    @State private var revision: Int = 0

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
        Group {
            if let url = imageURL, let img = NSImage(contentsOf: url) {
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
        .task(id: "\(cacheKey)#\(revision)") {
            let key = cacheKey
            // Fast path: skip the actor hop + bridge call when the
            // avatar is already cached on disk.
            if let cached = AvatarCache.cachedURL(for: key),
               FileManager.default.fileExists(atPath: cached.path) {
                imageURL = cached
                return
            }
            guard let client = session.client else {
                imageURL = nil
                return
            }
            imageURL = await AvatarCache.shared.ensure(jid: key, using: client)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .avatarCacheInvalidated)) { note in
            guard let invalid = note.userInfo?["jid"] as? String,
                  JIDNormalize.same(invalid, jid, client: session.client)
            else { return }
            // Clear the URL so the placeholder shows during the brief
            // re-fetch window; bumping `revision` re-runs `.task`.
            imageURL = nil
            revision &+= 1
        }
    }

    private func initialFor(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        return String(first).uppercased()
    }
}
