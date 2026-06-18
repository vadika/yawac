# F98 — Communities Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Project rule:** Run a ponytail-review pass on touched code BEFORE every commit. See `feedback_ponytail_before_commit.md`.

**Goal:** Two community-management gaps closed in one ship. Sidebar pending-request chip becomes tappable + scrolls ChatInfoView to the PENDING REQUESTS section. New "Leave community…" button on community-parent chats bulk-leaves all sub-groups + parent.

**Architecture:** Pure SwiftUI + bridge wiring on existing primitives (`WAClient.listSubGroups`, `WAClient.leaveGroup`). No bridge / Go changes. No unit tests (pure UI wiring). Existing bridge `events.GroupInfo` handler drives chat-row removal post-leave.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-06-18-communities-polish-design.md`

---

## Pre-flight

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
```

xcodeproj is gitignored — don't `git add` it.

---

## File map

| File | Action |
|---|---|
| `yawac/ViewModels/SessionViewModel.swift` | + `PendingChatInfoSection` enum + transient var (near other `@Observable` fields) |
| `yawac/Views/ChatListView.swift` | Wrap pending-chip `HStack` (lines 883-897) in `Button` |
| `yawac/Views/ChatInfoView.swift` | `ScrollViewReader` around root `ScrollView`, `.id("pending-requests")` on PendingRequestsSection, `.onChange` observer; leave-community button split + alert + handler |
| `docs/ROADMAP.md` | Flip Communities gaps ☐ → ✅ for chip tap + leave community |
| `project.yml` / `yawac/Info.plist` | Version 0.10.32 / build 115 |

---

## Task 1: SessionViewModel.pendingChatInfoSection

**Files:** Modify `yawac/ViewModels/SessionViewModel.swift`

- [ ] **Step 1: Locate insertion point**

```bash
grep -n "pendingShortcutQuery\|weak var chatList" /Users/vadikas/Work/yawac/yawac/ViewModels/SessionViewModel.swift
```
Expected: `pendingShortcutQuery` from F97 lives around line 110. Add the new enum + var alongside it.

- [ ] **Step 2: Add the enum + field**

Insert near the existing `pendingShortcutQuery` field:

```swift
    /// F98: which ChatInfoView section to scroll to on next mount.
    /// ChatListView writes this when the user taps a sidebar
    /// affordance (e.g. pending-request chip); ChatInfoView observes
    /// + scrolls + clears so re-tapping re-triggers.
    enum PendingChatInfoSection: Equatable { case pendingRequests }
    var pendingChatInfoSection: PendingChatInfoSection? = nil
```

- [ ] **Step 3: Build**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Ponytail-review**

Single enum + single field, both minimal. The single-case enum is the right shape — leaves room for future sections without re-typing the field, but adds nothing today. Confirm and proceed.

- [ ] **Step 5: Commit**

```bash
cd /Users/vadikas/Work/yawac
git add yawac/ViewModels/SessionViewModel.swift
git commit -m "F98: SessionViewModel.pendingChatInfoSection for sidebar chip tap"
```

---

## Task 2: ChatListView — wrap pending chip in Button

**Files:** Modify `yawac/Views/ChatListView.swift:883-897`

- [ ] **Step 1: Read the existing chip block**

```bash
sed -n '878,902p' /Users/vadikas/Work/yawac/yawac/Views/ChatListView.swift
```

Expected: a Spacer + `if let pending = vm.pendingRequestsChip(for: chat)` block followed by an HStack containing icon + count Text + `.background(Theme.accent.opacity(0.25), in: Capsule())` styling + `.help(...)`.

- [ ] **Step 2: Wrap the HStack in a Button**

Replace the existing block from `if let pending = ...` through the end of the `.help(...)` modifier with:

```swift
                    if let pending = vm.pendingRequestsChip(for: chat) {
                        Button {
                            selection = chat.id
                            session.pendingChatInfoSection = .pendingRequests
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "checkmark.circle")
                                    .scaledIcon(10, weight: .semibold)
                                Text("\(pending)")
                                    .scaledMono(10.5, weight: .semibold)
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 18)
                            .background(Theme.accent.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(pending) pending request\(pending == 1 ? "" : "s") — tap to review")
                    }
```

Two things changed:
- Outer `Button { ... } label: { existing HStack }` wrap
- `.help(...)` text gains "— tap to review" suffix
- `.buttonStyle(.plain)` so the chip stays visually identical (no system button styling)

`selection` is the `Binding<Chat.ID?>` already in scope at this part of `ChatListView` (passed from ContentView). `session` is `@Environment(SessionViewModel.self)` — verify it's accessible at this nesting level via `grep -n "@Environment.*Session" /Users/vadikas/Work/yawac/yawac/Views/ChatListView.swift`. If it's not yet imported into ChatListView, add `@Environment(SessionViewModel.self) private var session` near the top of the struct.

- [ ] **Step 3: Build**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

If `selection` isn't accessible at this nesting depth (e.g. it's nested inside a closure that doesn't capture it), pass through the existing chain — search for how the surrounding row passes selection. Likely the chip is inside a chat-row view that already binds it.

- [ ] **Step 4: Ponytail-review**

The added Button is necessary (chip must be tappable). No unnecessary state. `.buttonStyle(.plain)` is the smallest no-styling escape. `.help` text is a one-line tooltip — fine. Nothing to tighten.

- [ ] **Step 5: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "F98: tap pending-request chip → open chat + flag pendingRequests section"
```

---

## Task 3: ChatInfoView observer + section id tag + ScrollViewReader

**Files:** Modify `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Verify root scroll location**

```bash
grep -n "ScrollView\|var body" /Users/vadikas/Work/yawac/yawac/Views/ChatInfoView.swift | head -5
```
Root `ScrollView` is at line 136 (inside `var body: some View` at line 125). Wrap this in a `ScrollViewReader`.

- [ ] **Step 2: Wrap the root ScrollView in ScrollViewReader**

Read lines 125-140 to capture the existing shape:

```bash
sed -n '125,140p' /Users/vadikas/Work/yawac/yawac/Views/ChatInfoView.swift
```

You'll likely see something like:
```swift
var body: some View {
    VStack(spacing: 0) {
        … header bar …
        ScrollView {
            …
```

Wrap the `ScrollView` block in `ScrollViewReader`:

```swift
        ScrollViewReader { proxy in
            ScrollView {
                … existing body …
            }
            .onChange(of: session.pendingChatInfoSection) { _, target in
                guard target == .pendingRequests else { return }
                withAnimation { proxy.scrollTo("pending-requests", anchor: .top) }
                session.pendingChatInfoSection = nil
            }
        }
```

Place the `.onChange` modifier on the ScrollView (NOT on the ScrollViewReader) so the proxy is in scope. The closure body uses `proxy` which the ScrollViewReader provides.

- [ ] **Step 3: Tag the PendingRequestsSection with `.id("pending-requests")`**

At line 1315 (per `grep -n "PendingRequestsSection(" yawac/Views/ChatInfoView.swift`):

```swift
            PendingRequestsSection(
                model: prModel,
                displayName: { jid in session.contactNames[jid] ?? jid }
            )
            .id("pending-requests")
```

The `.id(...)` modifier on the SwiftUI view registers a scroll anchor that `proxy.scrollTo(_:anchor:)` can target.

- [ ] **Step 4: Build**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

If the `.onChange` write to `session.pendingChatInfoSection = nil` fails with `cannot assign to property: 'session' is a let constant`, declare `@Bindable var bindableSession = session` inside the closure or at top of body, and write to `bindableSession.pendingChatInfoSection = nil`. SwiftUI's `@Observable` typically allows direct mutation since the env injection is a reference to the @Observable class.

- [ ] **Step 5: Ponytail-review**

ScrollViewReader is necessary (only way to drive programmatic scroll). `.id("pending-requests")` is the standard SwiftUI scroll-anchor pattern. `.onChange` is the standard observer pattern. Three lines of new code, all earning their place. Nothing to tighten.

- [ ] **Step 6: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "F98: ChatInfoView observes pendingChatInfoSection + scrolls to pending requests"
```

---

## Task 4: ChatInfoView leave-community button + alert + handler

**Files:** Modify `yawac/Views/ChatInfoView.swift`

- [ ] **Step 1: Add the `confirmLeaveCommunity` state**

Near the existing `@State private var confirmLeave = false` (line 51), add:

```swift
    /// F98: parent-side confirmation flag for the bulk
    /// listSubGroups + leaveGroup workflow. Separate from
    /// `confirmLeave` (which is the single-group leave dialog) so
    /// the dialog message can be community-aware ("you'll be
    /// removed from all sub-groups").
    @State private var confirmLeaveCommunity = false
```

- [ ] **Step 2: Switch the leave action by chat type**

At line 1256, the existing single-line button:

```swift
.init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
      destructive: true, action: { confirmLeave = true }),
```

Replace with a `g.isParent` switch. The surrounding code uses `g` as the `BridgeGroupModel` reference (per the existing PendingRequestsSection conditional at line 1310 which reads `g.isParent`):

```swift
            .init(label: g.isParent ? "Leave community" : "Leave",
                  icon: "rectangle.portrait.and.arrow.right",
                  destructive: true,
                  action: { 
                      if g.isParent {
                          confirmLeaveCommunity = true
                      } else {
                          confirmLeave = true
                      }
                  }),
```

If `g` isn't accessible at this exact line (the `.init` is inside an array literal that may be passed into a separate view), check what's in scope. The PendingRequestsSection at line 1313 uses `g`, so it should be in scope unless the actions array is built in a different scope.

Verify with:
```bash
sed -n '1240,1260p' /Users/vadikas/Work/yawac/yawac/Views/ChatInfoView.swift
```

If `g.isParent` is not in scope, use `chat.isCommunityParent` instead (the Chat struct mirror field).

- [ ] **Step 3: Add the confirmation dialog**

Near the existing `.confirmationDialog("Leave \(name)?", isPresented: $confirmLeave)` (line 191), add a sibling dialog:

```swift
        .confirmationDialog("Leave community \(name)?",
                            isPresented: $confirmLeaveCommunity) {
            Button("Leave community", role: .destructive) { leaveCommunity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be removed from \"\(name)\" and all of its sub-groups.")
        }
```

`name` is the existing chat-name variable in scope (same one the original dialog uses).

- [ ] **Step 4: Add the `leaveCommunity()` method**

Near `private func leaveGroup()` (line 324), add:

```swift
    /// F98: bulk-leave a community parent. Enumerates sub-groups
    /// via `listSubGroups` and fires `leaveGroup` per sub + once
    /// for the parent. Per-sub errors are logged but don't block the
    /// remaining sub-leaves — server may have removed the user from
    /// some subs already (stale state) and we'd rather continue.
    /// Existing bridge `events.GroupInfo` handler drives chat-row
    /// removal post-leave; no custom in-VM cleanup needed.
    private func leaveCommunity() {
        guard let client = session.client else { return }
        let parentJID = chatJID
        let parentName = name
        Task { @MainActor in
            do {
                let subs = try await Task.detached {
                    try client.listSubGroups(parentJID: parentJID)
                }.value
                for sub in subs {
                    let subJID = sub.jid
                    do {
                        try await Task.detached {
                            try client.leaveGroup(jid: subJID)
                        }.value
                        session.chatList?.applyIncomingDelete(chatJID: subJID)
                    } catch {
                        NSLog("[yawac/leaveCommunity] sub-leave failed jid=%@ err=%@",
                              subJID, String(describing: error))
                    }
                }
                do {
                    try await Task.detached {
                        try client.leaveGroup(jid: parentJID)
                    }.value
                    session.chatList?.applyIncomingDelete(chatJID: parentJID)
                } catch {
                    NSLog("[yawac/leaveCommunity] parent-leave failed jid=%@ err=%@",
                          parentJID, String(describing: error))
                }
                NSLog("[yawac/leaveCommunity] done parent=%@ subs=%d",
                      parentName, subs.count)
                onClose?()
            } catch {
                NSLog("[yawac/leaveCommunity] listSubGroups failed jid=%@ err=%@",
                      parentJID, String(describing: error))
                // Fall back to parent-only leave if enumeration fails.
                do {
                    try await Task.detached {
                        try client.leaveGroup(jid: parentJID)
                    }.value
                    session.chatList?.applyIncomingDelete(chatJID: parentJID)
                    onClose?()
                } catch {
                    NSLog("[yawac/leaveCommunity] fallback parent-leave failed jid=%@ err=%@",
                          parentJID, String(describing: error))
                }
            }
        }
    }
```

The `applyIncomingDelete(chatJID:)` call mirrors the existing `leaveGroup()` post-action (line 328) — proactively removes the row in case the bridge event takes time to propagate.

- [ ] **Step 5: Build**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

If `client.listSubGroups(parentJID:)` returns a different type than `[BridgeSubGroup]`, verify with:
```bash
grep -n "func listSubGroups" /Users/vadikas/Work/yawac/yawac/Bridge/WAClient.swift
grep -n "struct BridgeSubGroup" /Users/vadikas/Work/yawac/yawac/Bridge/WAClient.swift
```
Adapt the `sub.jid` access if the type differs.

- [ ] **Step 6: Ponytail-review**

`leaveCommunity()` is ~40 LoC — could it be smaller?

- The nested do/catch for per-sub vs parent is needed (different error logging tags + don't bail on sub failures).
- The fallback "list-failed → parent-only-leave" is borderline. Per ponytail: drop it. If `listSubGroups` fails, the user can re-tap or leave the parent via the regular Leave path (after we add a button switch back later — for now, no fallback). Decide based on how often listSubGroups actually fails. **Recommend: drop the fallback.** If it fails, log + abort. User can retry. Saves ~10 LoC.

Apply the cut: remove the catch block at the very bottom (the `// Fall back to parent-only leave...` branch). The outer catch just logs + bails. ~30 LoC final.

- [ ] **Step 7: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "F98: leave-community workflow (bulk leaveGroup over listSubGroups + parent)"
```

---

## Task 5: Manual smoke + release v0.10.32

- [ ] **Step 1: Build Debug + launch**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
cd /Users/vadikas/Work/yawac && xcodebuild -project yawac.xcodeproj -scheme yawac -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
DERIVED=$(xcodebuild -project yawac.xcodeproj -showBuildSettings -scheme yawac 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)
open "$DERIVED/yawac.app"
```

Wait ~10s for bridge auth.

- [ ] **Step 2: Smoke-test sidebar chip tap**

Pre-req: user must own a community parent with at least 1 pending request. If unavailable, skip + document as untested.

Find a chat in the sidebar showing the green checkmark pending chip. Click the chip (not the row). Expected:
- Chat opens
- ChatInfoView appears
- View scrolls to PENDING REQUESTS section

- [ ] **Step 3: Smoke-test leave community**

Pre-req: user must own a community parent (test only — don't actually leave a real community without intent).

Open a community parent's ChatInfoView. Verify:
- Button reads "Leave community" (not "Leave")
- Tap → confirmation dialog "Leave community X?" with message "You'll be removed from X and all of its sub-groups."
- Cancel → no change
- (Optional, if user has a disposable test community) Confirm → sidebar removes parent + all sub-groups within seconds

If skipping the destructive confirm, verify the dialog and Cancel path only.

- [ ] **Step 4: Smoke-test non-community group**

Open a regular group's ChatInfoView. Verify:
- Button reads "Leave" (unchanged behavior)
- Confirmation dialog matches pre-F98 wording

- [ ] **Step 5: Quit test build**

```bash
pkill -f "yawac.app/Contents/MacOS/yawac" 2>/dev/null
```

- [ ] **Step 6: Pre-flight release**

```bash
cd /Users/vadikas/Work/yawac
git status
git pull --rebase origin main
```

- [ ] **Step 7: Bump version in `project.yml`**

```
CFBundleShortVersionString: "0.10.32"
CFBundleVersion: "115"
```

- [ ] **Step 8: Regenerate Xcode project**

```bash
xcodegen
```

- [ ] **Step 9: Flip ROADMAP bullets**

In `docs/ROADMAP.md`, find the Communities gaps section (around line 138 and 141):

```markdown
    - ☐ **Approve from sidebar chip tap** — sidebar pending-count
      chip is read-only; tapping doesn't jump to the PENDING
      REQUESTS section. Tap currently opens the chat as normal.
```
Replace with:
```markdown
    - ✅ **Approve from sidebar chip tap** — landed as F98 in v0.10.32.
```

```markdown
    - ☐ **Leave community** — multi-step "leave all sub-groups +
      leave parent" workflow. Today user leaves each sub-group +
      parent individually via Leave group on each chat info.
```
Replace with:
```markdown
    - ✅ **Leave community** — landed as F98 in v0.10.32.
```

- [ ] **Step 10: Append shipped entry**

Under `# Shipped (✅)`, BEFORE the existing F97 entry, prepend:

```markdown
- ✅ **F98 — Communities polish: sidebar chip tap + leave-community workflow** (v0.10.32) —
  Two bounded community-management gaps closed in one ship.
  - **Sidebar pending-request chip is now tappable.** Previously a
    read-only badge; tap opens the chat AND scrolls ChatInfoView
    to the PENDING REQUESTS section. Implementation:
    `SessionViewModel.pendingChatInfoSection: PendingChatInfoSection?`
    transient field, `ChatListView` chip wrapped in `Button`,
    `ChatInfoView` body wrapped in `ScrollViewReader` with
    `.onChange` observer that runs `proxy.scrollTo("pending-requests",
    anchor: .top)` and consumes the flag. Help-text gains "— tap
    to review" suffix.
  - **Leave community workflow.** ChatInfoView's leave button on a
    community parent (`isParent` per BridgeGroupModel) now reads
    "Leave community" and opens a community-aware confirmation:
    "You'll be removed from X and all of its sub-groups." Confirm
    enumerates sub-groups via `WAClient.listSubGroups(parentJID:)`,
    fires `WAClient.leaveGroup(jid:)` per sub (per-sub errors
    logged, loop continues), then for the parent.
    `applyIncomingDelete(chatJID:)` proactively removes rows from
    `chats[]`; existing bridge `events.GroupInfo` handler covers the
    rest. Non-parent chats keep the original "Leave" wording.
  - **No bridge / Go changes.** No unit tests (pure UI wiring).
    Manual smoke on Debug.
  - **Spec / plan.** Design at `docs/superpowers/specs/2026-06-18
    -communities-polish-design.md`; plan at
    `docs/superpowers/plans/2026-06-18-communities-polish.md`.
  - **Out of scope (deferred / blocked).** Demote community parent
    → plain group (whatsmeow has no RPC), default-subgroup unlink
    (server breaks announcements channel), Newsletter/Channels
    (upstream Platform == MACOS argo decoding blocker).
```

- [ ] **Step 11: Commit + tag + push**

```bash
git add project.yml yawac/Info.plist docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
release: 0.10.32 — F98 Communities polish (chip tap + leave community)

Two community gaps closed. Sidebar pending-request chip is now
tappable + scrolls ChatInfoView to PENDING REQUESTS section via a
transient SessionViewModel field + ScrollViewReader observer.
Leave-community button on community parent enumerates sub-groups
via listSubGroups, bulk-fires leaveGroup per sub + once for the
parent (per-sub errors logged but don't bail the loop). No bridge
changes; pure UI wiring on existing primitives.
EOF
)"
git tag -a v0.10.32 -m "yawac 0.10.32 — F98 Communities polish"
git push origin main
git push origin v0.10.32
```

- [ ] **Step 12: Verify release**

```bash
gh run watch   # release workflow; ignore CI flake on TestApplyHistorySyncEmitsMessages
gh release view v0.10.32 --json tagName,isDraft,publishedAt,assets
```
Expected: `isDraft: false`, both `yawac-0.10.32.zip` + `appcast.xml` uploaded.

Allow xcodebuild 5 min, CI 10 min.

---

## Self-review

**1. Spec coverage:**

| Spec section | Task |
|---|---|
| Item 1 sidebar chip tap — Session field | Task 1 |
| Item 1 — ChatListView Button wrap | Task 2 |
| Item 1 — ChatInfoView observer + scroll | Task 3 |
| Item 2 leave-community — button split | Task 4 |
| Item 2 — confirmation alert | Task 4 |
| Item 2 — `leaveCommunity()` handler | Task 4 |
| Manual smoke | Task 5 |
| Release v0.10.32 | Task 5 |

No gaps.

**2. Placeholder scan:** No TBD / TODO / vague reqs. Every step has concrete code or commands.

**3. Type consistency:**
- `PendingChatInfoSection.pendingRequests` used in Tasks 1, 2, 3
- `session.pendingChatInfoSection` write site (Task 2 ChatListView) and read/reset site (Task 3 ChatInfoView) consistent
- `confirmLeaveCommunity` declared (Task 4 Step 1), set (Task 4 Step 2), observed (Task 4 Step 3)
- `leaveCommunity()` defined (Task 4 Step 4), called from confirm dialog (Task 4 Step 3)
- `WAClient.listSubGroups(parentJID:)` + `WAClient.leaveGroup(jid:)` verified during plan prep
