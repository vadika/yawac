# Group Name + Description Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show + edit a group's name and description from `ChatInfoView`. Admin-only inline-pencil edit; URLs in description auto-linked; cross-device sync via `events.GroupInfo`. Bridge wraps whatsmeow's `SetGroupName` + `SetGroupDescription` IQ writes.

**Architecture:** Mirrors the mute appstate-event pattern — Go `SetGroupName`/`SetGroupDescription` issue direct IQ writes returning `error`; whatsmeow fans the server-side change back as `events.GroupInfo` which we dispatch as `JGroupInfoChanged`. Swift VM keeps `PersistedChat.groupDescription` in sync; `ChatInfoView` renders two editable sections gated on admin status. The existing `BridgeGroupModel.topic` field is the wire-level description (WhatsApp's proto names it "Topic"); we map it into `Chat.groupDescription` on the Swift side without changing the bridge field name.

**Tech Stack:** Go 1.22 + whatsmeow, gomobile xcframework, Swift 5.10, SwiftUI macOS 14+, SwiftData lightweight migration, `NSDataDetector` for URL auto-link.

---

## File Map

**New files:**
- `yawacTests/ChatListViewModelGroupInfoTests.swift` — VM unit tests.
- `yawac/Views/LinkifyHelper.swift` — small shared helper `linkified(_:)` extracted from the existing pattern in `MessageRow.swift:590`. Used by description rendering and stays available for future surfaces.

**Modified files:**
- `bridge/groups.go` — `SetGroupName`, `SetGroupDescription`.
- `bridge/events.go` — `case *events.GroupInfo` + `dispatchGroupInfo`.
- `bridge/jsonmodels.go` — `JGroupInfoChanged`.
- `bridge/events_dispatch_test.go` — three `dispatchGroupInfo` tests.
- `bridge/groups_test.go` — name + description bridge tests (if helpers exist).
- `yawac/Bridge/WAClient.swift` — `setGroupName`, `setGroupDescription`, `Event.groupInfoChanged`, decoder branch.
- `yawac/Models/Chat.swift` — `groupDescription: String? = nil`.
- `yawac/Models/PersistedMessage.swift` — `PersistedChat.groupDescription` + init param.
- `yawac/ViewModels/ChatListViewModel.swift` — VM methods, apply-local / apply-incoming, `groupDescription` round-trip in `upsertPersisted` + `loadChats`, cold-start backfill from `getGroupInfo`.
- `yawac/ContentView.swift` — `.groupInfoChanged` event apply.
- `yawac/Views/ChatInfoView.swift` — editable Name + Description sections, `isCurrentUserAdmin`, two `@State` edit-mode flags.
- `yawac/Views/MessageRow.swift` — replace inline `NSDataDetector` link block with a call to the new `LinkifyHelper` (optional cleanup; can stay duplicated if the move is risky).

Order: Go bridge first → xcframework rebuild → Swift bridge → models → VM (TDD) → ContentView wiring → ChatInfoView UI → full test → manual gate.

---

## Task 1: Bridge `SetGroupName` + `SetGroupDescription`

**Files:**
- Modify: `bridge/groups.go`

- [ ] **Step 1: Add the two wrappers**

Append to `bridge/groups.go` (after `LeaveGroup` ~line 155):

```go
// SetGroupName changes the displayed group name (WhatsApp "subject").
// The server fans the change out as an events.GroupInfo to every
// participant, including this client.
func (c *Client) SetGroupName(chatJID, name string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SetGroupName(context.Background(), jid, name)
}

// SetGroupDescription changes the group description (WhatsApp "topic").
// Empty `description` clears it. The server fans the change out as an
// events.GroupInfo with a populated Topic field.
func (c *Client) SetGroupDescription(chatJID, description string) error {
	if c.wa == nil {
		return errors.New("client closed")
	}
	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("parse jid: %w", err)
	}
	return c.wa.SetGroupDescription(context.Background(), jid, description)
}
```

- [ ] **Step 2: Build the Go bridge**

```bash
cd bridge && go build ./... && cd ..
```

Expected: clean compile.

- [ ] **Step 3: Run Go tests**

```bash
cd bridge && go test ./... 2>&1 | tail -10
```

Expected: existing tests still pass; no new tests yet (added in Task 3).

- [ ] **Step 4: Commit**

```bash
git add bridge/groups.go
git commit -m "bridge: SetGroupName + SetGroupDescription"
```

---

## Task 2: Bridge `events.GroupInfo` dispatch + `JGroupInfoChanged`

**Files:**
- Modify: `bridge/jsonmodels.go`
- Modify: `bridge/events.go`

- [ ] **Step 1: Add the JSON model**

Append to `bridge/jsonmodels.go` (after `JChatMuted`):

```go
type JGroupInfoChanged struct {
	ChatJID     string `json:"chat_jid"`
	Name        string `json:"name"`        // empty = unchanged this event
	Description string `json:"description"` // empty = unchanged this event
	Timestamp   int64  `json:"timestamp"`
}
```

- [ ] **Step 2: Add the event case + dispatcher to `bridge/events.go`**

In `handleWAEvent` switch, after the existing `*events.Mute` case (~line 71-72), add:

```go
		case *events.GroupInfo:
			c.dispatchGroupInfo(v)
```

Append the dispatcher near `dispatchMute` / `dispatchArchive`:

```go
// dispatchGroupInfo surfaces app-level group metadata changes
// (name + description). Other GroupInfo fields (locked, announce,
// ephemeral, membership-approval, participant changes) are ignored
// here — they belong on separate handlers. When neither name nor
// description carried a value in this event, we don't dispatch.
func (c *Client) dispatchGroupInfo(evt *events.GroupInfo) {
	var name, description string
	if evt.Name != nil {
		name = evt.Name.Name
	}
	if evt.Topic != nil {
		description = evt.Topic.Topic
	}
	if name == "" && description == "" {
		return
	}
	fmt.Fprintf(os.Stderr,
		"[yawac/groupInfo] dispatch jid=%s name=%q desc_len=%d\n",
		evt.JID.String(), name, len(description))
	b, _ := json.Marshal(JGroupInfoChanged{
		ChatJID:     evt.JID.String(),
		Name:        name,
		Description: description,
		Timestamp:   evt.Timestamp.Unix(),
	})
	c.dispatch("GroupInfoChanged", string(b))
}
```

> If `evt.Name.Name` / `evt.Topic.Topic` are unexported, confirm the
> field names via:
> `grep -A3 'type GroupName\|type GroupTopic' ~/go/pkg/mod/github.com/vadika/whatsmeow*/types/group.go`
> and adapt. Common alternates: capitalized `Name` field, getter
> `GetName()` / `GetTopic()`.

- [ ] **Step 3: Add a dispatcher test in `bridge/events_dispatch_test.go`**

Locate an existing dispatcher test (e.g., `TestMuteJSON`) and mirror its shape. Append:

```go
func TestGroupInfoNameOnlyJSON(t *testing.T) {
	c, sink := newRecSink(t)
	evt := &events.GroupInfo{
		JID:       types.JID{User: "111", Server: types.GroupServer},
		Timestamp: time.Unix(1700000000, 0),
		Name:      &types.GroupName{Name: "New Name"},
	}
	c.dispatchGroupInfo(evt)
	kind, payload := sink.wait()
	if kind != "GroupInfoChanged" {
		t.Fatalf("kind=%s want GroupInfoChanged", kind)
	}
	var got JGroupInfoChanged
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.Name != "New Name" || got.Description != "" {
		t.Errorf("got %+v", got)
	}
}

func TestGroupInfoTopicOnlyJSON(t *testing.T) {
	c, sink := newRecSink(t)
	evt := &events.GroupInfo{
		JID:       types.JID{User: "111", Server: types.GroupServer},
		Timestamp: time.Unix(1700000000, 0),
		Topic:     &types.GroupTopic{Topic: "New description"},
	}
	c.dispatchGroupInfo(evt)
	kind, payload := sink.wait()
	if kind != "GroupInfoChanged" {
		t.Fatalf("kind=%s want GroupInfoChanged", kind)
	}
	var got JGroupInfoChanged
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.Description != "New description" || got.Name != "" {
		t.Errorf("got %+v", got)
	}
}

func TestGroupInfoNeitherSkipsDispatch(t *testing.T) {
	c, sink := newRecSink(t)
	evt := &events.GroupInfo{
		JID:       types.JID{User: "111", Server: types.GroupServer},
		Timestamp: time.Unix(1700000000, 0),
		// Name + Topic both nil → no name/desc; we expect no dispatch.
	}
	c.dispatchGroupInfo(evt)
	if got := sink.peek(); got != "" {
		t.Fatalf("unexpected dispatch: %q", got)
	}
}
```

> The exact `types.GroupServer` constant name (vs `DefaultUserServer`)
> may differ — check existing tests like `TestMuteJSON` for the right
> spelling. The `newRecSink`/`sink.wait()`/`sink.peek()` helpers are
> existing patterns from the mute dispatcher tests in the same file.
> If `peek()` doesn't exist, use a short timeout on `wait()` and
> assert it returned the zero kind.

- [ ] **Step 4: Build + test**

```bash
cd bridge && go test ./... 2>&1 | tail -15
```

Expected: 3 new tests pass; suite green.

- [ ] **Step 5: Commit**

```bash
git add bridge/events.go bridge/jsonmodels.go bridge/events_dispatch_test.go
git commit -m "bridge: dispatch events.GroupInfo (name/description) as GroupInfoChanged"
```

---

## Task 3: Rebuild `Bridge.xcframework`

**Files:** none (regenerated artifact).

- [ ] **Step 1: Run build script**

```bash
./scripts/build-xcframework.sh 2>&1 | tail -5
```

Expected: `Built: build/Bridge.xcframework`.

- [ ] **Step 2: Verify new methods exported**

```bash
grep -nE 'setGroupName|setGroupDescription|skipped method.*SetGroup' \
  build/Bridge.xcframework/macos-arm64_x86_64/Bridge.framework/Versions/A/Headers/Bridge.objc.h | head
```

Expected: real method declarations for `setGroupName:` and
`setGroupDescription:`. NO "skipped method" lines.

- [ ] **Step 3: No commit** (xcframework gitignored).

---

## Task 4: Swift bridge wrappers + Event enum + decoder

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`

- [ ] **Step 1: Extend the `Event` enum**

In `yawac/Bridge/WAClient.swift` find the `Event` enum (~lines 31-52). After `case chatMuted(...)`, add:

```swift
        case groupInfoChanged(chatJID: String, name: String, description: String, timestamp: Int64)
```

- [ ] **Step 2: Add the wrappers**

After the existing `archiveChat(chatJID:archived:lastTS:lastMsgID:fromMe:)` (~line 267), add:

```swift
    func setGroupName(chatJID: String, name: String) throws {
        try go.setGroupName(chatJID, name: name)
    }

    func setGroupDescription(chatJID: String, description: String) throws {
        try go.setGroupDescription(chatJID, description: description)
    }
```

> If the gomobile-generated selectors differ (verify from the header
> in Task 3 Step 2), adapt the call sites. Typical gomobile naming is
> `setGroupName(_:name:error:)` etc.

- [ ] **Step 3: Add the decoder case**

In the event-payload decoder (around the existing `case "ChatMuted":` block), add after that case:

```swift
        case "GroupInfoChanged":
            struct G: Codable {
                let chatJID: String
                let name: String
                let description: String
                let timestamp: Int64
                enum CodingKeys: String, CodingKey {
                    case chatJID = "chat_jid"
                    case name, description, timestamp
                }
            }
            if let g = try? dec.decode(G.self, from: data) {
                return .groupInfoChanged(chatJID: g.chatJID,
                                         name: g.name,
                                         description: g.description,
                                         timestamp: g.timestamp)
            }
```

- [ ] **Step 4: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift
git commit -m "bridge: Swift wrappers for SetGroupName + SetGroupDescription + GroupInfoChanged"
```

---

## Task 5: Model fields — `Chat.groupDescription`, `PersistedChat.groupDescription`

**Files:**
- Modify: `yawac/Models/Chat.swift`
- Modify: `yawac/Models/PersistedMessage.swift`

- [ ] **Step 1: Extend `Chat`**

In `yawac/Models/Chat.swift`, after `mutedUntil: Date? = nil`, add:

```swift
    var groupDescription: String? = nil
```

- [ ] **Step 2: Extend `PersistedChat`**

In `yawac/Models/PersistedMessage.swift` `PersistedChat` (~lines 154-187), add the property next to `mutedUntil`:

```swift
    var groupDescription: String? = nil
```

And add a matching init param (defaulted). Locate the init `init(jid:name:...mutedUntil:)` (post-T5-mute change), append `groupDescription: String? = nil` before the closing `)`. In the body, add `self.groupDescription = groupDescription`.

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. SwiftData lightweight migration handles the new defaulted column.

- [ ] **Step 4: Commit**

```bash
git add yawac/Models/Chat.swift yawac/Models/PersistedMessage.swift
git commit -m "models: Chat + PersistedChat gain groupDescription"
```

---

## Task 6: `ChatListViewModel` core — VM methods + apply + persist round-trip (TDD)

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`
- Create: `yawacTests/ChatListViewModelGroupInfoTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `yawacTests/ChatListViewModelGroupInfoTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ChatListViewModelGroupInfoTests: XCTestCase {

    private func makeVM() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }

    private func chat(_ jid: String, name: String = "G",
                      description: String? = nil) -> Chat {
        var c = Chat(jid: jid, name: name, lastMessage: "",
                     lastTimestamp: 0, unread: 0)
        c.groupDescription = description
        return c
    }

    func testApplyIncomingNameOnlyUpdatesName() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "Old", description: "desc")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: "New", description: nil, at: Date())
        XCTAssertEqual(vm.chats.first?.name, "New")
        XCTAssertEqual(vm.chats.first?.groupDescription, "desc")
    }

    func testApplyIncomingDescriptionOnlyUpdatesDescription() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "old")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: nil, description: "new", at: Date())
        XCTAssertEqual(vm.chats.first?.name, "G")
        XCTAssertEqual(vm.chats.first?.groupDescription, "new")
    }

    func testApplyIncomingBothUpdates() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "Old", description: "old")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: "New", description: "new", at: Date())
        XCTAssertEqual(vm.chats.first?.name, "New")
        XCTAssertEqual(vm.chats.first?.groupDescription, "new")
    }

    func testApplyIncomingNilBothNoop() {
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "d")]
        vm.applyIncomingGroupInfo(chatJID: "g@g.us",
                                  name: nil, description: nil, at: Date())
        XCTAssertEqual(vm.chats.first?.name, "G")
        XCTAssertEqual(vm.chats.first?.groupDescription, "d")
    }

    func testApplyLocalGroupInfoEmptyDescriptionStoredAsNil() {
        // Empty string from a "clear description" save should land as nil
        // so the read-only branch renders the "No description" placeholder.
        let vm = makeVM()
        vm.chats = [chat("g@g.us", name: "G", description: "old")]
        vm.applyLocalGroupInfo(chatJID: "g@g.us", name: nil, description: "")
        XCTAssertNil(vm.chats.first?.groupDescription)
    }
}
```

- [ ] **Step 2: Run, confirm build failure**

```bash
xcodegen generate
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatListViewModelGroupInfoTests 2>&1 | tail -10
```

Expected: `Cannot find member 'applyIncomingGroupInfo'` / `'applyLocalGroupInfo'`.

- [ ] **Step 3: Add VM methods to `ChatListViewModel.swift`**

Append after the existing `reconcileMutedWithStore` (or alongside the other Mute helpers — find via `grep -n 'MARK: - Mute' yawac/ViewModels/ChatListViewModel.swift`):

```swift
    // MARK: - Group info (name + description)

    /// Issues `SetGroupName` to the bridge + optimistic local apply.
    func setGroupName(_ chat: Chat, to name: String) {
        guard let client else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            do {
                try client.setGroupName(chatJID: chat.jid, name: trimmed)
                self.applyLocalGroupInfo(chatJID: chat.jid,
                                        name: trimmed,
                                        description: nil)
            } catch {
                NSLog("[yawac/setGroupName] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// Issues `SetGroupDescription` to the bridge + optimistic local apply.
    /// Empty string clears the description on the server and stores nil
    /// locally.
    func setGroupDescription(_ chat: Chat, to description: String) {
        guard let client else { return }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try client.setGroupDescription(chatJID: chat.jid,
                                               description: trimmed)
                self.applyLocalGroupInfo(chatJID: chat.jid,
                                        name: nil,
                                        description: trimmed)
            } catch {
                NSLog("[yawac/setGroupDescription] failed jid=%@ err=%@",
                      chat.jid, String(describing: error))
            }
        }
    }

    /// Updates `chats[]` entry and persists. `name == nil` leaves name
    /// untouched. `description == nil` leaves description untouched.
    /// Empty `description` ("" — sent by an explicit "clear it" save)
    /// stores `nil` locally so the placeholder renders.
    func applyLocalGroupInfo(chatJID: String, name: String?, description: String?) {
        if let idx = chats.firstIndex(where: { $0.jid == chatJID }) {
            if let n = name, !n.isEmpty {
                chats[idx].name = n
            }
            if let d = description {
                chats[idx].groupDescription = d.isEmpty ? nil : d
            }
            upsertPersisted(chats[idx])
        } else if let context {
            let descriptor = FetchDescriptor<PersistedChat>(
                predicate: #Predicate { $0.jid == chatJID })
            if let row = try? context.fetch(descriptor).first {
                if let n = name, !n.isEmpty { row.name = n }
                if let d = description {
                    row.groupDescription = d.isEmpty ? nil : d
                }
                try? context.save()
            }
        }
    }

    /// Event-path equivalent. Last-event-wins (the values are state, not
    /// operation timestamps — same pattern as mute).
    func applyIncomingGroupInfo(chatJID: String,
                                name: String?,
                                description: String?,
                                at _: Date) {
        applyLocalGroupInfo(chatJID: chatJID,
                            name: name, description: description)
    }
```

- [ ] **Step 4: Round-trip `groupDescription` in `upsertPersisted`**

In `yawac/ViewModels/ChatListViewModel.swift`, find `upsertPersisted` (lines 660-693 area). In both branches (insert + update), add `groupDescription` next to the existing `mutedUntil`:

- Insert branch: in the `PersistedChat(...)` init call, add `groupDescription: c.groupDescription`.
- Update branch: alongside `row.mutedUntil = c.mutedUntil`, add `row.groupDescription = c.groupDescription`.

Use `grep -n 'mutedUntil\b' yawac/ViewModels/ChatListViewModel.swift` to find every site; every line that round-trips `mutedUntil` also needs `groupDescription`.

- [ ] **Step 5: Derive `groupDescription` in `loadChats`**

In the same file, in `loadChats` around line 198-207, the `Chat(...)` init from a `PersistedChat` row. Add `groupDescription: row.groupDescription` to the initializer call.

- [ ] **Step 6: Cold-start backfill from `getGroupInfo`**

Find the existing `loadGroupParticipantsIfNeeded` on `ConversationViewModel` (added in the mention-autocomplete feature). It currently sets `self.groupParticipants = info.participants`. Add a sibling backfill of the chat-list description:

```swift
            self.groupParticipants = info.participants
            // Side-effect: keep chat-list's groupDescription in sync
            // with the freshly-fetched group topic.
            if !info.topic.isEmpty {
                chatList?.applyLocalGroupInfo(chatJID: jid,
                                              name: nil,
                                              description: info.topic)
            }
```

`chatList` reference exists on CVM (`weak var chatList: ChatListViewModel?`). If it's nil at this point (the chat list VM wasn't wired yet), the backfill no-ops — that's fine; next refresh triggers it again.

- [ ] **Step 7: Run mute + group-info tests + new tests**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  -only-testing:yawacTests/ChatListViewModelGroupInfoTests \
  -only-testing:yawacTests/ChatListViewModelMuteTests 2>&1 | tail -15
```

Expected: all pass (5 new + 8 existing mute = 13 total).

- [ ] **Step 8: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift \
        yawac/ViewModels/ConversationViewModel.swift \
        yawacTests/ChatListViewModelGroupInfoTests.swift
git commit -m "convo: groupInfo apply + setGroupName/Description + cold-start backfill"
```

---

## Task 7: `ContentView` event apply

**Files:**
- Modify: `yawac/ContentView.swift`

- [ ] **Step 1: Add the `.groupInfoChanged` case**

In `yawac/ContentView.swift` find the event-apply switch (~line 180 area, next to `.chatMuted`). After the `.chatMuted` case body, add:

```swift
                case .groupInfoChanged(let chatJID, let name, let description, let ts):
                    let canonical = JIDNormalize.canonical(chatJID, client: client)
                    let when = Date(timeIntervalSince1970: TimeInterval(ts))
                    vm.applyIncomingGroupInfo(
                        chatJID: canonical,
                        name:        name.isEmpty        ? nil : name,
                        description: description.isEmpty ? nil : description,
                        at: when)
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "convo: route GroupInfoChanged events into applyIncomingGroupInfo"
```

---

## Task 8: URL auto-link helper

**Files:**
- Create: `yawac/Views/LinkifyHelper.swift`

This task extracts the `NSDataDetector` URL-linking pattern currently inline at `yawac/Views/MessageRow.swift:590` into a reusable helper. `MessageRow.swift` keeps its inline version (not migrated here — separate cleanup task), but the new helper is the shared API for surfaces like the group description.

- [ ] **Step 1: Create the file**

Write `yawac/Views/LinkifyHelper.swift`:

```swift
import Foundation
import SwiftUI

/// Converts a plain string to an `AttributedString` with bare URLs
/// auto-linked (`https://example.com` becomes a clickable link styled
/// in `Theme.accent`). Used by surfaces that render user-authored
/// blob text — e.g. group description.
enum Linkify {
    static func attributed(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let str = String(attr.characters)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attr
        }
        let nsRange = NSRange(str.startIndex..<str.endIndex, in: str)
        detector.enumerateMatches(in: str, range: nsRange) { match, _, _ in
            guard let match, let url = match.url,
                  let range = Range(match.range, in: str),
                  let attrRange = attr.range(of: String(str[range])) else { return }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = Color.accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodegen generate
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/LinkifyHelper.swift
git commit -m "views: Linkify helper for URL auto-link in plain-text blobs"
```

---

## Task 9: `ChatInfoView` UI — editable Name + Description sections

**Files:**
- Modify: `yawac/Views/ChatInfoView.swift`

View-layer only — verification = build + visual.

- [ ] **Step 1: Add edit-mode state + helpers**

In `yawac/Views/ChatInfoView.swift`, find the top of the struct (around the existing `@State` declarations near line 10-30). Add four new state slots:

```swift
    @State private var editingName: Bool = false
    @State private var editingDescription: Bool = false
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
```

Add a computed `isCurrentUserAdmin: Bool` somewhere near the other helpers (before `groupBody`):

```swift
    private func isCurrentUserAdmin(_ g: BridgeGroupModel) -> Bool {
        let ownJID = JIDNormalize.bare(session.client?.ownJID ?? "")
        guard !ownJID.isEmpty else { return false }
        return g.participants.contains { p in
            JIDNormalize.bare(p.jid) == ownJID && (p.isAdmin || p.isSuper)
        }
    }
```

`session` is `@Environment(SessionViewModel.self) private var session` — confirm it's already declared on `ChatInfoView` (it is — used elsewhere).

- [ ] **Step 2: Replace the read-only TOPIC section with editable Name + Description sections**

Find the current `groupBody` start (~line 249). Replace the existing TOPIC section (~lines 250-257) with the new Name + Description blocks. The function gains a leading admin check:

```swift
    @ViewBuilder
    private func groupBody(_ g: BridgeGroupModel) -> some View {
        let admin = isCurrentUserAdmin(g)
        let chat = chatList?.chats.first(where: { $0.jid == g.jid })
            ?? Chat(jid: g.jid, name: g.name,
                    lastMessage: "", lastTimestamp: 0, unread: 0)

        // NAME
        sectionCard(label: "NAME") {
            if editingName {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Group name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .onChange(of: nameDraft) { _, new in
                            if new.count > 100 {
                                nameDraft = String(new.prefix(100))
                            }
                        }
                    HStack {
                        Text("\(nameDraft.count)/100")
                            .scaledMono(10)
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Cancel") {
                            editingName = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textMuted)
                        Button("Save") {
                            chatList?.setGroupName(chat, to: nameDraft)
                            editingName = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || nameDraft == g.name)
                    }
                }
            } else {
                HStack(alignment: .top) {
                    Text(g.name)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if admin {
                        Button {
                            nameDraft = g.name
                            editingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .scaledIcon(11, weight: .semibold)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Edit name")
                    }
                }
            }
        }

        // DESCRIPTION
        sectionCard(label: "DESCRIPTION") {
            if editingDescription {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Add a description",
                              text: $descriptionDraft,
                              axis: .vertical)
                        .lineLimit(3...10)
                        .textFieldStyle(.plain)
                        .scaledUI(13)
                        .foregroundStyle(Theme.text)
                        .onChange(of: descriptionDraft) { _, new in
                            if new.count > 512 {
                                descriptionDraft = String(new.prefix(512))
                            }
                        }
                    HStack {
                        Text("\(descriptionDraft.count)/512")
                            .scaledMono(10)
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Cancel") {
                            editingDescription = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textMuted)
                        Button("Save") {
                            chatList?.setGroupDescription(chat,
                                to: descriptionDraft)
                            editingDescription = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(descriptionDraft == (chat.groupDescription ?? ""))
                    }
                }
            } else {
                HStack(alignment: .top) {
                    let desc = (chat.groupDescription ?? "").isEmpty
                        ? nil
                        : chat.groupDescription
                    Group {
                        if let d = desc {
                            Text(Linkify.attributed(d))
                                .scaledUI(13)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                        } else {
                            Text("No description")
                                .scaledUI(13)
                                .foregroundStyle(Theme.textFaint)
                                .italic()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if admin {
                        Button {
                            descriptionDraft = chat.groupDescription ?? ""
                            editingDescription = true
                        } label: {
                            Image(systemName: "pencil")
                                .scaledIcon(11, weight: .semibold)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Edit description")
                    }
                }
            }
        }

        metadataRow([
            .init(label: "MEMBERS", value: "\(g.participants.count)"),
            .init(label: "CREATED",
                  value: Date(timeIntervalSince1970: TimeInterval(g.created))
                    .formatted(.dateTime.day().month(.abbreviated).year())),
        ])

        actionRow(actions: [
            .init(label: "Mute", icon: "speaker.slash"),
            .init(label: "Search", icon: "magnifyingglass"),
            .init(label: "Leave", icon: "rectangle.portrait.and.arrow.right",
                  destructive: true, action: { confirmLeave = true }),
        ])

        starredSection
        sharedMediaSection
        filesSection

        sectionLabel("PARTICIPANTS", trailing: "\(g.participants.count)")
        VStack(spacing: 0) {
            ForEach(sortedParticipants(g.participants), id: \.jid) { p in
                participantRow(p)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }

        if g.isParent && !linkedGroups.isEmpty {
            sectionLabel("LINKED GROUPS", trailing: "\(linkedGroups.count)")
            VStack(spacing: 0) {
                ForEach(linkedGroups, id: \.jid) { sub in
                    linkedGroupRow(sub)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }
```

The replacement preserves every section after the previous TOPIC block (metadataRow, actionRow, starredSection, sharedMediaSection, filesSection, PARTICIPANTS, LINKED GROUPS) verbatim — diff just inserts Name + Description and removes the old TOPIC block.

`chatList` is `@Environment(ChatListViewModel.self) private var chatList` — confirm it's already declared on `ChatInfoView`. If declared `optional`, the `chatList?.` calls are correct. If it's non-optional, drop the `?`. (Check via `grep -n 'ChatListViewModel' yawac/Views/ChatInfoView.swift`.)

- [ ] **Step 3: Build verify**

```bash
xcodebuild build -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatInfoView.swift
git commit -m "info: editable Name + Description sections with admin gating + autolink"
```

---

## Task 10: Full test suite gate

- [ ] **Step 1: Run full suite**

```bash
xcodebuild test -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`. Pre-existing flaky `ChatSearchViewModelTests` debounce tests may need one retry.

- [ ] **Step 2: If green, no commit. If red on unrelated tests, retry once.**

---

## Task 11: Manual visual gate

No commit — interactive check.

- [ ] Open a group as admin in the inspector pane (right side). Name + Description sections show with pencil buttons.
- [ ] Tap the Name pencil. Field becomes editable. Counter "N/100" shown. Save button disabled until something changes.
- [ ] Type a new name (under 100 chars). Save. Section collapses; new name visible everywhere (sidebar row, header).
- [ ] Try pasting 200 chars: cut off at 100.
- [ ] Tap the Description pencil. Same behavior with 512 cap.
- [ ] Add a URL like `https://example.com` to the description. Save. Read-only view shows it as a clickable link.
- [ ] Cancel mid-edit: drafts discarded, original text shown.
- [ ] Open a group as a non-admin. No pencils. Description renders read-only.
- [ ] Empty-description group as admin: "No description" placeholder with pencil to add one.
- [ ] Rename the same group on the phone. yawac reflects within seconds (event-driven).
- [ ] Change description on phone → yawac reflects within seconds.

---

## Done When

- All `xcodebuild` commands succeed.
- All 11 manual checks pass.
- Commits land on `main`: Tasks 1, 2, 4, 5, 6, 7, 8, 9 each one commit. Tasks 3, 10, 11 are gates.
