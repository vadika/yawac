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
        .task(id: "\(jid)#\(revision)") {
            // Fast path: skip the actor hop + bridge call when the
            // avatar is already cached on disk.
            if let cached = AvatarCache.cachedURL(for: jid),
               FileManager.default.fileExists(atPath: cached.path) {
                imageURL = cached
                return
            }
            guard let client = session.client else {
                imageURL = nil
                return
            }
            imageURL = await AvatarCache.shared.ensure(jid: jid, using: client)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .avatarCacheInvalidated)) { note in
            guard let invalid = note.userInfo?["jid"] as? String,
                  invalid == jid else { return }
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
