# v0.9.0 — Own Profile Edit (About + Avatar)

**Date:** 2026-06-05
**Status:** Approved (design)
**Topic:** Settings sheet adds an "About me" section letting the
paired account edit its About (status message) and avatar. Push
name is deferred (no simple whatsmeow setter; requires app-state
patch).

## Goal

Surface profile edit affordances in `SettingsView`. Today the
user can pair + view their own JID but has no way to change About
or avatar from yawac — the phone is the only path.

## Non-goals

- **Push name (display name)** — whatsmeow has no top-level
  setter; updating requires building a SETTING_PUSHNAME app-state
  patch. Document as future work; phone remains the canonical
  path for now.
- Privacy controls (last seen / about visibility / read
  receipts) — separate gap, separate cycle.
- Multi-account profile management.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ SettingsView:                                                │
│   "ABOUT ME" section (top, above existing sections)          │
│     ─ Avatar with edit pencil overlay (tap → pick / remove)  │
│     ─ Push name (read-only, "edit via phone" hint)           │
│     ─ About multiline editor + Save                          │
└─────────────────────────────────────────────────────────────┘
              │ WAClient wrappers
              ▼
┌─────────────────────────────────────────────────────────────┐
│ bridge: SetSelfAvatar(jpegBytes) → SetGroupPhoto(ownJID, b)  │
│         RemoveSelfAvatar() → SetGroupPhoto(ownJID, nil)      │
│         SetStatusMessage(ctx, msg) — already exists upstream │
└─────────────────────────────────────────────────────────────┘
              │ whatsmeow
              ▼
   SetGroupPhoto(jid=ownJID), SetStatusMessage
```

## Components

### Bridge — Go

`bridge/profile.go` (new file):

```go
package bridge

import (
    "context"
    "errors"
    "fmt"
)

// SetSelfAvatar sets the paired account's profile picture by
// invoking SetGroupPhoto with the user's own JID. WhatsApp uses
// the same RPC for groups and self.
func (c *Client) SetSelfAvatar(jpegBytes []byte) error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    own := c.wa.Store.ID
    if own == nil {
        return errors.New("not paired")
    }
    _, err := c.wa.SetGroupPhoto(context.Background(), own.ToNonAD(), jpegBytes)
    if err != nil {
        return fmt.Errorf("set self avatar: %w", err)
    }
    return nil
}

// RemoveSelfAvatar clears the paired account's profile picture.
func (c *Client) RemoveSelfAvatar() error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    own := c.wa.Store.ID
    if own == nil {
        return errors.New("not paired")
    }
    _, err := c.wa.SetGroupPhoto(context.Background(), own.ToNonAD(), nil)
    if err != nil {
        return fmt.Errorf("remove self avatar: %w", err)
    }
    return nil
}

// SetSelfAbout updates the paired account's About / status message.
func (c *Client) SetSelfAbout(msg string) error {
    if c.wa == nil {
        return errors.New("client closed")
    }
    if err := c.wa.SetStatusMessage(context.Background(), msg); err != nil {
        return fmt.Errorf("set status message: %w", err)
    }
    return nil
}
```

### Swift bridge

`yawac/Bridge/WAClient.swift`:

```swift
nonisolated func setSelfAvatar(jpegBytes: Data) throws {
    try go.setSelfAvatar(jpegBytes)
}

nonisolated func removeSelfAvatar() throws {
    try go.removeSelfAvatar()
}

nonisolated func setSelfAbout(_ message: String) throws {
    try go.setSelfAbout(message)
}
```

### SettingsView — UI

New "ABOUT ME" sectionCard at the top of SettingsView:

```swift
// At the top of the Settings body.
sectionCard(label: "ABOUT ME") {
    HStack(alignment: .top, spacing: 12) {
        // Avatar with pencil overlay
        ZStack(alignment: .bottomTrailing) {
            AvatarView(jid: session.ownJID, size: 64)
            Button {
                avatarMenuOpen = true
            } label: {
                Image(systemName: "pencil")
                    .scaledIcon(11, weight: .medium)
                    .padding(5)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .popover(isPresented: $avatarMenuOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Choose image…") { avatarMenuOpen = false; pickAvatar() }
                    Button("Remove photo", role: .destructive) {
                        avatarMenuOpen = false; removeAvatar()
                    }
                }
                .padding(10)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(pushNameRead).scaledUI(14, weight: .semibold)
            Text("Edit display name on the phone.")
                .scaledUI(11).foregroundStyle(Theme.textMuted)
        }
        Spacer()
    }

    Divider().padding(.vertical, 4)

    VStack(alignment: .leading, spacing: 6) {
        Text("About").scaledUI(11).foregroundStyle(Theme.textMuted)
        TextField("", text: $aboutDraft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        HStack {
            if let err = aboutError {
                Text(err).foregroundStyle(.red).scaledUI(11)
            }
            Spacer()
            Button("Save About") { saveAbout() }
                .disabled(aboutDraft == aboutBaseline || aboutSaving)
        }
    }

    if let avatarError {
        Text(avatarError).foregroundStyle(.red).scaledUI(11)
    }
}
```

State + helpers:

```swift
@State private var aboutDraft: String = ""
@State private var aboutBaseline: String = ""
@State private var aboutSaving = false
@State private var aboutError: String?
@State private var avatarMenuOpen = false
@State private var avatarError: String?

private var pushNameRead: String {
    session.displayName(for: session.ownJID).trimmingCharacters(in: .whitespaces)
}

.task {
    // Hydrate About from upstream via GetUserInfo / equivalent
    // session helper. If session caches ownAbout, read from there;
    // otherwise call client.getUserInfo(jids: [ownJID]) and read .status.
    if let info = try? await session.fetchSelfInfo() {
        aboutBaseline = info.about
        aboutDraft = info.about
    }
}

private func pickAvatar() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.begin { resp in
        guard resp == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let img = NSImage(data: data) else { return }
        // Crop + resize via existing AvatarCropSheetView pattern; or
        // fall back to a direct JPEG re-encode at <=2MB.
        guard let jpeg = ImageEncoders.encodeJPEG(img, maxSize: 640) else {
            avatarError = "Couldn't encode image."
            return
        }
        Task {
            do {
                try await Task.detached {
                    try session.client?.setSelfAvatar(jpegBytes: jpeg)
                }.value
            } catch {
                avatarError = (error as NSError).localizedDescription
            }
        }
    }
}

private func removeAvatar() {
    Task {
        do {
            try await Task.detached {
                try session.client?.removeSelfAvatar()
            }.value
        } catch {
            avatarError = (error as NSError).localizedDescription
        }
    }
}

private func saveAbout() {
    let msg = aboutDraft
    aboutSaving = true
    Task {
        defer { aboutSaving = false }
        do {
            try await Task.detached {
                try session.client?.setSelfAbout(msg)
            }.value
            aboutBaseline = msg
        } catch {
            aboutError = (error as NSError).localizedDescription
        }
    }
}
```

`session.fetchSelfInfo()` is a new helper that wraps the existing
`client.getUserInfo(jids:)` path. If the project's existing
`loadUserInfo` in `ChatInfoView` is the pattern, expose a shared
fetcher on `SessionViewModel`.

`ImageEncoders.encodeJPEG` is a small helper — re-encode to JPEG
at quality 0.8, scaled to fit a max side of 640px. WhatsApp
expects roughly square avatars; for v0.9.0 we skip crop UX (the
phone offers cropping; macOS users typically pick a pre-cropped
image).

## Error handling

| Surface | Pattern |
|---|---|
| `SetSelfAvatar` fail | Inline red strip; doesn't revert any UI state (avatar refreshes async via PushName/UserInfo update). |
| `RemoveSelfAvatar` fail | Same. |
| `SetSelfAbout` fail | Inline red strip; `aboutBaseline` stays at prior value so the Save button re-enables. |
| Image encode fail | "Couldn't encode image." string. |
| Not paired | Bridge guards return "not paired" — surface verbatim. |

## Testing

### Bridge

- `SetSelfAvatar` / `RemoveSelfAvatar` / `SetSelfAbout` on
  unpaired client → "not paired" / "client closed" errors.
- Encoding nil bytes vs empty bytes — `SetSelfAvatar(nil)` is
  semantically remove; route through `RemoveSelfAvatar` instead.

### Swift

- `setSelfAbout` non-throwing happy path with stub client.
- Unpaired stub → throws.
- `aboutDraft` ≠ `aboutBaseline` enables Save.
- `saveAbout()` updates baseline on success.

### Manual smoke

- Settings → ABOUT ME → edit About text → Save → phone reflects new
  About line.
- Tap pencil → Choose image → pick file → avatar updates in yawac
  + phone reflects within ~1s.
- Tap pencil → Remove photo → avatar clears in yawac + phone.
- Push name field shows current name + hint text; not editable.
- About edit while unpaired (rare; pair-loss mid-session) → red
  "not paired" strip.

## Files touched

**New:**

- `bridge/profile.go`
- `bridge/profile_test.go`
- `yawac/Utilities/ImageEncoders.swift` (if not present)
- `yawacTests/OwnProfileEditTests.swift`

**Modified:**

- `yawac/Bridge/WAClient.swift` — three new wrappers.
- `yawac/ViewModels/SessionViewModel.swift` —
  `fetchSelfInfo()` helper (wraps existing getUserInfo path).
- `yawac/Views/SettingsView.swift` — ABOUT ME sectionCard +
  state + helpers.
- `project.yml` — bump `CFBundleShortVersionString` 0.8.4 → 0.9.0,
  `CFBundleVersion` 13 → 14.
- `docs/ROADMAP.md` — strike "Own profile edit" gap. Push-name
  sub-bullet stays open as a v0.9.x candidate.
