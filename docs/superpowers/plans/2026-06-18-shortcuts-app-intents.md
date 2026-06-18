# F97 — Shortcuts / App Intents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Project rule:** Before EVERY commit, run a ponytail-review pass on the touched code. Catch over-engineering at PR-time, not in a months-later audit. See `feedback_ponytail_before_commit.md`.

**Goal:** Expose `Send WhatsApp Message`, `Open WhatsApp Chat`, `Mark WhatsApp Chat Read`, `Search WhatsApp Messages` as native macOS App Intents so power users wire yawac into Shortcuts.app / Spotlight / Siri.

**Architecture:** Pure additive. New `yawac/Intents/` folder holds intent structs + a pure `ChatResolver`. Intents use `@Dependency` injection of `SessionViewModel`, run with `openAppWhenRun=true`. All four intents reach `session` methods via `MainActor.run`. The Search intent is the one exception that needs view-state plumbing (a published `pendingShortcutQuery` field on SessionViewModel that ContentView observes). No bridge / Go changes.

**Tech Stack:** Swift 5.10, App Intents framework, SwiftUI, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-06-18-shortcuts-app-intents-design.md`

**Deviation from spec:** Spec proposed both `pendingShortcutSelectJID` AND `pendingShortcutQuery`. Per ponytail: OpenChat / MarkRead intents call `session.openRootChat(jid)` / `chatList.markRead(jid)` directly via `MainActor.run` — no published field needed. Only Search needs the published-field plumbing because `chatSearch` is owned by ContentView, not session.

---

## Pre-flight

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
```

XcodeGen regenerates the project when `.swift` files are added — run `xcodegen` after `Create:` steps so xcodebuild finds new files.

---

## File map

| File | Action |
|---|---|
| `yawac/Intents/ChatResolver.swift` | Create |
| `yawacTests/ChatResolverTests.swift` | Create |
| `yawac/Intents/SendMessageIntent.swift` | Create |
| `yawac/Intents/OpenChatIntent.swift` | Create |
| `yawac/Intents/MarkReadIntent.swift` | Create |
| `yawac/Intents/SearchMessagesIntent.swift` | Create |
| `yawac/Intents/YawacShortcutsProvider.swift` | Create |
| `yawac/ViewModels/SessionViewModel.swift` | Modify — add `pendingShortcutQuery: String? = nil` |
| `yawac/yawacApp.swift` | Modify — `AppDependencyManager.shared.add(dependency: session)` + scene-level `YawacShortcutsProvider` registration |
| `yawac/ContentView.swift` | Modify — `.onChange(of: session.pendingShortcutQuery)` handler |
| `docs/ROADMAP.md` | Modify — flip ☐ Shortcuts/AppleScript → ✅ F97 v0.10.31 |
| `project.yml` / `yawac/Info.plist` | Modify — version 0.10.31 / build 114 |

---

## Task 1: ChatResolver + tests

**Files:**
- Create: `yawac/Intents/ChatResolver.swift`
- Create: `yawacTests/ChatResolverTests.swift`

- [ ] **Step 1: Write the failing tests**

`yawacTests/ChatResolverTests.swift`:

```swift
import XCTest
@testable import yawac

final class ChatResolverTests: XCTestCase {

    func testEmptyInputThrowsNotFound() {
        XCTAssertThrowsError(
            try ChatResolver.resolveChat("", in: [makeChat("1@s.whatsapp.net", "Alice")])
        ) { err in
            guard case ChatResolveError.notFound = err else {
                XCTFail("expected notFound, got \(err)")
                return
            }
        }
    }

    func testPhoneMatchesWhatsAppNet() throws {
        let chats = [
            makeChat("12345@s.whatsapp.net", "Alice"),
            makeChat("67890@s.whatsapp.net", "Bob"),
        ]
        let out = try ChatResolver.resolveChat("12345", in: chats)
        XCTAssertEqual(out.jid, "12345@s.whatsapp.net")
    }

    func testPhoneMatchesLIDFallback() throws {
        let chats = [makeChat("99999@lid", "Carol")]
        let out = try ChatResolver.resolveChat("99999", in: chats)
        XCTAssertEqual(out.jid, "99999@lid")
    }

    func testPhoneWithPlusAndSpacesNormalized() throws {
        let chats = [makeChat("12345550100@s.whatsapp.net", "Alice")]
        let out = try ChatResolver.resolveChat("+1 234 555-0100", in: chats)
        XCTAssertEqual(out.jid, "12345550100@s.whatsapp.net")
    }

    func testExactNameMatch() throws {
        let chats = [
            makeChat("1@s.whatsapp.net", "Alice"),
            makeChat("2@s.whatsapp.net", "Bob"),
        ]
        let out = try ChatResolver.resolveChat("Alice", in: chats)
        XCTAssertEqual(out.jid, "1@s.whatsapp.net")
    }

    func testSubstringNameMatchCaseInsensitive() throws {
        let chats = [makeChat("1@s.whatsapp.net", "Alice Smith")]
        let out = try ChatResolver.resolveChat("alice", in: chats)
        XCTAssertEqual(out.jid, "1@s.whatsapp.net")
    }

    func testAmbiguousNameThrows() {
        let chats = [
            makeChat("1@s.whatsapp.net", "Alice Smith"),
            makeChat("2@s.whatsapp.net", "Alice Jones"),
        ]
        XCTAssertThrowsError(try ChatResolver.resolveChat("alice", in: chats)) { err in
            guard case let ChatResolveError.ambiguous(_, matches) = err else {
                XCTFail("expected ambiguous, got \(err)")
                return
            }
            XCTAssertEqual(matches.sorted(), ["Alice Jones", "Alice Smith"])
        }
    }

    func testNoMatchThrowsNotFound() {
        let chats = [makeChat("1@s.whatsapp.net", "Alice")]
        XCTAssertThrowsError(try ChatResolver.resolveChat("Charlie", in: chats)) { err in
            guard case ChatResolveError.notFound = err else {
                XCTFail("expected notFound, got \(err)")
                return
            }
        }
    }

    private func makeChat(_ jid: String, _ name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -5
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatResolverTests test 2>&1 | tail -10
```
Expected: `cannot find 'ChatResolver' in scope`.

- [ ] **Step 3: Create `yawac/Intents/ChatResolver.swift`**

```swift
import Foundation

/// F97: chat-input resolver shared by all Shortcut intents. Pure
/// function — testable without an App Intents harness. Tries
/// phone-parse first, falls back to case-insensitive substring name
/// match. Errors on zero or multiple name matches.
enum ChatResolveError: Error, LocalizedError {
    case notPaired
    case notFound(input: String)
    case ambiguous(input: String, matches: [String])

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "No WhatsApp account is paired."
        case .notFound(let input):
            return "No chat matched \"\(input)\"."
        case .ambiguous(let input, let matches):
            let preview = matches.prefix(5).joined(separator: ", ")
            let extra = matches.count > 5 ? " and \(matches.count - 5) more" : ""
            return "\"\(input)\" matched \(matches.count) chats: \(preview)\(extra). Be more specific."
        }
    }
}

enum ChatResolver {
    static func resolveChat(_ input: String, in chats: [Chat]) throws -> Chat {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatResolveError.notFound(input: input) }

        // Phone path: keep digits only, try both @s.whatsapp.net + @lid.
        let digits = String(trimmed.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(Character.init))
        if !digits.isEmpty {
            for suffix in ["@s.whatsapp.net", "@lid"] {
                if let hit = chats.first(where: { $0.jid == "\(digits)\(suffix)" }) {
                    return hit
                }
            }
        }

        // Name path: case-insensitive substring match.
        let lower = trimmed.lowercased()
        let nameMatches = chats.filter { $0.name.lowercased().contains(lower) }
        switch nameMatches.count {
        case 0:
            throw ChatResolveError.notFound(input: input)
        case 1:
            return nameMatches[0]
        default:
            throw ChatResolveError.ambiguous(input: input, matches: nameMatches.map(\.name))
        }
    }
}
```

- [ ] **Step 4: Regen project + run test — expect pass**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatResolverTests test 2>&1 | tail -10
```
Expected: 8/8 pass.

- [ ] **Step 5: Ponytail-review the diff**

Re-read both files for: single-impl abstractions, dead flexibility, hand-rolled stdlib, single-caller helpers. Likely findings to consider:
- Is `ChatResolveError.notPaired` used yet? (Will be used by intents in later tasks — keep.)
- Is the `for suffix in ["@s.whatsapp.net", "@lid"]` loop needlessly generic? (Two suffixes, the loop is the right shape.)
- Could the digit-filter be simpler? (`String(trimmed.filter(\.isNumber))` is shorter — apply if so.)

If you find a tightening opportunity, apply it before committing.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/Intents/ChatResolver.swift yawacTests/ChatResolverTests.swift yawac.xcodeproj
git commit -m "F97: ChatResolver pure helper + 8 tests"
```

---

## Task 2: SessionViewModel pendingShortcutQuery field

**Files:**
- Modify: `yawac/ViewModels/SessionViewModel.swift`

- [ ] **Step 1: Find the right insertion point**

Run:
```bash
grep -n "@Observable @MainActor\|^final class SessionViewModel\|var client: WAClient" /Users/vadikas/Work/yawac/yawac/ViewModels/SessionViewModel.swift | head -5
```
Class declaration is around line 6-7. Add the field near other `@Observable` published fields.

- [ ] **Step 2: Add the field**

Add (around line 109, near `weak var chatList`):

```swift
    /// F97: Search shortcut payload. SearchMessagesIntent writes the
    /// query string here; ChatListView observes and applies to the
    /// existing ChatSearchViewModel. Consumer resets to nil after
    /// applying so re-firing the same query re-triggers the change.
    var pendingShortcutQuery: String? = nil
```

- [ ] **Step 3: Build to verify**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Ponytail-review**

Single field, default value, one-line. Nothing to tighten. Proceed.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/SessionViewModel.swift
git commit -m "F97: SessionViewModel.pendingShortcutQuery for SearchMessagesIntent"
```

---

## Task 3: SendMessageIntent

**Files:**
- Create: `yawac/Intents/SendMessageIntent.swift`

- [ ] **Step 1: Create the intent**

```swift
import AppIntents
import Foundation

/// F97: "Send WhatsApp Message" Shortcut. Resolves the chat input
/// (phone or contact name) and invokes the existing
/// `WAClient.sendText` via the live `SessionViewModel`. App must be
/// running (or will be launched) because the bridge holds live state.
struct SendWhatsAppMessage: AppIntent {
    static var title: LocalizedStringResource = "Send WhatsApp Message"
    static var description = IntentDescription("Sends a WhatsApp message via yawac to a chat looked up by phone number or contact name.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Parameter(title: "Message")
    var body: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let client = session.client else { throw ChatResolveError.notPaired }
        let chats = session.chatList?.chats ?? []
        let target = try ChatResolver.resolveChat(chat, in: chats)
        let result = try await Task.detached(priority: .userInitiated) {
            [client, jid = target.jid, body = self.body] in
            try client.sendText(jid, body)
        }.value
        return .result(value: "Sent message \(result.messageID)")
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

If `sendText` signature differs (it returns a struct with `messageID`), verify with `grep -n "func sendText" yawac/Bridge/WAClient.swift`. Adjust the return-value extraction accordingly. If it returns void, change the success message to `"Sent"`.

- [ ] **Step 3: Ponytail-review**

Re-read SendMessageIntent.swift:
- Is `IntentDescription` redundant? (No — surfaces in Shortcuts.app UI as user-facing tooltip; keep.)
- Is `priority: .userInitiated` warranted? (Yes — user actively triggered; right hint.)
- Could `[client, jid = target.jid, body = self.body]` be simpler? (Needs all three for sendable cross-actor capture; leave.)

- [ ] **Step 4: Commit**

```bash
git add yawac/Intents/SendMessageIntent.swift yawac.xcodeproj
git commit -m "F97: SendWhatsAppMessage App Intent"
```

---

## Task 4: OpenChatIntent

**Files:**
- Create: `yawac/Intents/OpenChatIntent.swift`

- [ ] **Step 1: Create the intent**

```swift
import AppIntents
import Foundation

/// F97: "Open WhatsApp Chat" Shortcut. Resolves chat input, drives
/// the session navigator + brings the main window forward. Goes
/// through `SessionViewModel.openRootChat` so the existing
/// BackBar / sidebar selection logic is honored.
struct OpenWhatsAppChat: AppIntent {
    static var title: LocalizedStringResource = "Open WhatsApp Chat"
    static var description = IntentDescription("Opens a WhatsApp chat in yawac by phone number or contact name.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard session.client != nil else { throw ChatResolveError.notPaired }
        let chats = session.chatList?.chats ?? []
        let target = try ChatResolver.resolveChat(chat, in: chats)
        session.openRootChat(target.jid)
        WindowToggler.bringToFront()
        return .result()
    }
}
```

- [ ] **Step 2: Verify openRootChat signature**

```bash
grep -n "func openRootChat" /Users/vadikas/Work/yawac/yawac/ViewModels/SessionViewModel.swift
```
If signature differs (e.g. takes a `Chat.ID` not a `String`), adapt the call. `Chat.ID == String` per `Chat.swift:51` so `.jid` works either way.

- [ ] **Step 3: Build**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Ponytail-review**

Re-read OpenChatIntent.swift. `WindowToggler.bringToFront()` is existing utility (yawacApp.swift:218). No new abstraction needed.

- [ ] **Step 5: Commit**

```bash
git add yawac/Intents/OpenChatIntent.swift yawac.xcodeproj
git commit -m "F97: OpenWhatsAppChat App Intent"
```

---

## Task 5: MarkReadIntent

**Files:**
- Create: `yawac/Intents/MarkReadIntent.swift`

- [ ] **Step 1: Create the intent**

```swift
import AppIntents
import Foundation

/// F97: "Mark WhatsApp Chat Read" Shortcut. Routes through the
/// existing `ChatListViewModel.markRead(_:)` which handles bridge
/// IQ + persisted-row updates + receipt fan-out.
struct MarkWhatsAppChatRead: AppIntent {
    static var title: LocalizedStringResource = "Mark WhatsApp Chat as Read"
    static var description = IntentDescription("Marks all unread messages in a WhatsApp chat as read.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Chat", description: "Phone number or contact name")
    var chat: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard session.client != nil else { throw ChatResolveError.notPaired }
        guard let chatList = session.chatList else { throw ChatResolveError.notPaired }
        let target = try ChatResolver.resolveChat(chat, in: chatList.chats)
        chatList.markRead(target.jid)
        return .result(value: "Marked \(target.name) as read")
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 3: Ponytail-review**

Two `guard` clauses both return `.notPaired` — could merge into one but readability is fine. Leave.

- [ ] **Step 4: Commit**

```bash
git add yawac/Intents/MarkReadIntent.swift yawac.xcodeproj
git commit -m "F97: MarkWhatsAppChatRead App Intent"
```

---

## Task 6: SearchMessagesIntent + ContentView observer

**Files:**
- Create: `yawac/Intents/SearchMessagesIntent.swift`
- Modify: `yawac/ContentView.swift`

- [ ] **Step 1: Create the intent**

```swift
import AppIntents
import Foundation

/// F97: "Search WhatsApp Messages" Shortcut. Brings yawac to the
/// front and writes the query through SessionViewModel's transient
/// `pendingShortcutQuery` field; ContentView's `.onChange` observer
/// forwards into the live `ChatSearchViewModel`.
struct SearchWhatsAppMessages: AppIntent {
    static var title: LocalizedStringResource = "Search WhatsApp Messages"
    static var description = IntentDescription("Opens yawac with a search query applied to the global message index.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Query")
    var query: String

    @Dependency private var session: SessionViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        session.pendingShortcutQuery = query
        WindowToggler.bringToFront()
        return .result()
    }
}
```

- [ ] **Step 2: Wire the observer in ContentView**

Open `yawac/ContentView.swift`. Find the existing `NavigationSplitView { ... }` body. Add an `.onChange` modifier to the outer view:

```swift
        .onChange(of: session.pendingShortcutQuery) { _, newQuery in
            guard let newQuery, let chatSearch else { return }
            chatSearch.query = newQuery
            // Consume: reset so the next shortcut with the same query
            // still triggers the change.
            session.pendingShortcutQuery = nil
        }
```

Add to the same `.environment(...)` chain or as a top-level modifier on the NavigationSplitView. Match existing style (look at the existing `.task` or `.onChange` modifiers in the file for placement).

- [ ] **Step 3: Build**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```

If `chatSearch.query` is not a writable var (it may be `@Bindable` accessed via `$chatSearch.query` somewhere), use the writable form. Most likely it's a plain `var query: String = ""` per the ChatSearchViewModel pattern — direct assignment works.

- [ ] **Step 4: Ponytail-review**

The observer's `guard let newQuery, let chatSearch else { return }` is the minimal shape. The reset-to-nil is one line. Nothing to tighten.

- [ ] **Step 5: Commit**

```bash
git add yawac/Intents/SearchMessagesIntent.swift yawac/ContentView.swift yawac.xcodeproj
git commit -m "F97: SearchWhatsAppMessages App Intent + ContentView observer"
```

---

## Task 7: AppShortcutsProvider + App-level registration

**Files:**
- Create: `yawac/Intents/YawacShortcutsProvider.swift`
- Modify: `yawac/yawacApp.swift`

- [ ] **Step 1: Create the provider**

```swift
import AppIntents

/// F97: registers yawac's four Shortcuts in the system-wide
/// Shortcuts.app gallery. macOS picks this up automatically on first
/// launch after install — no UI work required to populate the
/// Shortcuts library.
struct YawacShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendWhatsAppMessage(),
            phrases: ["Send WhatsApp message via \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane")
        AppShortcut(
            intent: OpenWhatsAppChat(),
            phrases: ["Open WhatsApp chat in \(.applicationName)"],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: MarkWhatsAppChatRead(),
            phrases: ["Mark WhatsApp chat read in \(.applicationName)"],
            shortTitle: "Mark Chat Read",
            systemImageName: "checkmark.message")
        AppShortcut(
            intent: SearchWhatsAppMessages(),
            phrases: ["Search WhatsApp messages in \(.applicationName)"],
            shortTitle: "Search Messages",
            systemImageName: "magnifyingglass")
    }
}
```

- [ ] **Step 2: Register session as App Intents dependency**

Open `yawac/yawacApp.swift`. In the `init()` block (around line 37-98), after `self.container = try ModelContainer(...)`:

```swift
        // F97: expose the live session to App Intents so the four
        // shortcut intents can resolve chats + drive the navigator.
        // Must register BEFORE any intent dispatches.
        AppDependencyManager.shared.add(dependency: self.session)
```

`self.session` is the `@State private var session = SessionViewModel()` at the top of `YawacApp`.

Add `import AppIntents` at the top of yawacApp.swift if not present.

- [ ] **Step 3: Build**

```bash
cd /Users/vadikas/Work/yawac && xcodegen 2>&1 | tail -3
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```

If compile fails with "AppDependencyManager called from App.init() — NSApp not ready" (similar to the F76 NSApp memory note), move the registration into the `.onAppear` of the WindowGroup body alongside the dock-policy + menu-bar setup. Verify the actual failure first before pre-emptive moves.

If `@State private var session = SessionViewModel()` can't be read from `init()` (Swift property wrapper restriction), use a separate `let sessionRef: SessionViewModel` mirror or capture in `init`. Or move to `.task` / `.onAppear`.

- [ ] **Step 4: Run the full test target to catch regressions**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (one flaky pre-existing `TestApplyHistorySyncEmitsMessages` may fail on Linux CI — acceptable).

- [ ] **Step 5: Ponytail-review**

`YawacShortcutsProvider` is the only consumer of the four intents at this layer. Its 4-block declaration is the App Intents framework convention — no tightening.

The yawacApp.swift addition is one line in init() + an `import`. Minimal.

- [ ] **Step 6: Commit**

```bash
git add yawac/Intents/YawacShortcutsProvider.swift yawac/yawacApp.swift yawac.xcodeproj
git commit -m "F97: YawacShortcutsProvider + AppDependencyManager registration"
```

---

## Task 8: Manual smoke + release v0.10.31

The intent implementations can't be unit-tested through the App Intents framework. Manual verification on Debug build is the only confidence we get pre-ship.

- [ ] **Step 1: Build + launch a Debug copy**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
DERIVED=$(xcodebuild -project yawac.xcodeproj -showBuildSettings -scheme yawac 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)
open "$DERIVED/yawac.app"
```

Wait ~10s for the bridge to authenticate. Verify the app is connected to your account.

- [ ] **Step 2: Open Shortcuts.app, search for "yawac"**

Expected: 4 actions appear (Send WhatsApp Message, Open WhatsApp Chat, Mark WhatsApp Chat as Read, Search WhatsApp Messages).

- [ ] **Step 3: Smoke-test each intent**

Create a temporary Shortcut for each:

| Intent | Input | Expect |
|---|---|---|
| Send | chat="<pick a real chat by name>", body="test from shortcuts" | Message arrives in the chat |
| Open Chat | chat="<chat name>" | yawac front, sidebar selection = that chat |
| Mark Read | chat="<any chat with unread>" | unread count → 0 |
| Search | query="test" | yawac front, search field populated, results filtered |

If any fail, debug via `grep -E '\[yawac/' /tmp/yawac.log | tail -20` and revisit the implementation.

- [ ] **Step 4: Stop the test build + clear Shortcuts cache**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
```

(macOS caches the AppShortcutsProvider registration; if Shortcuts.app doesn't refresh, log out + back in. Document for the user if needed but skip in the plan.)

- [ ] **Step 5: Pre-flight release**

```bash
cd /Users/vadikas/Work/yawac
git status
git pull --rebase origin main
```

- [ ] **Step 6: Bump version in `project.yml`**

```
CFBundleShortVersionString: "0.10.31"
CFBundleVersion: "114"
```

- [ ] **Step 7: Regenerate Xcode project**

```bash
xcodegen
```

- [ ] **Step 8: Flip ROADMAP bullet + add shipped entry**

In `docs/ROADMAP.md`:

Find the `☐ **Shortcuts / AppleScript integration**` bullet (around line 160) and replace with:
```markdown
- ✅ **Shortcuts / AppleScript integration** — App Intents path landed as F97 in v0.10.31. AppleScript sdef deferred.
```

Prepend under `# Shipped (✅)` before the existing F96 entry:

```markdown
- ✅ **F97 — App Intents for Send / Open Chat / Mark Read / Search** (v0.10.31) —
  Power-user automation surface that the official WhatsApp Mac
  client can't match. Four App Intents wired through a fresh
  `yawac/Intents/` folder:
  - **`SendWhatsAppMessage(chat, body)`** — resolves chat via the
    shared `ChatResolver` (phone digits or substring name match,
    `@s.whatsapp.net` + `@lid` fallback), invokes
    `WAClient.sendText`, returns `Sent message <ID>`.
  - **`OpenWhatsAppChat(chat)`** — resolves chat, drives the
    existing `SessionViewModel.openRootChat`, calls
    `WindowToggler.bringToFront()` to surface the window.
  - **`MarkWhatsAppChatRead(chat)`** — resolves chat, calls
    `ChatListViewModel.markRead`.
  - **`SearchWhatsAppMessages(query)`** — writes the query through
    transient `SessionViewModel.pendingShortcutQuery`; ContentView
    observer forwards into the live `ChatSearchViewModel`.
  - **Discoverability.** `YawacShortcutsProvider: AppShortcutsProvider`
    registers all four with phrases like "Send WhatsApp message via
    yawac" so Shortcuts.app, Spotlight, and Siri pick them up on
    first launch.
  - **Dependency wiring.** `AppDependencyManager.shared.add(dependency: session)`
    in `YawacApp.init()` so `@Dependency private var session: SessionViewModel`
    resolves inside `perform()`.
  - **Coverage.** `openAppWhenRun: true` — the live `WAClient` +
    SwiftData store are required, so headless invocation isn't
    supported.
  - **Resolver tests.** `yawacTests/ChatResolverTests.swift` — 8
    pure-function cases (empty / phone-net / phone-lid / phone
    normalize / exact name / substring case-insensitive / ambiguous
    / not-found).
  - **Spec / plan.** Design at `docs/superpowers/specs/2026-06-18
    -shortcuts-app-intents-design.md`; plan at
    `docs/superpowers/plans/2026-06-18-shortcuts-app-intents.md`.
  - **Skipped (deferred to future cycle).** AppleScript `.sdef` /
    `NSScriptCommand` path; send-with-attachment intent; reply-to-
    message intent; multi-account targeting.
```

- [ ] **Step 9: Commit + tag + push**

```bash
git add yawac/yawacApp.swift project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
release: 0.10.31 — F97 App Intents (Send / Open / MarkRead / Search)

Four native macOS App Intents wired through new yawac/Intents/
folder + shared ChatResolver (phone or contact-name match). Plus
YawacShortcutsProvider so Shortcuts.app / Spotlight / Siri pick
them up. AppDependencyManager injects SessionViewModel into intent
perform(). Power-user automation surface the official WhatsApp Mac
client can't match.
EOF
)"
git tag -a v0.10.31 -m "yawac 0.10.31 — F97 App Intents"
git push origin main
git push origin v0.10.31
```

- [ ] **Step 10: Verify release**

```bash
gh run watch   # release workflow; ignore CI flake
gh release view v0.10.31 --json tagName,isDraft,publishedAt,assets
```
Expected: `isDraft: false`, both `yawac-0.10.31.zip` + `appcast.xml` uploaded.

---

## Self-review

**1. Spec coverage:**

| Spec section | Task |
|---|---|
| Four intents (Send / OpenChat / MarkRead / Search) | Tasks 3-6 |
| Pure `ChatResolver` helper | Task 1 |
| Chat input = phone OR contact name | Task 1 (resolver) |
| `openAppWhenRun: true` | All 4 intents (Tasks 3-6) |
| `@Dependency` injection of SessionViewModel | All 4 intents + Task 7 (`AppDependencyManager`) |
| `YawacShortcutsProvider` | Task 7 |
| 7-8 unit tests on resolver | Task 1 (8 cases — bumped by one to cover phone normalization explicitly) |
| Manual smoke test | Task 8 |

**Deviation noted:** spec proposed `pendingShortcutSelectJID` AND `pendingShortcutQuery` — plan uses only `pendingShortcutQuery` since OpenChat / MarkRead intents call session methods directly via `MainActor.run` (per ponytail). Spec text updated only in the plan's deviation note; the spec file itself stays as-written for design-trail integrity.

**2. Placeholder scan:** No TBD / TODO / vague reqs. Every step has concrete code or commands.

**3. Type consistency:**
- `ChatResolveError` cases (`.notPaired` / `.notFound(input:)` / `.ambiguous(input:matches:)`) consistent across Tasks 1, 3, 4, 5
- `session.client` / `session.chatList?.chats` access pattern consistent across intents
- `WindowToggler.bringToFront()` referenced in Tasks 4 + 6 (existing function per yawacApp.swift:218)
- `SessionViewModel.openRootChat(_:)` referenced in Task 4 — verify signature in Task 4 Step 2 (the plan notes the verify step explicitly)
- `ChatListViewModel.markRead(_:)` referenced in Task 5 — signature confirmed at line 722 during plan prep
- `pendingShortcutQuery` field added in Task 2, consumed in Task 6 (intent set, ContentView reset)
