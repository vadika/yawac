# v0.10.6 — Settings wiring + per-chat mute customization

**Date:** 2026-06-12
**Status:** Approved (design)
**Target release:** v0.10.6

## Goal

Two independent features bundled into a single release:

1. Wire up the six `@AppStorage` toggle stubs that have lived cosmetic-only in `GeneralPanel` since v0.9.13.
2. Replace the rigid 3-preset mute control with custom-duration support + a per-chat sound toggle.

Push-name edit was considered and deferred — whatsmeow has no direct setter for the paired account's own push-name. Path forward is a custom appstate patch; risk + research budget too high for this bundle.

## Non-goals

- Menu-bar Quick-Send (the popover with chat picker + Send button). The `yawac.menuBar.show` toggle in this release creates an `NSStatusItem` that, on click, only brings the main window to front. Quick-Send lands in a later release on top of this foundation.
- Per-chat notification-style customization beyond bell on/off (custom sounds per chat, banner-vs-alert style, VIP, quiet hours all stay future work).
- Push-name edit (see above).

## Scope by toggle

| Setting key | Behavior when wired |
|---|---|
| `yawac.notifications.enabled` | When false, `NotificationService.notify(...)` early-returns; no banner posted. |
| `yawac.notifications.preview` | When false, the `UNMutableNotificationContent.body` is set to `""`. Title (chat name / sender) stays so the user still sees who messaged. |
| `yawac.notifications.sound` | Mapped to `UNNotificationSound`: "Default" → `.default`, "Pop" → `UNNotificationSound(named: UNNotificationSoundName("Pop.aiff"))` (macOS system sound), "Glass" → same with `"Glass.aiff"`, "None" → `nil`. macOS resolves the named sound from `/System/Library/Sounds/`; if the file is missing on the user's system the sound is silently dropped (matches Apple's documented fallback). |
| `yawac.dock.keep` | At launch and on toggle change: `NSApp.setActivationPolicy(.regular)` when true, `.accessory` when false. When the user toggles back on with no window visible, `WindowToggler.bringToFront()` opens the main window. |
| `yawac.menuBar.show` | New `MenuBarController` (in `yawac/UI/`) owns an `NSStatusItem`. Created when true; torn down (and the status item released) when false. Click action: `WindowToggler.bringToFront()`. |
| `yawac.launchAtLogin` | `SMAppService.mainApp.register()` / `.unregister()` on toggle change, with the result logged. Failures (sandboxed permission denied, etc.) surface via `NSLog` but don't block the toggle from flipping back — the AppStorage value reflects the user's intent regardless of system success. |

## Per-chat mute customization

### UI

`ChatInfoView`'s notifications section gets:

- Mute picker expanded with a fourth option **"Until…"** that opens a `.popover` containing a `DatePicker` (compact style, ".dateAndTime") for arbitrary expiry. Existing 8 hours / 1 week / Always presets stay.
- New row **"Sound"** with a `Toggle` that mirrors the chat's `bellEnabled` field.

### Persistence

`PersistedChat` gains:

```swift
var bellEnabled: Bool = true
```

No `@Attribute(.indexed)`. No `#Index<T>`. No `VersionedSchema`. Default value via Swift property initializer is the SwiftData-supported lightweight-migration path (confirmed safe on the v0.9.60 baseline; only `#Index` triggered the destructive migration in v0.9.59). Existing rows lightweight-migrate to `bellEnabled = true`.

`Chat` value struct mirrors the field for the in-memory list. Bridge round-trip not needed — bell is a yawac-local notification suppression knob; phone doesn't get told.

### Notification gating

Notification path becomes (pseudocode):

```swift
func notify(...) {
    guard UserDefaults.standard.bool(forKey: "yawac.notifications.enabled") else { return }
    let chat = chatList?.chats.first { $0.jid == chatJID }
    if chat?.bellEnabled == false {
        content.sound = nil
    } else {
        content.sound = soundFromUserDefault()
    }
    if !UserDefaults.standard.bool(forKey: "yawac.notifications.preview") {
        content.body = ""
    }
    ...
}
```

Per-chat bell off → silent banner. Mute (existing path) → no banner at all. The two are independent.

## Architecture changes

- New file `yawac/UI/MenuBarController.swift` owning the `NSStatusItem` lifecycle. Reads `@AppStorage("yawac.menuBar.show")`; lifecycle bound to a hosting view in `yawacApp` or a singleton.
- New file `yawac/Services/LaunchAtLoginService.swift` wrapping the `SMAppService` register/unregister + a `.status` getter so the toggle reflects actual system state on read.
- `NotificationService.notify(...)` extended per Notification gating above.
- `ChatInfoView` extended with the Until… picker + Sound row.
- `PersistedChat` + `Chat` extended with `bellEnabled`.

## Migration safety

The only schema change is a single `Bool` property with a default value on an existing `@Model`. Per v0.9.60 baseline behavior, this lightweight-migrates without data loss. No `VersionedSchema` / `SchemaMigrationPlan` / `#Index` work involved — the v0.9.59→v0.9.61 disaster trail was entirely about `#Index`, not plain property adds.

## Testing

- **Unit**: notification gating matrix — for each combination of `enabled` × `preview` × `sound` × `bellEnabled`, the resulting `UNMutableNotificationContent` fields match expectation.
- **Smoke**:
  - Toggle each Settings switch, observe macOS behavior: dock icon comes/goes, menu-bar icon appears/disappears, login item appears in System Settings → General → Login Items.
  - Send a message to a muted chat with bell off; verify silent banner.
  - Set Mute → Until… 1 min ahead, wait, verify chat unmutes itself.
- **Regression**: existing mute presets still work; existing notification path still surfaces banners for non-muted chats.

## Risks

| Risk | Mitigation |
|---|---|
| SwiftData migration adds the `bellEnabled` column destructively. | Plain default-value Bool — Apple's documented safe path. Backed by v0.9.60 baseline; no `#Index` involved. Smoke-test on the real store before tagging. |
| `SMAppService.register` fails silently on unsigned dev builds. | `NSLog` the result; AppStorage value reflects user intent. Future hardening: surface a non-blocking notice if `.status` reports `.notFound`. |
| `NSStatusItem` retain cycle / lifecycle issues. | `MenuBarController` is a singleton; explicit teardown when toggle flips off. |
| Custom "Until…" date in the past gets saved. | Picker constrained to `Date.now…` via `in:` parameter. |
| Per-chat bell field grows the `Chat` struct + breaks all existing initializers in tests. | `bellEnabled` defaults to `true`; existing call sites untouched. |

## Out-of-scope follow-ups documented for later

- Menu-bar Quick-Send popover (the actual chat-picker + Send UI on top of this release's `NSStatusItem`).
- Per-chat sound name (sound is currently app-wide; only on/off is per-chat).
- Per-chat notification-style overrides (banner vs. alert, show preview override).
- Push-name edit via SendAppState appstate patch.

## Implementation order

1. PersistedChat + Chat extended with `bellEnabled` default true.
2. ChatInfoView Sound toggle row.
3. ChatInfoView Mute → Until… picker.
4. NotificationService gating (notifications.enabled, .preview, .sound, bellEnabled).
5. Dock visibility wiring (NSApp activationPolicy).
6. LaunchAtLoginService + GeneralPanel toggle wiring.
7. MenuBarController + GeneralPanel toggle wiring.
8. Smoke matrix.
9. Release bump → v0.10.6, ROADMAP entry, commit, tag, push.
