# Sidebar Search — Design

**Date:** 2026-05-24
**Status:** Approved
**Scope:** Sidebar chat-list search by contact name and phone number, with bridge-validated new-chat affordance for unknown numbers. In-chat message search is explicitly out of scope.

## Goal

Replace the placeholder "Search" hint in `ChatListView` (yawac/Views/ChatListView.swift:105–131) with a real text field that:

1. Filters the existing chat list by contact/group name (case-insensitive substring).
2. Filters by phone number across JID format variants (`+49 151…`, `49151…`, `0151…`).
3. When the user types a phone number that doesn't match any existing chat, validates it through the whatsmeow bridge and offers a "Start chat with +X" row that opens an empty conversation against that JID.

## Non-goals

- Searching inside message bodies.
- Global ⌘F shortcut.
- Contact-import or address-book integration.
- Multi-number paste / bulk lookups.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ ChatListView (SwiftUI)                                  │
│   ├ TextField bound to search.query  (⌘K focuses)       │
│   ├ list rows ← search.filteredChats                    │
│   └ optional "Start chat with +X" row ← search.suggestion│
└──────────────┬──────────────────────────────────────────┘
               │
   ┌───────────▼─────────────────┐
   │ ChatSearchViewModel         │  @Observable @MainActor
   │   query: String             │
   │   filteredChats: [Chat]     │  derived from listVM.chats
   │   suggestion: PhoneSuggestion?
   │   debounceTask: Task<…>     │  500ms idle
   │   validate(phone) → bridge  │
   └───────────┬─────────────────┘
               │
   ┌───────────▼──────────┐    ┌──────────────────────────┐
   │ ChatListViewModel    │    │ WAClient                 │
   │   .chats source      │    │   .checkOnWhatsApp(phone)│
   └──────────────────────┘    └────────────┬─────────────┘
                                            │
                                  ┌─────────▼──────────┐
                                  │ bridge/contacts.go │
                                  │ CheckOnWhatsApp()  │
                                  │ → whatsmeow.IsOnWA │
                                  └────────────────────┘
```

**Data flow:** keystroke → `query` set → cancel prior debounce Task → restart 500ms Task → on fire, run name-filter (sync) → if input matches phone heuristic AND no existing chat hit, call bridge → set `suggestion`. Tapping the suggestion creates a stub `Chat` via `ChatListViewModel.upsertStubChat(jid:)` and routes selection to its id; `ConversationView` opens against an empty message list; first send triggers the normal send flow.

## Components

### New: `yawac/ViewModels/ChatSearchViewModel.swift`

```swift
@Observable @MainActor
final class ChatSearchViewModel {
    var query: String = "" { didSet { onQueryChanged() } }
    private(set) var filteredChats: [Chat] = []
    private(set) var suggestion: PhoneSuggestion? = nil
    private(set) var validating: Bool = false

    private weak var listVM: ChatListViewModel?
    private let client: WAClient
    private var debounceTask: Task<Void, Never>? = nil

    init(listVM: ChatListViewModel, client: WAClient) { … }

    func clear()                       // reset query + suggestion
    private func onQueryChanged()      // cancel + restart debounce
    private func runFilter() async     // name/phone substring
    private func maybeValidate() async // 500ms gate → bridge call
}

struct PhoneSuggestion: Equatable {
    let jid: String        // e.g. "4915123456789@s.whatsapp.net"
    let displayPhone: String
}
```

### Modify: `yawac/Views/ChatListView.swift`

- Replace fake "Search" hint block (lines 105–131) with a real `TextField` bound to `search.query`, styled to match the current Theme.
- Add `@FocusState private var searchFocused: Bool`.
- Hidden button with `.keyboardShortcut("k", modifiers: .command)` → `searchFocused = true`.
- `displayRows()` reads from `search.filteredChats` when `search.query` is non-empty; otherwise current behavior unchanged.
- New `Row.suggestion(PhoneSuggestion)` variant, rendered as a distinct row ("Start chat with +X · Tap to open"). Tap → `listVM.upsertStubChat(jid:displayName:)` → `selection = chat.id` → `search.clear()`.

### Modify: `yawac/ViewModels/ChatListViewModel.swift`

- Add `func upsertStubChat(jid: String, displayName: String) -> Chat.ID`. Inserts a `Chat` with empty `lastMessage`, `lastTimestamp = Int64(Date().timeIntervalSince1970)`, `unread = 0`. Persists via existing `upsertPersisted`. Idempotent: returns existing id if JID already present.

### Modify: `yawac/Bridge/WAClient.swift`

```swift
func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult
```

Wraps the gomobile call, decodes JSON.

```swift
struct PhoneCheckResult: Decodable {
    let jid: String
    let registered: Bool
    let businessName: String?
}
```

### Modify: `bridge/contacts.go`

```go
func (b *Bridge) CheckOnWhatsApp(phone string) (string, error)
```

Calls `b.cli.IsOnWhatsApp([]string{phone})`, marshals first result to JSON `{jid, registered, business_name}`. Returns the JSON string and a nil error on success; returns an error string on bridge failure.

### Modify: `yawac/AppRoot.swift`

Instantiate `ChatSearchViewModel(listVM:, client:)` alongside existing VMs and inject into `ChatListView`.

## Data flow & matching rules

### Local name/phone filter

- Normalize query: trim, lowercase, strip spaces and hyphens.
- For each `Chat`, match if:
  - `chat.name.localizedCaseInsensitiveContains(query)`, OR
  - `digitsOnly(query)` is non-empty AND `digitsOnly(chat.jid)` contains it.
- Preserve existing sort (lastTimestamp desc, name asc tiebreak).
- Sections in `displayRows()` still applied to the filtered set; empty sections hidden.

### Phone heuristic for bridge validation

- Strip everything but digits and a single leading `+`.
- Trigger validation iff: query starts with `+`, OR has ≥ 7 consecutive digits AND no letters.
- Pass the digits-only form (no `+`) to the bridge — whatsmeow `IsOnWhatsApp` accepts the raw international form.

### Debounce

```swift
debounceTask?.cancel()
debounceTask = Task {
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled else { return }
    await runFilter()
    await maybeValidate()
}
```

`runFilter()` runs every fire (cheap, in-memory). `maybeValidate()` only runs when the heuristic matches AND no existing chat matched the digit form (avoid re-validating known contacts).

### Bridge call

- `validating = true` → spinner on suggestion row.
- `Task.detached` for the synchronous gomobile call; `await` result back on main.
- `registered == true` → `suggestion = PhoneSuggestion(jid: result.jid, displayPhone: "+\(digits)")`.
- `registered == false` → `suggestion = nil`, optionally show greyed "Not on WhatsApp" hint row.
- Error → `suggestion = nil`, log via `NSLog`. No user-facing error in v1.

### Suggestion tap

1. `listVM.upsertStubChat(jid:, displayName:)` — idempotent.
2. `selection = chat.id` → `ConversationView` opens (empty message list state already handled by existing code).
3. `search.clear()` — sidebar returns to full list.

### Race & cancellation

- New keystroke cancels the in-flight debounce Task (Task cancellation propagates to the bridge call wrapper).
- If a real message for the stub JID arrives mid-typing, the existing `ingest()` path upserts the chat — `upsertStubChat` is a no-op on conflict.

## Error handling & edge cases

- **Bridge unavailable / not connected:** `WAClient.checkOnWhatsApp` throws; VM catches, clears suggestion, logs.
- **Rate limiting:** bridge returns `"rate_limited"`; VM keeps last successful suggestion, schedules silent retry after 5s. Single attempt — no retry storm.
- **Logged out / no session:** skip bridge call entirely; local filter still works against cached chats.
- **Empty query:** `filteredChats = listVM.chats`; `suggestion = nil`.
- **Query matches existing chat by digits:** skip bridge call.
- **Self-number entered:** compare against `client.ownJID`; suppress suggestion.
- **Query contains `+` but < 7 digits:** no bridge call; local filter still runs.
- **Rapid type then clear:** debounce cancellation; empty-string set triggers `clear()` synchronously.
- **Suggestion row rendering:** matches existing chat row layout. Avatar = `person.crop.circle.badge.plus`. Name = displayPhone. Subtitle = "Start new chat". Optional spinner during `validating`.
- **Stub chat persistence:** `upsertStubChat` writes a `PersistedChat` row. Survives restart even if user never sends. Matches WhatsApp mobile behavior.

## Testing

### Unit tests (`yawacTests/`)

- `ChatSearchViewModelTests`
  - empty query passes through all chats
  - name substring match (case-insensitive)
  - digit substring match across JID format variants
  - phone heuristic: `+49…` yes, `hello` no, `12345` no (< 7 digits), `1234567` yes
  - debounce: rapid sets fire only one filter run
  - cancellation: new query while bridge call in flight discards stale result
  - self-JID filtered from suggestions
- `BridgeClientTests` (extend)
  - `checkOnWhatsApp` decodes valid JSON
  - throws on bridge error string

### Bridge Go test (`bridge/contacts_test.go`)

- mock whatsmeow client; assert JSON shape and error path

### Manual smoke

- Type partial contact name → list narrows.
- Type own phone → no suggestion.
- Type unknown valid number → spinner → "Start chat" row.
- Tap suggestion → conversation opens.
- ⌘K from any focus state → caret in search field.

## File touch list

| File | Action |
|---|---|
| `yawac/ViewModels/ChatSearchViewModel.swift` | new |
| `yawac/Views/ChatListView.swift` | modify (search field, suggestion row, displayRows wiring) |
| `yawac/ViewModels/ChatListViewModel.swift` | modify (add `upsertStubChat`) |
| `yawac/Bridge/WAClient.swift` | modify (add `checkOnWhatsApp`, `PhoneCheckResult`) |
| `bridge/contacts.go` | modify (add `CheckOnWhatsApp`) |
| `bridge/contacts_test.go` | modify (add test) |
| `yawac/AppRoot.swift` | modify (instantiate + inject) |
| `yawacTests/ChatSearchViewModelTests.swift` | new |
| `yawacTests/BridgeClientTests.swift` | modify (add cases) |
