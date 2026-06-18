# F97 — Shortcuts / App Intents

> Roadmap entry: `docs/ROADMAP.md` — Productivity / macOS → Shortcuts / AppleScript integration.

## Goal

Expose four user-initiated actions as native macOS App Intents so power users can wire WhatsApp into Shortcuts.app, Spotlight, and Siri workflows. The official WhatsApp Mac client offers none of this — pure yawac differentiator.

## Surface

Four intents, App Intents framework only (modern path; AppleScript sdef deferred to a future cycle if requested).

| Intent | Summary | Input parameters | Result |
|---|---|---|---|
| `SendWhatsAppMessage` | "Send WhatsApp message via yawac" | `chat: String` (phone or name), `body: String` | `.result(value: "Sent")` or `.error` |
| `OpenWhatsAppChat` | "Open WhatsApp chat in yawac" | `chat: String` | `.result()` (opens window + selects chat) |
| `MarkWhatsAppChatRead` | "Mark WhatsApp chat as read in yawac" | `chat: String` | `.result(value: "Marked read")` |
| `SearchWhatsAppMessages` | "Search WhatsApp messages in yawac" | `query: String` | `.result()` (opens window + focuses ⌘K + sets query) |

All four have `static var openAppWhenRun: Bool { true }` — they need the running yawac process (live `WAClient` + SwiftData store) so headless invocation isn't supported. Shortcuts will launch yawac if it isn't already running.

## Architecture

```
yawac/Intents/
├── ChatResolver.swift           // pure helper: input → Chat
├── ChatResolverTests.swift      // unit test (in yawacTests/)
├── SendMessageIntent.swift
├── OpenChatIntent.swift
├── MarkReadIntent.swift
├── SearchMessagesIntent.swift
└── YawacShortcutsProvider.swift // AppShortcutsProvider registration
```

Each intent is a `struct: AppIntent` (Swift). Pulls the live session via:

```swift
@Dependency private var session: SessionViewModel
```

(yawac's App scene registers the session as an App Intents dependency via `AppDependencyManager`.)

## Chat resolver

Pure function. Single source of truth for "user typed something, give me the Chat row".

```swift
enum ChatResolveError: Error, LocalizedError {
    case notPaired
    case notFound(input: String)
    case ambiguous(input: String, matches: [String])  // chat names
    var errorDescription: String? { … }
}

/// F97: resolve user input (phone or contact name) to a Chat in
/// `chats`. Tries phone-parse first, then case-insensitive substring
/// match on chat name. Errors on zero / multiple matches.
static func resolveChat(_ input: String, in chats: [Chat]) throws -> Chat {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ChatResolveError.notFound(input: input) }

    // 1. Phone path: extract digits, try @s.whatsapp.net + @lid suffixes.
    let digits = trimmed.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(Character.init).map(String.init).joined()
    if !digits.isEmpty {
        for suffix in ["@s.whatsapp.net", "@lid"] {
            if let hit = chats.first(where: { $0.jid == "\(digits)\(suffix)" }) {
                return hit
            }
        }
    }

    // 2. Name path: case-insensitive substring match.
    let lower = trimmed.lowercased()
    let nameMatches = chats.filter { $0.name.lowercased().contains(lower) }
    switch nameMatches.count {
    case 0: throw ChatResolveError.notFound(input: input)
    case 1: return nameMatches[0]
    default: throw ChatResolveError.ambiguous(input: input, matches: nameMatches.map(\.name))
    }
}
```

Pure-function tests:
- empty input → `.notFound`
- phone matches `@s.whatsapp.net` → match
- phone matches `@lid` (no `@s.whatsapp.net` row) → match
- exact name → match
- substring name (case-insensitive) → match
- 2 name matches → `.ambiguous`
- 0 matches → `.notFound`

## Intent bodies

Send:
```swift
struct SendWhatsAppMessage: AppIntent {
    static var title: LocalizedStringResource = "Send WhatsApp Message"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat") var chat: String
    @Parameter(title: "Message") var body: String
    @Dependency private var session: SessionViewModel

    func perform() async throws -> some IntentResult {
        guard let client = session.client else { throw ChatResolveError.notPaired }
        let chats = session.chatList?.chats ?? []
        let target = try ChatResolver.resolveChat(chat, in: chats)
        try await Task.detached { [client, jid = target.jid, body] in
            _ = try client.sendText(jid, body)
        }.value
        return .result(value: "Sent")
    }
}
```

Open chat: writes `session.pendingShortcutSelectJID = jid` (new `@Observable` field). ContentView observes via `.onChange` and forwards into the existing `selection: Chat.ID?` binding; window forwards via `WindowToggler.bringToFront()` (already exists per `yawacApp.swift:218`).

Mark read: resolves → calls existing `vm.markRead(jid)` on chatList.

Search: writes `session.pendingShortcutQuery = query` + `session.pendingShortcutFocusSearch = true`. ChatListView observes + sets `search.query` + focuses the search field.

## Wiring into the App

`yawacApp.swift`:

```swift
// In App init, after session is constructed:
AppDependencyManager.shared.add(dependency: session)
```

```swift
// New struct registered at App scope:
struct YawacShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendWhatsAppMessage(),
                    phrases: ["Send WhatsApp message via \(.applicationName)"],
                    shortTitle: "Send Message",
                    systemImageName: "paperplane")
        AppShortcut(intent: OpenWhatsAppChat(),
                    phrases: ["Open WhatsApp chat in \(.applicationName)"],
                    shortTitle: "Open Chat",
                    systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: MarkWhatsAppChatRead(),
                    phrases: ["Mark WhatsApp chat read in \(.applicationName)"],
                    shortTitle: "Mark Chat Read",
                    systemImageName: "checkmark.message")
        AppShortcut(intent: SearchWhatsAppMessages(),
                    phrases: ["Search WhatsApp messages in \(.applicationName)"],
                    shortTitle: "Search Messages",
                    systemImageName: "magnifyingglass")
    }
}
```

Shortcuts.app picks up `YawacShortcutsProvider` on first launch under macOS 14+.

## SessionViewModel additions

Three new `@Observable` fields for cross-intent → view-state plumbing:

```swift
var pendingShortcutSelectJID: String? = nil      // OpenChat / Send (post-send open)
var pendingShortcutQuery: String? = nil          // Search
```

Consumption protocol: the view's `.onChange` handler (ContentView for selection, ChatListView for query) reads the value, applies it, and writes nil back to the published field — so a repeat shortcut firing with the same value re-triggers the change. No `@Persisted` storage — purely transient.

## Error handling

- Unpaired → `ChatResolveError.notPaired` (Shortcuts surfaces "No account paired")
- Chat input doesn't resolve → `.notFound` ("No chat matched X")
- Multiple name matches → `.ambiguous` ("Matched N chats: A, B, C — be more specific")
- Send failure (network, bridge) → throws underlying error
- Mark-read on unread=0 → no-op, returns success

## Testing

- `yawacTests/ChatResolverTests.swift` — 7 pure-function cases above
- No intent-body tests (App Intents framework is hard to unit-test; `@Dependency` injection is opaque)
- Manual smoke: ship Debug build, open Shortcuts.app, run each intent with sample inputs

## Migration / risk

- Pure additive. No existing call sites change.
- ContentView gains 2 `.onChange` handlers (pendingShortcutSelectJID + pendingShortcutQuery).
- ChatListView's search field gains 1 `.onChange` for query input.
- No bridge / Go code changes.
- macOS 14 deployment target already covers App Intents.

## Out of scope (v1)

- AppleScript sdef (deferred — add when users ask)
- Send with attachment (file path → media send)
- Reply-to-message intent (needs message-ID surface)
- Receive-side intents (e.g. "When I get a message from X, do Y") — that's `AppIntent` triggers, much heavier
- Multi-account targeting (covered by future Multi-account work)

## File summary

| File | Action |
|---|---|
| `yawac/Intents/ChatResolver.swift` | Create |
| `yawac/Intents/SendMessageIntent.swift` | Create |
| `yawac/Intents/OpenChatIntent.swift` | Create |
| `yawac/Intents/MarkReadIntent.swift` | Create |
| `yawac/Intents/SearchMessagesIntent.swift` | Create |
| `yawac/Intents/YawacShortcutsProvider.swift` | Create |
| `yawac/ViewModels/SessionViewModel.swift` | Modify — add 2 `@Observable` pending* fields |
| `yawac/yawacApp.swift` | Modify — `AppDependencyManager.shared.add(dependency: session)` + provider hookup |
| `yawac/Views/ContentView.swift` | Modify — 2 `.onChange` handlers |
| `yawac/Views/ChatListView.swift` | Modify — 1 `.onChange` for search query |
| `yawacTests/ChatResolverTests.swift` | Create — 7 cases |
| `docs/ROADMAP.md` | Modify — flip Shortcuts/AppleScript ☐ → ✅ (F97) |
| `project.yml` / `yawac/Info.plist` | Modify — version 0.10.31 |
