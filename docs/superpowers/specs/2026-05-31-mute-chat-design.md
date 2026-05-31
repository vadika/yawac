# Mute Chat Design Spec

**Date:** 2026-05-31
**Status:** Approved (design)
**Topic:** Per-chat mute via whatsmeow's `BuildMuteAbs`. Three duration
options (8h / 1 week / Always); sidebar bell-slash badge + dimmed unread
count; banner + dock badge + reaction notifications all suppressed for
muted chats; @-mentions pierce mute.

## Goal

Today every inbound message bumps the menu-bar / dock unread count and
fires a system banner. There's no way to silence a noisy chat without
also losing the message itself. Wire up the existing whatsmeow appstate
mute primitive so noisy chats can be silenced for a fixed window or
indefinitely, with cross-device sync and a clear sidebar indicator.

## Non-goals

- Per-chat notification sound choice (system default only).
- "Show message preview vs hide" mute variant — banner is on or off.
- Minute-precision snooze (no "1 hour" option v1).
- Custom date/time picker for arbitrary mute-until times.
- Muting a status update or call (calls out of scope project-wide).

## Architecture

Mirrors the existing pin/archive appstate-sync path almost verbatim —
the bridge already routes `*events.Pin` / `*events.Archive` through
`dispatchPin` / `dispatchArchive` into Swift; mute follows the same
shape. `bridge/appstate.go` already has `PinChat` / `ArchiveChat` /
`ListPinnedChats`; add `MuteChat` / `ListMutedChats` next to them.

### Model

- `yawac/Models/PersistedMessage.swift` `PersistedChat` (line 154) gains
  `var mutedUntil: Date? = nil` — defaulted so SwiftData performs a
  lightweight migration.
- `yawac/Models/Chat.swift` (line 18 area) gains `var mutedUntil: Date?
  = nil` on the UI struct.
- Semantics:
  - `nil` → not muted.
  - Future `Date` → muted until that instant.
  - The whatsmeow `MutedForever` sentinel (year-9999 UTC) → "Always".
    Peer devices receive and interpret the same sentinel.

### Bridge (Go)

- **`bridge/appstate.go`** —
  - `MuteChat(chatJID string, mute bool, mutedUntilUnixMs int64) (string, error)`:
    parse jid, build `*int64` from `mutedUntilUnixMs` (or pass `nil`
    when `mute == false`), call `c.wa.SendAppState(appstate.BuildMuteAbs(jid, mute, ts))`.
    Returns JSON `{ "muted": bool, "mutedUntilMs": int64 }` for the
    Swift wrapper.
  - `ListMutedChats() (string, error)`: iterate
    `store.ChatSettingsStore` (whatsmeow exposes a `GetChatSettings(jid)`
    that surfaces `MutedUntil`); return JSON
    `[{ "chatJID": string, "mutedUntilMs": int64 }]` for every chat with
    `MutedUntil > now`. Used for cold-start reconcile.
- **`bridge/events.go`** —
  - Add `case *events.Mute` in the event switch (~line 67–69, next to
    Pin/Archive).
  - New `dispatchMute(evt *events.Mute)` (mirrors `dispatchArchive` at
    line 181) marshals
    `JChatMuted{ChatJID, MutedUntilMs, Timestamp}` and dispatches with
    the type tag `"ChatMuted"`.
- **`bridge/jsonmodels.go`** — new `JChatMuted{ChatJID string,
  MutedUntilMs int64, Timestamp int64}`.

### Swift bridge

- **`yawac/Bridge/WAClient.swift`** —
  - `muteChat(_ chatJID: String, mute: Bool, mutedUntil: Date?) throws -> BridgeMuteResult`
    — converts `mutedUntil` → Unix ms (or 0 for unmute), calls
    `go.muteChat(...)`.
  - `listMutedChats() throws -> [(jid: String, mutedUntil: Date)]`.
  - `BridgeMuteResult{ muted: Bool, mutedUntilMs: Int64 }` (Codable
    mirror of the Go return JSON).
- **WAClient `Event` enum** gains `case chatMuted(chatJID: String,
  mutedUntil: Date?, timestamp: Int64)`. The event dispatcher
  (~line 620, `case "ChatPinned"` switch) gains a `case "ChatMuted"`
  branch.

### VM

- **`yawac/ViewModels/ChatListViewModel.swift`** —
  - `func applyLocalMute(chatJID: String, mutedUntil: Date?)` — updates
    the in-memory `chats[]` entry, persists via `upsertPersisted`,
    calls `sortChats()`. No SwiftData migration timing concerns; same
    shape as `applyLocalArchive`.
  - `func applyIncomingMute(chatJID: String, mutedUntil: Date?, at:)` —
    no-op when our row is newer than the incoming `at` (lww — same
    pattern as `applyIncomingChatPin`).
  - `func reconcileMutedWithStore()` — called from `init` immediately
    after `reconcilePinsWithStore`. Pulls
    `client?.listMutedChats()` and writes results into matching rows.
  - `func isMuted(_ chatJID: String, now: Date) -> Bool`:
    `chats.first(where: { $0.jid == chatJID })?.mutedUntil.map { $0 > now } ?? false`.
  - `func isMutedForNotification(chatJID: String, message: BridgeMessage) -> Bool`:
    1. If `!isMuted(chatJID, now: Date())` → false.
    2. Else, if the chat is a group AND `message.text` contains
       `"@\(session.ownPhoneDigits)"` token → false (mention pierces).
    3. Else → true.
  - `pushUnreadToSession()`: replace the existing sum with one that
    skips muted chats:
    ```swift
    let total = chats.reduce(0) { acc, c in
        (c.mutedUntil.map { $0 > Date() } ?? false) ? acc : acc + c.unread
    }
    ```
  - Both inbound paths (`ChatListViewModel:339` message banner +
    `:476` reaction banner) wrap `NotificationService.notify(...)`
    with `guard !isMutedForNotification(chatJID:, message:) else
    { return }`.
- **`yawac/ViewModels/SessionViewModel.swift`** — add a small
  `var ownPhoneDigits: String { ownJID.split(separator: "@").first.map(String.init) ?? "" }`
  helper if no equivalent exists. Used only by the mention-pierce
  predicate.
- **`yawac/ContentView.swift`** — extend the event-apply switch
  (~line 173, next to `.chatPinned`) with `case .chatMuted(let jid, let
  until, let ts): chatList?.applyIncomingMute(chatJID: jid, mutedUntil:
  until, at: Date(timeIntervalSince1970: TimeInterval(ts)))`.

### UI — context menus

- **Sidebar row context menu** (`yawac/Views/ChatListView.swift` ~line
  388, next to the existing Pin button):
  ```swift
  if (chat.mutedUntil.map { $0 > Date() }) == true {
      Button("Unmute") { Task { await vm.muteChat(chat, until: nil) } }
  } else {
      Menu("Mute") {
          Button("Mute for 8 hours") {
              Task { await vm.muteChat(chat,
                  until: Date().addingTimeInterval(8 * 3600)) }
          }
          Button("Mute for 1 week") {
              Task { await vm.muteChat(chat,
                  until: Date().addingTimeInterval(7 * 86400)) }
          }
          Button("Mute always") {
              Task { await vm.muteChat(chat,
                  until: ChatListViewModel.muteForever) }
          }
      }
  }
  ```
  The `until` parameter accepted by `vm.muteChat` carries the
  always-sentinel via a private constant
  `ChatListViewModel.muteForever = Date(timeIntervalSinceReferenceDate:
  253_402_300_799)` (year-9999 UTC; matches whatsmeow's `MutedForever`
  when round-tripped through Unix-ms).
- **Conversation header context menu** (`yawac/Views/ConversationView.swift`
  ~line 200, next to the Pin / Archive buttons): identical block.

`vm.muteChat(_ chat: Chat, until: Date?)` is the single entry point
for both UIs; it calls `client.muteChat(chat.jid, mute: until != nil,
mutedUntil: until)`, applies `applyLocalMute(chatJID: chat.jid,
mutedUntil: until)` optimistically, and shows a `transientError` on
bridge failure (rolling back the optimistic update).

### UI — sidebar row badge + dimmed unread

- **Bell badge** — in the per-row chrome around the timestamp area
  (`ChatListView.swift:509` is where pin renders today), add:
  ```swift
  if (chat.mutedUntil.map { $0 > Date() }) == true {
      Image(systemName: "bell.slash.fill")
          .scaledIcon(10)
          .foregroundStyle(Theme.textFaint)
  }
  ```
  Placed next to the existing pin icon. Identical sizing / palette.
- **Dimmed unread chip** — the existing unread-count renderer uses
  `Theme.accent` background. Wrap:
  ```swift
  let muted = (chat.mutedUntil.map { $0 > Date() }) == true
  let bg = muted ? Theme.surfaceAlt : Theme.accent
  let fg = muted ? Theme.textMuted : Color.white
  ```
  Same shape, palette swap. One ternary; no layout change.

## Cold-start reconcile

`ChatListViewModel.init` (line ~21 area) currently calls
`loadChats()` then `reconcilePinsWithStore()`. Add a
`reconcileMutedWithStore()` immediately after. This call does NOT fire
notifications and does NOT cancel pending notifications already in
NotificationCenter — it only updates the row state. WhatsApp's own
clients drop expired mutes server-side, so the store's view is
authoritative.

## Mention-pierce detail

The mention-pierce check uses the same logic the receiver renders:
the message body contains `@<own-digits>` (e.g. `@358501234567`)
matching the user's phone JID's pre-`@` digits. This works for both
direct mentions (someone typed `@you`) and `@everyone` expansions
(every participant's JID lands in `ContextInfo.MentionedJID`, and the
body carries the literal `@everyone` — for the everyone case the
sender's body contains `@everyone` not the recipient's digits, so the
mention-pierce predicate based on `text.contains("@\(ownDigits)")`
would NOT pierce on `@everyone`). That's the intentional v1 trade:
direct `@you` pierces, `@everyone` doesn't (avoids waking everyone in
a 200-person muted group when one person types `@everyone`). If we
later want `@everyone` to pierce, extend the check to also consult the
incoming message's `mentionedJIDs` array.

## Testing

### Unit

- **`ChatListViewModelMuteTests`** (new):
  - `applyLocalMute(chatJID:, mutedUntil:)` sets the row's `mutedUntil`
    and persists.
  - `isMuted(_, now:)` returns false for nil, true for future,
    false for past timestamps.
  - `pushUnreadToSession` total excludes muted chats with `unread > 0`.
  - `isMutedForNotification` returns false on non-muted, true on muted
    + no mention, false on muted + body contains `@<ownDigits>`.
  - `applyIncomingMute` honors lww — older incoming event doesn't
    overwrite newer local mute.
- **Bridge** (`bridge/appstate_test.go`):
  - `MuteChat(jid, true, futureMs)` invokes whatsmeow's
    `BuildMuteAbs` with a non-nil `*int64` matching the input. Use
    a fake `WAStore` if the existing pin test uses one.
  - `MuteChat(jid, false, 0)` invokes `BuildMuteAbs` with `mute=false`
    and `nil` end.
  - `ListMutedChats()` round-trips a seeded mute through the JSON
    return shape.

### Manual

- Pick a chat. Right-click → Mute → 8 hours. Bell badge appears next
  to timestamp.
- Send a message to the chat from a phone. No banner. Dock badge does
  NOT increment.
- Open the chat. Unread count shows in the muted (dim) palette;
  flips back to bright after read.
- Reaction notifications: react to your message from a phone in the
  muted chat. No banner.
- In a muted group, send `@<your-name>` from a phone. Banner fires
  (mention pierces).
- In a muted group, send `@everyone` from a phone. No banner (v1
  intent).
- Unmute via context menu. Bell badge disappears. Next inbound
  banners normally and bumps dock.
- Mute from a second device (phone). The mute event arrives within
  seconds; bell appears on yawac's row.
- Restart yawac. Bell stays (cold-start reconcile re-reads the store).
- Mute "Always". The end time stored is the whatsmeow `MutedForever`
  sentinel; on the phone, the chat shows "Always" too.

## Components touched

**New files:**
- `yawacTests/ChatListViewModelMuteTests.swift`

**Modified files:**
- `bridge/appstate.go` — `MuteChat`, `ListMutedChats`.
- `bridge/events.go` — `case *events.Mute` + `dispatchMute`.
- `bridge/jsonmodels.go` — `JChatMuted`.
- `bridge/appstate_test.go` — `MuteChat` test cases.
- `bridge/events_dispatch_test.go` — `dispatchMute` test.
- `yawac/Models/PersistedMessage.swift` — `PersistedChat.mutedUntil`.
- `yawac/Models/Chat.swift` — UI struct `mutedUntil`.
- `yawac/Bridge/WAClient.swift` — `muteChat`, `listMutedChats`,
  `BridgeMuteResult`, `Event.chatMuted`, dispatch decoder.
- `yawac/ViewModels/ChatListViewModel.swift` — `applyLocalMute`,
  `applyIncomingMute`, `reconcileMutedWithStore`, `isMuted`,
  `isMutedForNotification`, `muteChat(_:until:)`, dock-badge sum tweak,
  banner-gate at the two notification call sites.
- `yawac/ViewModels/SessionViewModel.swift` — `ownPhoneDigits` (if
  not already present).
- `yawac/ContentView.swift` — `.chatMuted` event apply.
- `yawac/Views/ChatListView.swift` — row context-menu Mute/Unmute
  submenu, bell badge, dimmed unread chip.
- `yawac/Views/ConversationView.swift` — header context-menu
  Mute/Unmute submenu.

## Risks

- **whatsmeow `MutedForever` sentinel round-trip.** The year-9999 UTC
  value loses sub-second precision when packed into Int64 ms and back.
  Compare via `>` not `==` when checking "is this forever". The
  `Date(timeIntervalSinceReferenceDate: 253_402_300_799)` constant
  matches the second-precision value; if the actual sentinel
  emitted by whatsmeow differs slightly, treat "any date > now + 100
  years" as forever in the UI label.
- **Bridge `*events.Mute` not previously imported.** Confirm the
  event type's exact qualified name in
  `~/go/pkg/mod/github.com/vadika/whatsmeow.../types/events/appstate.go:76`
  matches `events.Mute`; if it's `events.MuteChange` or similar,
  adjust the switch case accordingly. Implementation plan will verify.
- **`@everyone` doesn't pierce mute (v1 intent).** Documented above.
  If users complain, the fix is small: extend `isMutedForNotification`
  to consult the incoming message's `mentionedJIDs` (whatsmeow exposes
  it on `events.Message.Info.ContextInfo`).
- **Reconcile race vs in-flight events.** If a `chatMuted` event
  arrives during `reconcileMutedWithStore`, the lww rule on
  `applyIncomingMute` handles it — the later timestamp wins.
