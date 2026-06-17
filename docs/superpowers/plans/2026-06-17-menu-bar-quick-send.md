# Menu-bar Quick-send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a yawac menu-bar status-item popover (left-click + ⌘⇧Y) that lets the user search a recent / all-chats list and send a text WhatsApp message without surfacing the main window.

**Architecture:** Four new SwiftUI / AppKit files (`GlobalHotkey`, `QuickSendChatPicker`, `QuickSendComposer`, `QuickSendPopover`) plus a focused change to the existing `MenuBarController` (F73). Send goes through the existing `WAClient.sendText` Go-bridge call; the popover stays out of `ConversationViewModel` — the open chat's CVM is untouched.

**Tech Stack:** Swift 5.10 / SwiftUI / AppKit (`NSPopover`, `NSStatusItem`) on macOS 14+. Carbon (`RegisterEventHotKey`) for the global hotkey. XCTest for unit tests. XcodeGen for project regeneration after new files land.

**Spec:** [`docs/superpowers/specs/2026-06-17-menu-bar-quick-send-design.md`](../specs/2026-06-17-menu-bar-quick-send-design.md)

---

## Pre-task: regenerate Xcode project after every new file

XcodeGen picks up new Swift files from the `sources: - path: yawac` glob, but `xcodebuild` only sees them after `xcodegen generate` writes a new `yawac.xcodeproj`. Every task below that creates a new file ends with this step. Don't skip it — symptom is "unknown symbol X" from `xcodebuild` while the file exists on disk.

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
```

---

## Task 1: `GlobalHotkey` Carbon wrapper

**Files:**
- Create: `yawac/UI/GlobalHotkey.swift`
- Test: `yawacTests/GlobalHotkeyTests.swift`

The wrapper owns one `EventHotKeyRef` + one `EventHandlerRef`, registers ⌘⇧Y at `register(callback:)`, fires the supplied closure on the main actor when the hotkey is pressed, and tears down both refs at `unregister()`.

Note: this task ships the wrapper API + unit tests for register/unregister symmetry and the `eventHotKeyExistsErr` swallow. Tests for the callback fire come in the manual-verification task — Carbon hotkey delivery requires a real event loop and is not feasible to fire from XCTest.

- [ ] **Step 1: Write the failing test**

```swift
// yawacTests/GlobalHotkeyTests.swift
import XCTest
@testable import yawac

final class GlobalHotkeyTests: XCTestCase {

    func testRegisterUnregisterIsIdempotent() throws {
        let hk = GlobalHotkey()
        XCTAssertFalse(hk.isRegistered)

        hk.register { /* no-op for this test */ }
        XCTAssertTrue(hk.isRegistered)

        // Second register call is a no-op, not a crash.
        hk.register { }
        XCTAssertTrue(hk.isRegistered)

        hk.unregister()
        XCTAssertFalse(hk.isRegistered)

        // Second unregister is also a no-op.
        hk.unregister()
        XCTAssertFalse(hk.isRegistered)
    }

    func testConflictDoesNotCrashOrThrow() {
        // Two GlobalHotkey instances racing for the same shortcut.
        // The second one's register call must swallow eventHotKeyExistsErr
        // and report isRegistered == false.
        let first = GlobalHotkey()
        let second = GlobalHotkey()
        first.register { }
        second.register { }
        XCTAssertTrue(first.isRegistered)
        XCTAssertFalse(second.isRegistered)
        first.unregister()
        second.unregister()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/GlobalHotkeyTests 2>&1 | tail -5
```

Expected: **FAIL** with "cannot find 'GlobalHotkey' in scope".

- [ ] **Step 3: Write `GlobalHotkey`**

```swift
// yawac/UI/GlobalHotkey.swift
import AppKit
import Carbon.HIToolbox

/// Carbon-based global hotkey registration. The Carbon path is the only
/// one that doesn't trip the macOS Accessibility-permission prompt; the
/// `NSEvent.addGlobalMonitorForEvents` alternative does.
///
/// Hardcoded to ⌘⇧Y for v1 to match the menu-bar Quick-send design.
/// A custom-bind UI is a follow-up; rebind by editing the constants
/// below in the meantime.
@MainActor
final class GlobalHotkey {

    private static let keyCode = UInt32(kVK_ANSI_Y)
    private static let modifiers = UInt32(cmdKey | shiftKey)
    private static let signature: OSType = 0x79617763 // 'yawc'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Boxed closure storage. Carbon's `InstallEventHandler` takes a
    /// raw C callback + `userData` pointer; we route through this box
    /// so the C handler can recover the Swift closure.
    private final class HandlerBox {
        let fire: () -> Void
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }
    private var box: HandlerBox?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(callback: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }

        let box = HandlerBox(callback)
        self.box = box
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_: EventHandlerCallRef?, evt: EventRef?, ud: UnsafeMutableRawPointer?) -> OSStatus in
                guard let evt, let ud else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    evt,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                guard status == noErr,
                      hkID.signature == GlobalHotkey.signature,
                      hkID.id == GlobalHotkey.hotKeyID else { return noErr }
                let box = Unmanaged<HandlerBox>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async { box.fire() }
                return noErr
            },
            1,
            &spec,
            boxPtr,
            &handlerRef)
        guard installStatus == noErr else {
            NSLog("[yawac/hotkey] InstallEventHandler failed status=%d", installStatus)
            self.box = nil
            return
        }

        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: GlobalHotkey.hotKeyID)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            GlobalHotkey.keyCode,
            GlobalHotkey.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref)
        if registerStatus == OSStatus(eventHotKeyExistsErr) {
            NSLog("[yawac/hotkey] ⌘⇧Y already registered by another app; skipping")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            self.box = nil
            return
        }
        guard registerStatus == noErr, let ref else {
            NSLog("[yawac/hotkey] RegisterEventHotKey failed status=%d", registerStatus)
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            self.box = nil
            return
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
        box = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
```

- [ ] **Step 4: Regenerate Xcode project**

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
```

Expected: `Created project at /Users/vadikas/Work/yawac/yawac.xcodeproj`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/GlobalHotkeyTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/UI/GlobalHotkey.swift yawacTests/GlobalHotkeyTests.swift yawac/Info.plist
git commit -m "feat(quick-send): Carbon GlobalHotkey wrapper for ⌘⇧Y"
```

---

## Task 2: `QuickSendChatPicker`

**Files:**
- Create: `yawac/UI/QuickSendChatPicker.swift`
- Test: `yawacTests/QuickSendChatPickerTests.swift`

Pure-data filter + ordering logic is split into a static `filter(chats:query:recentLimit:)` function so it can be unit-tested without mounting SwiftUI. The view layer is a thin `List` over the result.

- [ ] **Step 1: Write the failing test**

```swift
// yawacTests/QuickSendChatPickerTests.swift
import XCTest
@testable import yawac

final class QuickSendChatPickerTests: XCTestCase {

    private func chat(_ jid: String,
                      _ name: String,
                      _ ts: Int64) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "",
             lastTimestamp: ts, unread: 0)
    }

    func testRecentOrderingDESCByLastTimestamp() {
        let all = [
            chat("1@s.whatsapp.net", "Alice", 100),
            chat("2@s.whatsapp.net", "Bob", 300),
            chat("3@s.whatsapp.net", "Carol", 200),
        ]
        let out = QuickSendChatPicker.filter(chats: all, query: "", recentLimit: 5)
        XCTAssertEqual(out.map(\.name), ["Bob", "Carol", "Alice"])
    }

    func testRecentLimitCapsTheList() {
        let all = (0..<30).map { i in
            chat("\(i)@s.whatsapp.net", "Chat\(i)", Int64(i))
        }
        let out = QuickSendChatPicker.filter(chats: all, query: "", recentLimit: 15)
        XCTAssertEqual(out.count, 15)
        XCTAssertEqual(out.first?.name, "Chat29")  // newest
    }

    func testSearchIsCaseInsensitiveAndSubstring() {
        let all = [
            chat("1@s.whatsapp.net", "Alice", 100),
            chat("2@s.whatsapp.net", "Bob", 300),
            chat("3@s.whatsapp.net", "alicia keys", 200),
        ]
        let out = QuickSendChatPicker.filter(chats: all, query: "ali", recentLimit: 100)
        XCTAssertEqual(out.map(\.name), ["alicia keys", "Alice"])
    }

    func testSearchMatchesJIDDigitPrefix() {
        let all = [
            chat("3725060015@s.whatsapp.net", "", 100),
            chat("1234567890@s.whatsapp.net", "", 200),
        ]
        // Unsaved contact: filter by phone prefix.
        let out = QuickSendChatPicker.filter(chats: all, query: "37250", recentLimit: 100)
        XCTAssertEqual(out.map(\.jid), ["3725060015@s.whatsapp.net"])
    }

    func testQueryBypassesRecentLimit() {
        // 30 chats, all named "Match", recentLimit 5. With a matching
        // query the full set should be searchable, not just the top 5.
        let all = (0..<30).map { i in
            chat("\(i)@s.whatsapp.net", "Match\(i)", Int64(i))
        }
        let out = QuickSendChatPicker.filter(chats: all, query: "match",
                                             recentLimit: 5)
        XCTAssertEqual(out.count, 30)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/QuickSendChatPickerTests 2>&1 | tail -5
```

Expected: **FAIL** with "cannot find 'QuickSendChatPicker' in scope".

- [ ] **Step 3: Write `QuickSendChatPicker`**

```swift
// yawac/UI/QuickSendChatPicker.swift
import SwiftUI

/// Search field + filtered chat list for the menu-bar quick-send
/// popover. The filter / ordering logic is split into a static helper
/// so it can be unit-tested without mounting SwiftUI.
struct QuickSendChatPicker: View {

    /// Default cap on the "recents" view when the query is empty. The
    /// design doc settled on ~15 visible rows by default; the query
    /// path uncaps so search reaches every chat.
    static let defaultRecentLimit = 15

    @Binding var query: String
    @Binding var selectedChatJID: String?

    let chats: [Chat]
    let nameResolver: (Chat) -> String

    @State private var highlightIndex: Int = 0

    /// Pure, testable. Sorts recents DESC by `lastTimestamp`, then
    /// truncates to `recentLimit` when the query is empty; with a
    /// non-empty query it filters the entire list (case-insensitive
    /// substring on `name`, or digit-prefix on the JID's user
    /// component) and preserves the DESC ordering.
    static func filter(chats: [Chat], query: String,
                       recentLimit: Int) -> [Chat] {
        let sorted = chats.sorted { $0.lastTimestamp > $1.lastTimestamp }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(sorted.prefix(recentLimit))
        }
        let needle = trimmed.lowercased()
        let needleIsDigits = trimmed.allSatisfy(\.isNumber)
        return sorted.filter { chat in
            if chat.name.lowercased().contains(needle) { return true }
            if needleIsDigits,
               let user = chat.jid.split(separator: "@").first {
                return user.hasPrefix(trimmed)
            }
            return false
        }
    }

    private var visible: [Chat] {
        Self.filter(chats: chats, query: query,
                    recentLimit: Self.defaultRecentLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search a chat…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .onChange(of: query) { _, _ in highlightIndex = 0 }
                .onSubmit { selectHighlighted() }
                .onKeyPress(.upArrow) {
                    highlightIndex = max(0, highlightIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    let cap = max(0, visible.count - 1)
                    highlightIndex = min(cap, highlightIndex + 1)
                    return .handled
                }

            if visible.isEmpty {
                emptyState
            } else {
                List(Array(visible.enumerated()), id: \.element.id) { idx, chat in
                    row(for: chat,
                        displayName: nameResolver(chat),
                        highlighted: idx == highlightIndex)
                        .contentShape(.rect)
                        .onTapGesture {
                            highlightIndex = idx
                            selectedChatJID = chat.jid
                        }
                        .listRowInsets(.init(top: 4, leading: 10,
                                             bottom: 4, trailing: 10))
                }
                .listStyle(.plain)
                .frame(maxHeight: 260)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let isEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(spacing: 4) {
            Text(isEmpty ? "Search to find a chat" : "No chats match")
                .scaledUI(12)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    @ViewBuilder
    private func row(for chat: Chat,
                     displayName: String,
                     highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: chat.isGroup ? "person.3.fill" : "person.crop.circle.fill")
                .scaledIcon(14, weight: .regular)
                .foregroundStyle(Theme.textFaint)
            Text(displayName)
                .scaledUI(13)
                .lineLimit(1)
            Spacer()
            Text(chat.isGroup ? "Group" : "Direct")
                .scaledUI(10)
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(highlighted ? Theme.accent.opacity(0.18)
                                : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func selectHighlighted() {
        guard !visible.isEmpty else { return }
        let idx = max(0, min(highlightIndex, visible.count - 1))
        selectedChatJID = visible[idx].jid
    }
}
```

If `scaledUI` / `scaledIcon` / `Theme.textFaint` / `Theme.accent` aren't visible from this file, the build fails with "cannot find". They are defined in the existing `yawac/UI/` modifiers + `Theme.swift`; check those imports in nearby UI files (e.g. `ConversationView.swift`) and copy whatever import wiring they use.

- [ ] **Step 4: Regenerate Xcode project**

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/QuickSendChatPickerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/UI/QuickSendChatPicker.swift yawacTests/QuickSendChatPickerTests.swift yawac/Info.plist
git commit -m "feat(quick-send): chat picker view + filter logic"
```

---

## Task 3: `QuickSendComposer`

**Files:**
- Create: `yawac/UI/QuickSendComposer.swift`
- Test: `yawacTests/QuickSendComposerTests.swift`

The composer holds `draft`, `sending`, and `error` state and exposes the send-attempt logic as a pure async function (`attemptSend(...)`) that takes an injectable sender closure so XCTest can drive it without a real `WAClient`.

- [ ] **Step 1: Write the failing test**

```swift
// yawacTests/QuickSendComposerTests.swift
import XCTest
@testable import yawac

@MainActor
final class QuickSendComposerTests: XCTestCase {

    func testEmptyOrWhitespaceDraftIsBlocked() {
        XCTAssertFalse(QuickSendComposer.canSend(draft: ""))
        XCTAssertFalse(QuickSendComposer.canSend(draft: "  "))
        XCTAssertFalse(QuickSendComposer.canSend(draft: "\n\n  \n"))
        XCTAssertTrue(QuickSendComposer.canSend(draft: "hi"))
    }

    func testAttemptSendSuccessClosesPopover() async {
        var closed = false
        let result = await QuickSendComposer.attemptSend(
            chatJID: "1@s.whatsapp.net",
            draft: "hi",
            sender: { _, _ in /* no throw → success */ },
            onClose: { closed = true })
        if case .success = result {} else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(closed)
    }

    func testAttemptSendFailureKeepsPopoverOpenAndReturnsError() async {
        struct BogusError: Error, LocalizedError {
            var errorDescription: String? { "phone offline" }
        }
        var closed = false
        let result = await QuickSendComposer.attemptSend(
            chatJID: "1@s.whatsapp.net",
            draft: "hi",
            sender: { _, _ in throw BogusError() },
            onClose: { closed = true })
        XCTAssertFalse(closed)
        if case .failure(let msg) = result {
            XCTAssertEqual(msg, "phone offline")
        } else {
            XCTFail("expected failure, got \(result)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/QuickSendComposerTests 2>&1 | tail -5
```

Expected: **FAIL** with "cannot find 'QuickSendComposer' in scope".

- [ ] **Step 3: Write `QuickSendComposer`**

```swift
// yawac/UI/QuickSendComposer.swift
import SwiftUI

/// Composer for the menu-bar quick-send popover. The send logic is
/// factored into a static `attemptSend` so it can be unit-tested
/// without a real `WAClient` / Go bridge.
struct QuickSendComposer: View {

    let chatJID: String
    let displayName: String
    let send: @Sendable (String, String) async throws -> Void
    let onClose: () -> Void
    let onBack: () -> Void

    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    /// Pure: returns `true` iff the draft has at least one
    /// non-whitespace character.
    static func canSend(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum SendOutcome: Equatable {
        case success
        case failure(String)
    }

    /// Pure-async send driver. Calls `sender(chatJID, draft)`; on
    /// success invokes `onClose`. Returns the outcome so the test can
    /// assert on it without spinning the SwiftUI runtime.
    static func attemptSend(
        chatJID: String,
        draft: String,
        sender: @Sendable (String, String) async throws -> Void,
        onClose: () -> Void
    ) async -> SendOutcome {
        guard canSend(draft: draft) else { return .failure("empty draft") }
        do {
            try await sender(chatJID, draft)
            onClose()
            return .success
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return .failure(msg)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("Message \(displayName)…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { trigger() }
                .disabled(sending)
                .padding(.horizontal, 10)

            if let error {
                Text(error)
                    .scaledUI(11)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
            }

            HStack {
                Spacer()
                Button {
                    trigger()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .scaledIcon(11, weight: .semibold)
                        Text("Send")
                            .scaledUI(12)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!Self.canSend(draft: draft) || sending)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .scaledIcon(12, weight: .semibold)
            }
            .buttonStyle(.plain)
            Text(displayName)
                .scaledUI(12, weight: .semibold)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func trigger() {
        guard Self.canSend(draft: draft), !sending else { return }
        sending = true
        error = nil
        let snapshot = draft
        Task {
            let outcome = await Self.attemptSend(
                chatJID: chatJID,
                draft: snapshot,
                sender: { jid, body in try await send(jid, body) },
                onClose: onClose)
            switch outcome {
            case .success:
                draft = ""
                sending = false
            case .failure(let msg):
                sending = false
                error = msg
                // Auto-clear the error banner after 4s.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if self.error == msg { self.error = nil }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Regenerate Xcode project**

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/vadikas/Work/yawac
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' -only-testing:yawacTests/QuickSendComposerTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/UI/QuickSendComposer.swift yawacTests/QuickSendComposerTests.swift yawac/Info.plist
git commit -m "feat(quick-send): composer view + send driver"
```

---

## Task 4: `QuickSendPopover` root view

**Files:**
- Create: `yawac/UI/QuickSendPopover.swift`

Glues the picker and the composer behind a single `selectedChatJID` flag. No unit test — it's a layout shell; behavior is covered by the picker / composer tests + the manual verification at the end.

- [ ] **Step 1: Write `QuickSendPopover`**

```swift
// yawac/UI/QuickSendPopover.swift
import SwiftUI

/// Root content view for the menu-bar quick-send `NSPopover`. Switches
/// between the chat picker and the composer based on
/// `selectedChatJID`. Width is fixed to 320pt; height adapts to
/// content via SwiftUI's natural sizing (the popover frames it).
struct QuickSendPopover: View {

    let session: SessionViewModel
    let client: WAClient
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedChatJID: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.client == nil {
                placeholder("No account paired")
            } else if let jid = selectedChatJID {
                composer(for: jid)
            } else {
                picker
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private var picker: some View {
        QuickSendChatPicker(
            query: $query,
            selectedChatJID: $selectedChatJID,
            chats: chats,
            nameResolver: { chat in
                let resolved = session.displayName(for: chat.jid)
                if !resolved.isEmpty { return resolved }
                return chat.name.isEmpty ? chat.jid : chat.name
            })
    }

    @ViewBuilder
    private func composer(for jid: String) -> some View {
        let resolved = session.displayName(for: jid)
        let displayName = resolved.isEmpty
            ? (chats.first(where: { $0.jid == jid })?.name ?? jid)
            : resolved
        QuickSendComposer(
            chatJID: jid,
            displayName: displayName,
            send: { [client] chatJID, body in
                _ = try await Task.detached(priority: .userInitiated) {
                    try client.sendText(chatJID, body)
                }.value
            },
            onClose: onClose,
            onBack: { selectedChatJID = nil })
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 4) {
            Text(text).scaledUI(12).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var chats: [Chat] {
        session.chatList?.chats ?? []
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/UI/QuickSendPopover.swift yawac/Info.plist
git commit -m "feat(quick-send): popover root view glue"
```

---

## Task 5: `MenuBarController` integration

**Files:**
- Modify: `yawac/UI/MenuBarController.swift`

Adds an `NSPopover` and a `GlobalHotkey`. Left-click now toggles the popover instead of bringing the main window forward. The right-click context menu gains a "Show Main Window" entry so the old left-click affordance is still reachable. The popover + hotkey install/uninstall together with the status item via `install()` / `tearDown()`, so `yawac.menuBar.show` (F73) gates everything as one bundle.

- [ ] **Step 1: Modify `MenuBarController`**

Replace the entire `private func install()`, `private func tearDown()`, `@objc private func handleClick(_:)`, and `private func buildMenu()` blocks (lines roughly 42-138 in the current file — verify with `grep -n` before editing) so the new wiring lands together:

```swift
// yawac/UI/MenuBarController.swift — additions / changes

import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private weak var session: SessionViewModel?
    private var observationTask: Task<Void, Never>?

    // F87: popover + global hotkey lifecycle.
    private var popover: NSPopover?
    private let hotkey = GlobalHotkey()

    override private init() { super.init() }

    func bind(session: SessionViewModel) {
        self.session = session
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            tearDown()
        }
    }

    private func install() {
        guard self.item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        refreshIcon()
        startObservingUnread()

        // F87: register the global ⌘⇧Y hotkey alongside the status
        // item. The lifecycle is bundled — disabling the menu bar
        // setting tears both down.
        hotkey.register { [weak self] in
            Task { @MainActor [weak self] in
                self?.togglePopover()
            }
        }
    }

    private func tearDown() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        popover = nil
        hotkey.unregister()

        guard let item else { return }
        observationTask?.cancel()
        observationTask = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func startObservingUnread() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            self?.armUnreadObserver()
        }
    }

    @MainActor
    private func armUnreadObserver() {
        withObservationTracking {
            _ = self.session?.totalUnread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshIcon()
                self?.armUnreadObserver()
            }
        }
    }

    private func refreshIcon() {
        guard let button = item?.button else { return }
        let unread = session?.totalUnread ?? 0
        let name = unread > 0 ? "MenuBarActive" : "MenuBarIdle"
        let img = NSImage(named: name)
        img?.isTemplate = (unread == 0)
        button.image = img
    }

    @objc private func handleClick(_ sender: Any?) {
        let isRightClick = (NSApp.currentEvent?.type == .rightMouseUp)
            || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            popContextMenu()
        } else {
            // F87: left-click now toggles the quick-send popover
            // instead of bringing the main window forward. "Show Main
            // Window" lives in the right-click context menu.
            togglePopover()
        }
    }

    /// F87: public entry point for both the status-item left-click and
    /// the Carbon ⌘⇧Y hotkey callback. Idempotent — clicking while
    /// the popover is already open closes it.
    func togglePopover() {
        guard let item, let button = item.button else { return }
        guard let session else { return }
        guard let client = session.client else {
            // No client = no point opening the popover.
            return
        }
        let popover = ensurePopover(session: session, client: client)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate yawac just enough to host the popover focus,
            // without bringing the main window forward — `.accessory`
            // is the policy when `yawac.dock.keep` is false, so
            // forcing activation is necessary for keyboard focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds,
                         of: button, preferredEdge: .minY)
        }
    }

    private func ensurePopover(session: SessionViewModel,
                               client: WAClient) -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let root = QuickSendPopover(session: session,
                                    client: client,
                                    onClose: { [weak self] in
            self?.popover?.performClose(nil)
        })
        popover.contentViewController = NSHostingController(rootView: root)
        self.popover = popover
        return popover
    }

    private func popContextMenu() {
        guard let item else { return }
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        DispatchQueue.main.async { [weak item] in item?.menu = nil }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let unread = session?.totalUnread, unread > 0 {
            let header = NSMenuItem(title: "\(unread) unread",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        // F87: "Show Main Window" entered the context menu when
        // left-click moved to the popover.
        let show = NSMenuItem(title: "Show Main Window",
                              action: #selector(menuShowWindow),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let toggle = NSMenuItem(title: "Show / Hide Window",
                                action: #selector(menuToggleWindow),
                                keyEquivalent: "h")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit yawac",
                              action: #selector(menuQuit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func menuShowWindow() { WindowToggler.bringToFront() }
    @objc private func menuToggleWindow() { WindowToggler.toggleMain() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}
```

- [ ] **Step 2: Build to verify the wiring**

```bash
cd /Users/vadikas/Work/yawac
xcodegen generate
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
xcodebuild -scheme yawac -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/vadikas/Work/yawac
xcodebuild test -scheme yawac -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` (no regressions in the previously-green test suite).

- [ ] **Step 4: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/UI/MenuBarController.swift
git commit -m "feat(quick-send): MenuBarController popover + hotkey lifecycle"
```

---

## Task 6: End-to-end manual verification

**Files:** none (verification only)

Carbon hotkey delivery + `NSPopover` presentation need a real event loop, so this is a manual walk-through against the running Debug binary. If any step fails, treat as a bug, fix, recommit, and re-run.

- [ ] **Step 1: Launch the freshly-built debug binary**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
open /Users/vadikas/Library/Developer/Xcode/DerivedData/yawac-bplgxfeuyvjpvlavuewevrxmorvr/Build/Products/Debug/yawac.app
```

(See `[[yawac-log-path]]` in auto-memory — DerivedData is the canonical build location; the legacy `build/dd` path holds a stale binary from before today's session.)

- [ ] **Step 2: Enable the menu bar in Settings**

In yawac: `⌘,` to open Settings → General → toggle "Show in menu bar" ON. Verify the yawac icon appears in the macOS menu bar.

- [ ] **Step 3: Left-click → popover opens**

Click the menu-bar icon with the left button. Expected: popover slides down from the icon showing the search field + ~15 recent chats. Main window does NOT come forward.

- [ ] **Step 4: Search filters the list**

Type the first 2-3 letters of a known contact's name. Expected: list filters in real time. Down-arrow + Enter selects.

- [ ] **Step 5: Composer focuses + send works**

After Enter, the composer view appears with the chosen contact's name in the header and the text field auto-focused. Type a short message ("yawac quick-send test"). Press `⌘⏎`. Expected: popover closes; the message arrives on the phone within seconds (verify in WhatsApp on phone).

- [ ] **Step 6: ⌘⇧Y opens the popover from another app**

Switch to Safari or any non-yawac app (`⌘⇥`). Press ⌘⇧Y. Expected: yawac popover opens at the menu-bar icon. yawac is now front-of-screen but the main window stays as it was (closed or background).

- [ ] **Step 7: Esc closes the popover from the picker**

Open popover via ⌘⇧Y, press Esc with no chat selected. Expected: popover dismisses. (If Esc doesn't fire — SwiftUI may need `.onExitCommand` on the picker; treat as a follow-up fix.)

- [ ] **Step 8: Back button returns to picker**

Open popover → select a chat → press the `←` button next to the chat name. Expected: composer view replaced by the picker with the prior search query cleared.

- [ ] **Step 9: Send-failure error banner**

Temporarily disconnect from Wi-Fi. ⌘⇧Y, pick a chat, send. Expected: error banner appears under the text field for ~4 seconds; popover stays open. Reconnect Wi-Fi.

- [ ] **Step 10: Status-item disable kills the hotkey**

In Settings, toggle "Show in menu bar" OFF. Press ⌘⇧Y. Expected: nothing happens (no popover; the hotkey is unregistered alongside the status item).

- [ ] **Step 11: If any manual step failed, capture the failure**

```bash
strings /tmp/yawac.log | grep "yawac/hotkey" | tail -10
```

Expected: no error lines about RegisterEventHotKey / InstallEventHandler. If the conflict log fires, identify the competing app (Spectacle / Magnet / Raycast all bind ⌘⇧+letters), pick a different combo, update `GlobalHotkey.keyCode` / `modifiers`, redo Task 1, then re-run this task.

---

## Self-review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Picker = recent + search | Task 2 |
| Send-and-close | Task 3 (`onClose` on success) + Task 5 (`onClose` closure) |
| Text only (no attachments) | Task 3 (composer has no paperclip / drag-drop) |
| Carbon hotkey | Task 1 |
| Hardcoded ⌘⇧Y | Task 1 (`keyCode = kVK_ANSI_Y`, `modifiers = cmdKey | shiftKey`) |
| NSPopover transient + status-item anchor | Task 5 (`behavior = .transient`, `show(relativeTo:button.bounds, of:button)`) |
| `yawac.menuBar.show` gates the bundle | Task 5 (`install()` / `tearDown()` covers status item + popover + hotkey together) |
| Mirror F51 send pattern w/o bubble append | Task 3 (`attemptSend` → `client.sendText`; no CVM touched) |
| Error banner 4s auto-clear | Task 3 (`Task.sleep(for: .seconds(4))` self-clear) |
| Empty / no-paired-account placeholder | Task 4 (`if session.client == nil { placeholder(...) }`) and Task 2 (`emptyState`) |
| Manual repro list | Task 6 |

**Placeholder scan:** no "TBD", no "implement later", no "add appropriate error handling" — every step has the exact code or command needed.

**Type consistency:** `chatJID: String` flows from `Chat.jid` → `selectedChatJID` → `QuickSendComposer.chatJID` → `client.sendText(chatJID, body)`. `displayName` flows from `nameResolver` (Task 2) → `QuickSendPopover.composer(for:)` (Task 4) → `QuickSendComposer.displayName` (Task 3). `send: @Sendable (String, String) async throws -> Void` signature matches between `QuickSendComposer.send` and the closure built in `QuickSendPopover.composer(for:)`. `attemptSend(...)` returns `SendOutcome` consistently in test + production paths. `GlobalHotkey.register(callback:)` matches the call in Task 5.

No gaps surfaced; ready.
