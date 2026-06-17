# Menu-bar Quick-send — Design

## Background

Roadmap `Important → Productivity / macOS → Menu-bar quick-send`:

> NSStatusItem popover with chat picker + message field; cmd-shift-Y opens
> it from anywhere. Compose without bringing the full window forward.
> Pairs well with the Shortcuts integration above.

F73 (v0.10.6) already mounts the `NSStatusItem` via
`MenuBarController.shared`. Left-click currently brings the main window
forward; right-click drops a context menu. There is no popover and no
global hotkey. This design fills both gaps.

## Goal

Send a WhatsApp text message in under three seconds from any app
without surfacing yawac's main window. Mirrors the
`Spotlight → query → enter` rhythm. One-shot use is the dominant case;
multi-send is an explicit non-goal of v1.

## Decisions

(Recorded from the brainstorm pass. Each one is load-bearing for the
sections below; revisit before changing.)

| Topic | Decision | Why |
|---|---|---|
| Picker style | Recent + search | Covers "reply to whoever messaged me" + "send to anyone". Top ~15 recent visible by default; type to filter all chats. |
| After send | Close popover | Matches macOS Spotlight-like quick-action conventions. Reopen for next send. |
| Attachments | Text only (incl. emoji) | Smallest scope; richer composition belongs in the main window. |
| Global hotkey impl | Carbon `RegisterEventHotKey` | No Accessibility permission prompt. Same path Raycast / Alfred-class apps use. |
| Hotkey binding | Hardcoded ⌘⇧Y for v1 | Custom-bind is a follow-up; deferred. |

## Architecture

### New files

- `yawac/UI/QuickSendPopover.swift` — SwiftUI root view; owns
  `@State selectedChatJID: String?`.
- `yawac/UI/QuickSendChatPicker.swift` — search field + filtered chat
  list.
- `yawac/UI/QuickSendComposer.swift` — text field + send button.
- `yawac/UI/GlobalHotkey.swift` — Carbon `RegisterEventHotKey` wrapper.

### Modified files

- `yawac/UI/MenuBarController.swift`
  - Owns a private `NSPopover`.
  - `handleClick(_:)` left-click branch flips from
    `WindowToggler.bringToFront` to `togglePopover()`.
  - Right-click context menu gains a "Show Main Window" entry (so the
    old left-click affordance is still reachable).
  - `install()` / `tearDown()` also install / tear down the global
    hotkey so `yawac.menuBar.show` gates the whole feature with one
    switch.
  - New public `togglePopover()` invoked by both left-click and the
    Carbon hotkey callback.
- `yawac/yawacApp.swift`
  - No structural change; the existing `.onAppear` that calls
    `MenuBarController.shared.setEnabled(show)` continues to drive
    the popover + hotkey lifecycle through `install()` / `tearDown()`.

### Component responsibilities

| Component | Owns | Reads from environment |
|---|---|---|
| `QuickSendPopover` | `selectedChatJID`, popover dismiss action | `SessionViewModel`, `WAClient` |
| `QuickSendChatPicker` | `query`, highlighted-row index | `session.chatList?.chats` |
| `QuickSendComposer` | `draft`, `sending: Bool`, `error: String?` | `WAClient` (for `sendText`) |
| `GlobalHotkey` | Carbon hotkey ref, event handler ref | `() -> Void` callback supplied by `MenuBarController` |

`GlobalHotkey` is the only component allowed to touch Carbon. Other
files import AppKit + SwiftUI only.

## Data flow

### Open paths

Either of:
1. Left-click `NSStatusItem` → `MenuBarController.handleClick` →
   `togglePopover()`.
2. ⌘⇧Y from anywhere → `GlobalHotkey` C handler → MainActor dispatch →
   `MenuBarController.togglePopover()`.

`togglePopover()` shows the popover anchored to the status item's
`button` with `NSRectEdge.minY`. Behavior `.transient` so click-outside
dismisses.

### Reset semantics

`togglePopover()` resets `selectedChatJID`, `query`, and `draft` to nil
/ "" / "" on each open. v1 quick-send carries no state between
invocations.

### Picker → composer

- Up / Down arrows move the highlight in the filtered list.
- Enter on a highlighted row sets `selectedChatJID`, swaps the popover
  body from picker to composer, focus jumps to the text field.
- Esc in picker → close popover.
- "← Back" button in composer top-left → return to picker (do not
  close).

### Send

Mirrors F51's optimistic-send pattern but without the bubble append
(quick-send does not own a conversation view).

```
sending = true
Task.detached {
    do {
        try await client.sendText(
            chatJID: selectedChatJID,
            text: draft,
            quoted: nil)
        await MainActor.run { closePopover() }
    } catch {
        await MainActor.run {
            sending = false
            error = describe(error)  // auto-clear after 4s
        }
    }
}
```

The ingest pump catches the sent message into `PersistedMessage` and
into the sidebar tip on the next event from whatsmeow; the open
conversation's CVM is not touched.

### Settings binding

`yawac.menuBar.show` (F73) controls install / uninstall of the status
item, the popover, AND the global hotkey, as a single bundle. No new
`yawac.quickSend.*` defaults key is introduced.

## Global hotkey (Carbon)

### Why Carbon over `NSEvent.addGlobalMonitorForEvents`

- No Accessibility permission prompt.
- Survives Apple's tightening Launch Services security around
  background monitors.
- Same path Raycast / Alfred / Magnet use; battle-tested.

Trade-off: hardcoded modifier+keycode at compile time, no easy
re-bind UI. Deferred (`Settings → custom hotkey` is a follow-up).

### Registration

```swift
let signature: OSType = OSType("yawc".fourCharCode)  // 'yawc'
let id = EventHotKeyID(signature: signature, id: 1)
var ref: EventHotKeyRef?
RegisterEventHotKey(
    UInt32(kVK_ANSI_Y),
    UInt32(cmdKey | shiftKey),
    id,
    GetEventDispatcherTarget(),
    0,
    &ref)
```

`InstallEventHandler` filters `kEventClassKeyboard /
kEventHotKeyPressed`. The C handler unpacks the `EventHotKeyID`,
matches signature, and dispatches the stored Swift closure on the main
actor via `DispatchQueue.main.async`.

The Swift closure is passed in as a `Unmanaged<HandlerBox>`
`userData` so the C handler can recover it without a global.

### Conflict handling

If `RegisterEventHotKey` returns `eventHotKeyExistsErr`, log via
`NSLog("[yawac/hotkey] ⌘⇧Y unavailable, …")` and skip — the menu-bar
click still works.

## Error handling

| Failure | Behavior |
|---|---|
| Bridge send fails | Composer re-enables, banner row shows error string for 4s. Popover stays open. |
| Hotkey already registered by another app | Skip silently, log once at startup. |
| Status item disabled mid-popover (Settings flip) | `tearDown()` closes the popover + unregisters hotkey. |
| No paired account | Picker shows "No account paired" placeholder; composer hidden. |
| Empty chat list | Picker shows "Search to find a chat" hint. |

## Testing

- `QuickSendChatPickerTests`
  - Recent ordering reflects `lastMessageTimestamp` DESC.
  - Search query filters case-insensitively by display name.
  - Search query matches digit-prefix JIDs for unsaved contacts.
  - Direct vs group disambiguation in row label.
  - Empty `chats` array shows the empty-state.
- `QuickSendComposerTests`
  - Enter inserts newline; Cmd-Enter sends.
  - Empty / whitespace-only draft disables Send.
  - Error banner shows on bridge throw and auto-clears at 4s.
  - Send success closes the popover (asserted via the closure spy).
- `GlobalHotkeyTests`
  - Register / unregister pair is idempotent.
  - `eventHotKeyExistsErr` is swallowed and logged.
  - Posted callback fires exactly once per simulated press
    (synthetic event injection).

### Manual repro list

For the ship checklist:

1. ⌘⇧Y from Safari → popover opens at menu bar.
2. Type a chat name → list filters; Enter selects.
3. Type a message → Cmd-Enter sends → popover closes, no main window
   surfaces.
4. Phone receives the message within seconds.
5. Disable menu bar in Settings → hotkey no longer fires; popover gone.

## Out of scope

- Custom hotkey configuration UI.
- Attachments (text only per the brainstorm decision).
- Send-and-keep-open mode (per the brainstorm decision).
- Reply-target mode (no thread context).
- Multi-recipient send (one-shot to one chat).
- Read-only chat preview inside the popover.

These are all candidates for v2 once v1 ships and use-feedback lands.

## Risks

- **Carbon API deprecation surface.** `RegisterEventHotKey` and
  friends emit deprecation warnings in modern macOS SDKs. Apple has
  shown no signal they will remove them. Suppress at the wrapper file
  level; revisit if Apple does deprecate-for-removal.
- **Hotkey conflict with another app.** Mitigated by the `eventHot
  KeyExistsErr` skip. Custom-bind UI lifts this in v2.
- **Popover sizing under accessibility large-text.** SwiftUI handles
  the layout, but if the picker rows grow past the popover frame the
  UX degrades to a vertical scroller. Acceptable; monitored.
