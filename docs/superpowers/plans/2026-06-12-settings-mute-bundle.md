# v0.10.6 Settings + Mute Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four Settings AppStorage wirings + per-chat mute customization (custom Until… date + Sound on/off toggle) in a single bundled release v0.10.6.

**Architecture:** Pure additive surface changes — one default-value Bool added to PersistedChat (lightweight SwiftData migration), one new bridge-free service (LaunchAtLoginService), one new singleton controller (MenuBarController), and one notification-content builder extracted as a pure function so it's unit-testable.

**Tech Stack:** SwiftUI macOS 14+, SwiftData, UNUserNotificationCenter, ServiceManagement (SMAppService), NSStatusItem, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-12-settings-mute-bundle-design.md`

---

## File Structure

**Create:**
- `yawac/UI/MenuBarController.swift` — NSStatusItem lifecycle, click → bring main window forward.
- `yawac/Services/LaunchAtLoginService.swift` — SMAppService register / unregister / status wrapper.
- `yawacTests/NotificationContentBuilderTests.swift` — unit tests for the gating matrix.
- `yawacTests/PersistedChatBellMigrationTests.swift` — confirms default-value lightweight migration leaves existing rows with `bellEnabled = true`.

**Modify:**
- `yawac/Models/PersistedMessage.swift` — add `bellEnabled` property to `PersistedChat`.
- `yawac/Models/Chat.swift` — mirror `bellEnabled` on the value struct.
- `yawac/Services/NotificationService.swift` — extract pure `buildNotificationContent(...)`; thread per-chat bell + global toggles into it.
- `yawac/ViewModels/ChatListViewModel.swift` — hydrate `bellEnabled` from PersistedChat → Chat (loadChats, applyChatRowUpdate as applicable).
- `yawac/Views/ChatInfoView.swift` — add Sound row + Until… picker case.
- `yawac/Views/Settings/Panels/GeneralPanel.swift` — `.onChange` handlers wiring each toggle to its service / NSApp call.
- `yawac/yawacApp.swift` — mount MenuBarController + set initial dock policy from AppStorage.
- `project.yml` — version bump 0.10.5 → 0.10.6, build 88 → 89.
- `docs/ROADMAP.md` — F73-F75 entry block.

**No new dependencies.** `SMAppService` ships in `ServiceManagement` (system framework, macOS 13+).

---

## Task 1: Add `bellEnabled` to PersistedChat + Chat value type

**Files:**
- Modify: `yawac/Models/PersistedMessage.swift` (around the `@Model final class PersistedChat` declaration — find via grep, currently near line 240).
- Modify: `yawac/Models/Chat.swift` (search for `struct Chat`).

- [ ] **Step 1: Add field to PersistedChat**

Open `PersistedMessage.swift`, find the `PersistedChat` class (around line 233). Add the property right after `var draft: String? = nil` (before the `init`):

```swift
/// F74: per-chat notification-sound suppression. Default `true` so
/// existing rows lightweight-migrate transparently. Independent of
/// `mutedUntil` — bell off keeps the banner but silences the sound;
/// mute suppresses the banner entirely. Not added to `init(...)`
/// because the default-value path keeps every existing call site
/// compiling; upsertPersisted assigns it explicitly.
var bellEnabled: Bool = true
```

NO `@Attribute(.indexed)`, NO `#Index<T>` — adding a plain default-value Bool is the SwiftData lightweight-migration safe path (per F45 lessons; #Index was the destructive change). The existing custom `init(jid:name:...)` is NOT modified — `bellEnabled` defaults via the property initializer so freshly-created `PersistedChat` rows start at `true` without touching init param order.

- [ ] **Step 2: Mirror field on Chat value struct**

In `yawac/Models/Chat.swift`, add to the `Chat` struct's stored properties (place near `unread`):

```swift
var bellEnabled: Bool = true
```

If the struct has a memberwise init or `init(jid:name:...)`, add `bellEnabled` with default `true` at the END of the param list so existing call sites compile unchanged.

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug -derivedDataPath build/dd -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`. No call-site breakage because `bellEnabled` defaults to `true`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/PersistedMessage.swift yawac/Models/Chat.swift
git commit -m "F74: add PersistedChat.bellEnabled (default true)"
```

---

## Task 2: Hydrate bellEnabled into Chat in ChatListViewModel

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift` — the `loadChats` chat-build loop (around line 329-360 where `Chat(jid:name:...)` is constructed from a PersistedChat row) AND `applyChatRowUpdate` if it constructs Chats (currently it mutates existing chats; verify by reading).

- [ ] **Step 1: Pass bellEnabled through Chat construction**

In `ChatListViewModel.swift` around line 342-356 the static bootstrap builds a `Chat(...)` from a `PersistedChat`. There's no positional init for `Chat` — Swift synthesizes one. Because `Chat.bellEnabled` defaults to `true` (Task 1 step 2), existing call sites stay valid; only the bootstrap that knows about the persisted value needs to pass it. Search for the `return Chat(\n    jid: row.jid` block; after `lastTimestamp: Int64(ts.isFinite ? ts : 0),` (or wherever fits in the arg list) add:

```swift
                    bellEnabled: row.bellEnabled,
```

The synthesized init accepts trailing-default args in any order via labeled calls; place it just before `isCommunityParent:` to keep diff small.

- [ ] **Step 2: Persist mutations back through upsertPersisted**

`upsertPersisted` lives at line 1019 in `ChatListViewModel.swift`. It has TWO paths — mutate-existing and insert-new. Add `bellEnabled` to BOTH.

Mutate-existing branch (around line 1024-1035): after `existing.mutedUntil = c.mutedUntil`, add:

```swift
            existing.bellEnabled = c.bellEnabled
```

Insert-new branch (around line 1036-1050): keep the existing `PersistedChat(...)` init call unchanged (init signature not modified per Task 1 note), then immediately after the init line but BEFORE `context.insert(row)`, add:

```swift
            row.bellEnabled = c.bellEnabled
```

So the new-row branch becomes:

```swift
        } else {
            let row = PersistedChat(
                jid: c.jid,
                name: c.name,
                lastMessageText: preview,
                lastTimestamp: Date(timeIntervalSince1970: TimeInterval(c.lastTimestamp)),
                unread: c.unread,
                communityParentJID: c.communityParentJID,
                isCommunityParent: c.isCommunityParent,
                isDefaultSubGroup: c.isDefaultSubGroup,
                pinnedAt: c.pinnedAt,
                archivedAt: c.archivedAt,
                mutedUntil: c.mutedUntil,
                groupDescription: c.groupDescription)
            row.bellEnabled = c.bellEnabled
            context.insert(row)
        }
```

- [ ] **Step 3: Build**

Run: `xcodebuild ... build 2>&1 | tail -5`. Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift
git commit -m "F74: hydrate bellEnabled through Chat round-trip"
```

---

## Task 3: Extract pure `buildNotificationContent` from NotificationService

**Files:**
- Modify: `yawac/Services/NotificationService.swift` — refactor `notify(...)` body.

- [ ] **Step 1: Define the input prefs struct**

At top of `NotificationService.swift` (above `enum NotificationService`):

```swift
/// F73-F74: pure-function inputs for `buildNotificationContent`.
/// All side-channel state (per-chat bell, global toggles) is passed
/// in so the builder is testable without `UserDefaults` mocking.
struct NotificationPrefs {
    let enabled: Bool
    let preview: Bool
    let soundName: String  // "Default" / "Pop" / "Glass" / "None"
    let bellEnabled: Bool
}
```

- [ ] **Step 2: Add the pure builder**

Add static function on `NotificationService`:

```swift
/// Returns `nil` when the notification is fully suppressed (master
/// notifications-enabled toggle is off OR — in a future per-chat
/// banner-override world — banner is off). Caller short-circuits.
static func buildNotificationContent(
    title: String,
    subtitle: String?,
    body: String,
    chatJID: String,
    prefs: NotificationPrefs
) -> UNMutableNotificationContent? {
    guard prefs.enabled else { return nil }
    let content = UNMutableNotificationContent()
    content.title = title
    if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
    content.body = prefs.preview ? body : ""
    content.userInfo = ["chatJID": chatJID]
    content.categoryIdentifier = Self.messageCategoryID
    if prefs.bellEnabled {
        switch prefs.soundName {
        case "Default": content.sound = .default
        case "Pop":     content.sound = UNNotificationSound(named: UNNotificationSoundName("Pop.aiff"))
        case "Glass":   content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        case "None":    content.sound = nil
        default:        content.sound = .default
        }
    } else {
        content.sound = nil
    }
    return content
}
```

- [ ] **Step 3: Rewire `notify(...)` to call the builder**

Replace the body that constructs `UNMutableNotificationContent` with a call to `buildNotificationContent`. Pull the per-chat `bellEnabled` from the chat list (caller passes it OR look up via a new parameter on `notify`). Keep `notify`'s existing call sites compiling by giving `notify` a default `bellEnabled: Bool = true`.

```swift
static func notify(
    title: String,
    body: String,
    chatJID: String,
    subtitle: String? = nil,
    resolveMentions: ((String) -> String)? = nil,
    bellEnabled: Bool = true
) {
    let resolvedBody: String = resolveMentions.map { resolver in
        resolveMentionsText(body, resolver: resolver)
    } ?? body
    let prefs = NotificationPrefs(
        enabled: UserDefaults.standard.object(forKey: "yawac.notifications.enabled") as? Bool ?? true,
        preview: UserDefaults.standard.object(forKey: "yawac.notifications.preview") as? Bool ?? true,
        soundName: UserDefaults.standard.string(forKey: "yawac.notifications.sound") ?? "Default",
        bellEnabled: bellEnabled
    )
    guard let content = buildNotificationContent(
        title: title, subtitle: subtitle, body: resolvedBody,
        chatJID: chatJID, prefs: prefs
    ) else { return }
    let req = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
    if !unGranted {
        osascriptNotify(title: title, subtitle: subtitle, body: resolvedBody)
    }
}
```

(`AppStorage`'s default-true behavior only applies inside SwiftUI; for `UserDefaults.standard` reads outside SwiftUI we need the `object(forKey:) as? Bool ?? true` pattern to honor user intent OR default-on when never set.)

- [ ] **Step 4: Find existing notify call sites and pass bellEnabled**

Run: `grep -rnE "NotificationService\.notify\(" yawac --include="*.swift"`

For each caller (likely `ChatListViewModel.ingest` or wherever incoming-message banners fire), add a per-chat lookup:

```swift
let bell = chats.first(where: { $0.jid == chatJID })?.bellEnabled ?? true
NotificationService.notify(..., bellEnabled: bell)
```

- [ ] **Step 5: Build**

Run: `xcodebuild ... build 2>&1 | tail -5`. Fix compile errors. Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add yawac/Services/NotificationService.swift yawac/ViewModels/ChatListViewModel.swift
git commit -m "F73-F74: extract buildNotificationContent + per-chat bell"
```

---

## Task 4: Unit-test the notification gating matrix

**Files:**
- Create: `yawacTests/NotificationContentBuilderTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
import XCTest
import UserNotifications
@testable import yawac

final class NotificationContentBuilderTests: XCTestCase {
    private func prefs(
        enabled: Bool = true,
        preview: Bool = true,
        soundName: String = "Default",
        bellEnabled: Bool = true
    ) -> NotificationPrefs {
        NotificationPrefs(enabled: enabled, preview: preview,
                          soundName: soundName, bellEnabled: bellEnabled)
    }

    func testReturnsNilWhenMasterDisabled() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(enabled: false))
        XCTAssertNil(c)
    }

    func testBlanksBodyWhenPreviewOff() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "secret", chatJID: "x",
            prefs: prefs(preview: false))
        XCTAssertEqual(c?.body, "")
        XCTAssertEqual(c?.title, "T")
    }

    func testKeepsBodyWhenPreviewOn() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "hello", chatJID: "x",
            prefs: prefs(preview: true))
        XCTAssertEqual(c?.body, "hello")
    }

    func testSoundNoneStripsSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "None"))
        XCTAssertNil(c?.sound)
    }

    func testBellOffStripsSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "Default", bellEnabled: false))
        XCTAssertNil(c?.sound)
    }

    func testBellOnHonorsGlobalSound() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs(soundName: "Default", bellEnabled: true))
        XCTAssertNotNil(c?.sound)
    }

    func testUserInfoCarriesChatJID() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "abc@x",
            prefs: prefs())
        XCTAssertEqual(c?.userInfo["chatJID"] as? String, "abc@x")
    }

    func testCategoryIdentifierWired() {
        let c = NotificationService.buildNotificationContent(
            title: "T", subtitle: nil, body: "B", chatJID: "x",
            prefs: prefs())
        XCTAssertEqual(c?.categoryIdentifier, NotificationService.messageCategoryID)
    }
}
```

- [ ] **Step 2: Run tests, expect PASS**

```
xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' test \
    -only-testing:yawacTests/NotificationContentBuilderTests 2>&1 | tail -20
```

Expected: 8 tests, all pass. (Task 3 already implemented the builder; tests are coverage.)

- [ ] **Step 3: Commit**

```bash
git add yawacTests/NotificationContentBuilderTests.swift
git commit -m "F73-F74: unit tests for notification content builder"
```

---

## Task 5: Wire dock visibility (yawac.dock.keep)

**Files:**
- Modify: `yawac/yawacApp.swift` (apply initial policy on launch).
- Modify: `yawac/Views/Settings/Panels/GeneralPanel.swift` (`.onChange` handler).

- [ ] **Step 1: Apply initial policy at launch**

In `yawacApp.swift` `init()` (after existing setup), add:

```swift
// F73: respect Settings → General → "Keep in dock" at launch.
// Default true (regular app); when off, run as accessory (no dock).
let keep = UserDefaults.standard.object(forKey: "yawac.dock.keep") as? Bool ?? true
NSApp.setActivationPolicy(keep ? .regular : .accessory)
```

NB: at `init()` time `NSApp` may exist but the policy can be set safely.

- [ ] **Step 2: Wire .onChange in GeneralPanel**

In `GeneralPanel.swift`, find the `SettingsSwitch(isOn: $keepInDock)` row. Wrap or attach:

```swift
SettingsRow(label: "Keep in dock") {
    SettingsSwitch(isOn: $keepInDock)
}
.onChange(of: keepInDock) { _, newValue in
    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
    if newValue {
        // Bring main window back when re-enabling dock from a hidden state.
        WindowToggler.bringToFront()
    }
}
```

- [ ] **Step 3: Build + smoke-test manually**

```
xcodebuild ... build 2>&1 | tail -3
pkill -f yawac.app/Contents/MacOS/yawac; sleep 1
open build/dd/Build/Products/Debug/yawac.app
```

Toggle off → dock icon disappears. Toggle on → reappears + window comes forward.

- [ ] **Step 4: Commit**

```bash
git add yawac/yawacApp.swift yawac/Views/Settings/Panels/GeneralPanel.swift
git commit -m "F73: wire yawac.dock.keep to NSApp.activationPolicy"
```

---

## Task 6: LaunchAtLoginService

**Files:**
- Create: `yawac/Services/LaunchAtLoginService.swift`.

- [ ] **Step 1: Write service**

```swift
import Foundation
import ServiceManagement

/// F73: SMAppService wrapper for the Settings → General → "Launch at
/// login" toggle. Reads/writes the system's login-item registration
/// for yawac's main app bundle. Sandboxed-permission failures are
/// logged but don't crash; the toggle's AppStorage value still
/// reflects user intent.
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Apply `enabled` to the system. Returns the resulting status so
    /// the caller can decide whether to surface a warning.
    @discardableResult
    static func apply(_ enabled: Bool) -> SMAppService.Status {
        let svc = SMAppService.mainApp
        do {
            if enabled {
                try svc.register()
            } else {
                try svc.unregister()
            }
        } catch {
            NSLog("[yawac/launchAtLogin] %@ failed: %@",
                  enabled ? "register" : "unregister",
                  String(describing: error))
        }
        return svc.status
    }
}
```

- [ ] **Step 2: Wire .onChange in GeneralPanel**

In `GeneralPanel.swift`, attach to the launchAtLogin row:

```swift
.onChange(of: launchAtLogin) { _, newValue in
    _ = LaunchAtLoginService.apply(newValue)
}
```

- [ ] **Step 3: Sync AppStorage from actual system state on appear**

Add `.onAppear` to the GeneralPanel body:

```swift
.onAppear {
    // System truth wins on first display so a manual System Settings
    // removal doesn't leave the toggle stuck on.
    launchAtLogin = LaunchAtLoginService.isEnabled
}
```

- [ ] **Step 4: Build + smoke**

```
xcodebuild ... build
pkill -f yawac.app/Contents/MacOS/yawac; sleep 1
open build/dd/Build/Products/Debug/yawac.app
```

Toggle on → System Settings → General → Login Items should list yawac. Toggle off → it disappears.

- [ ] **Step 5: Commit**

```bash
git add yawac/Services/LaunchAtLoginService.swift yawac/Views/Settings/Panels/GeneralPanel.swift
git commit -m "F73: wire yawac.launchAtLogin via SMAppService"
```

---

## Task 7: MenuBarController (placeholder NSStatusItem)

**Files:**
- Create: `yawac/UI/MenuBarController.swift`.
- Modify: `yawac/yawacApp.swift` (mount controller).
- Modify: `yawac/Views/Settings/Panels/GeneralPanel.swift` (onChange).

- [ ] **Step 1: Write controller**

```swift
import AppKit

/// F73: owns the optional menu-bar `NSStatusItem`. Created on
/// demand when Settings → General → "Show in menu bar" is true;
/// torn down when toggled off. Click action brings the main window
/// to front — placeholder for the future Menu-bar Quick-Send popover.
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            tearDown()
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "message.fill",
                             accessibilityDescription: "yawac") {
            item.button?.image = img
        }
        item.button?.action = #selector(handleClick)
        item.button?.target = self
        statusItem = item
    }

    private func tearDown() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    @objc private func handleClick() {
        WindowToggler.bringToFront()
    }
}
```

- [ ] **Step 2: Mount at launch**

In `yawacApp.swift` `init()`:

```swift
// F73: initial menu-bar visibility from Settings.
let menuBar = UserDefaults.standard.object(forKey: "yawac.menuBar.show") as? Bool ?? false
MenuBarController.shared.setEnabled(menuBar)
```

- [ ] **Step 3: Wire .onChange**

In `GeneralPanel.swift`:

```swift
.onChange(of: showInMenuBar) { _, newValue in
    MenuBarController.shared.setEnabled(newValue)
}
```

- [ ] **Step 4: Build + smoke**

Toggle on → message icon appears in menu bar top-right. Click → brings yawac to front. Toggle off → icon disappears.

- [ ] **Step 5: Commit**

```bash
git add yawac/UI/MenuBarController.swift yawac/yawacApp.swift yawac/Views/Settings/Panels/GeneralPanel.swift
git commit -m "F73: MenuBarController + yawac.menuBar.show wiring"
```

---

## Task 8: ChatInfoView — Sound row

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift` — find the notifications section (search for the existing Mute picker / row).

- [ ] **Step 1: Add Sound row above or below the Mute row**

Locate the existing Mute row (search for `Mute` label or `mutedUntil` reference). Add adjacent:

```swift
// F74: per-chat sound toggle. Bell off = silent banner; mute still
// suppresses the banner entirely. Backed by PersistedChat.bellEnabled.
SettingsRow(label: "Sound") {
    SettingsSwitch(isOn: Binding(
        get: { chat.bellEnabled },
        set: { newValue in
            vm.setBellEnabled(chatJID: chat.jid, enabled: newValue)
        }
    ))
}
```

- [ ] **Step 2: Add setBellEnabled to ChatListViewModel**

In `yawac/ViewModels/ChatListViewModel.swift` (add near `setMute` / `setPinned` helpers — search for one of them):

```swift
/// F74: flip the per-chat bell. Local-only state — phone does not
/// see this preference.
func setBellEnabled(chatJID: String, enabled: Bool) {
    guard let idx = chats.firstIndex(where: { $0.jid == chatJID }) else { return }
    chats[idx].bellEnabled = enabled
    upsertPersisted(chats[idx])
}
```

- [ ] **Step 3: Build + smoke**

Open a chat → info pane → toggle Sound off → send yourself a test message → banner appears silently. Toggle on → banner makes sound.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatInfoView.swift yawac/ViewModels/ChatListViewModel.swift
git commit -m "F74: per-chat Sound toggle UI + setBellEnabled"
```

---

## Task 9: ChatInfoView — Until… custom mute picker

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift` (mute picker).

- [ ] **Step 1: Add a Until… case to the mute Picker**

Find the existing mute picker (likely a `Menu` or `Picker` with 8 hours / 1 week / Always options). Extend with a fourth case:

```swift
Button("Until…") { showUntilPicker = true }
```

- [ ] **Step 2: Add state + popover**

In the view's `@State` block:

```swift
@State private var showUntilPicker: Bool = false
@State private var pickedUntil: Date = Date().addingTimeInterval(3600)
```

Attach popover (place it near the existing mute Menu):

```swift
.popover(isPresented: $showUntilPicker) {
    VStack(alignment: .leading, spacing: 12) {
        Text("Mute until").font(.headline)
        DatePicker("", selection: $pickedUntil,
                   in: Date.now...,
                   displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact)
            .labelsHidden()
        HStack {
            Spacer()
            Button("Cancel") { showUntilPicker = false }
            Button("Mute") {
                vm.muteChat(chat, until: pickedUntil)
                showUntilPicker = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }
    .padding(16)
    .frame(minWidth: 280)
}
```

VM API confirmed: `ChatListViewModel.muteChat(_ chat: Chat, until: Date?)` at line 1225. Same call pattern as the existing presets in `ChatListView.swift:580` (`vm.muteChat(chat, until: Date().addingTimeInterval(8 * 3600))`).

- [ ] **Step 3: Build + smoke**

Open a chat → info pane → Mute → Until… → pick 1 min ahead → Mute → wait 60s → bell ring confirms auto-unmute (or banner appears).

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "F74: Until… custom mute date picker"
```

---

## Task 10: Release bump + ROADMAP + tag + push

**Files:**
- Modify: `project.yml` (version 0.10.5 → 0.10.6, build 88 → 89).
- Modify: `docs/ROADMAP.md` (add F73-F75 entry at top of Shipped section).

- [ ] **Step 1: Bump version**

Edit `project.yml`:

```yaml
        CFBundleShortVersionString: "0.10.6"
        CFBundleVersion: "89"
```

- [ ] **Step 2: ROADMAP entry**

Find the top of `# Shipped (✅)` section. Insert before the latest entry:

```markdown
- ✅ **F73-F75 — Settings wiring + per-chat mute customization**
  (v0.10.6) — bundle.
  - **F73** — four Settings toggles now actually do something:
    `yawac.notifications.enabled` gates the banner post entry;
    `yawac.notifications.preview` blanks the body field but keeps
    the title; `yawac.notifications.sound` selects between Default
    / Pop / Glass / None via `UNNotificationSound(named:)`;
    `yawac.dock.keep` flips `NSApp.activationPolicy` between
    `.regular` and `.accessory`; `yawac.menuBar.show` creates /
    tears down an `NSStatusItem` (click brings yawac front —
    placeholder for the future Menu-bar Quick-Send popover);
    `yawac.launchAtLogin` register/unregister via `SMAppService
    .mainApp`. AppStorage values reflect user intent even if
    system register fails (sandboxed dev builds).
  - **F74** — per-chat mute customization. `PersistedChat`
    gained `bellEnabled: Bool = true` (lightweight migration —
    plain default-value Bool, no `#Index`). ChatInfoView gained
    a Sound toggle and a Mute → "Until…" `DatePicker` for
    arbitrary expiry. The existing 8h / 1w / Always presets
    stay. Bell-off renders banners silent; mute still suppresses
    banners entirely — the two are independent.
  - **F75** — `NotificationService.buildNotificationContent`
    extracted as a pure function taking `NotificationPrefs`. All
    side-channel state (per-chat bell + global toggles) flows in
    as parameters so the gating matrix is unit-testable without
    `UserDefaults` mocking. 8 XCTest cases cover the matrix.
```

- [ ] **Step 3: xcodegen + build verify**

```
xcodegen generate
xcodebuild -project yawac.xcodeproj -scheme yawac -configuration Debug -derivedDataPath build/dd -destination 'platform=macOS' build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit + tag + push**

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "release: 0.10.6 — F73-F75 settings wiring + per-chat mute"
git fetch origin main
git rebase origin/main
git tag -a v0.10.6 -m "v0.10.6 — F73-F75 settings wiring + per-chat mute"
git push origin main
git push origin v0.10.6
```

- [ ] **Step 5: Watch CI**

```
sleep 6
gh run list --workflow=release.yml --limit 2
```

Expected: new run started; previous v0.10.5 already completed.

---

## Out of scope (deferred follow-ups)

These belong to later releases, not this plan:

- Menu-bar Quick-Send popover (chat picker + Send UI on the F73 NSStatusItem).
- Per-chat custom sound name (sound name is app-wide; only on/off is per-chat).
- Per-chat banner-vs-alert style override.
- Push-name edit via SendAppState (research budget too high; skipped from this bundle).
- "Show preview" per-chat override (only global today).
