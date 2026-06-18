# F98 — Communities Polish

> Roadmap entries: `docs/ROADMAP.md` — Channels / Communities gaps (sidebar chip tap + leave-community workflow).

## Goal

Two bounded community-management gaps closed in one ship:

1. **Sidebar pending-request chip tap** — currently a read-only badge. Tap should open the chat AND scroll the ChatInfoView to the PENDING REQUESTS section.
2. **Leave community workflow** — currently the user leaves the parent + each sub-group individually. One button that bulk-leaves all sub-groups + the parent.

## Architecture

Pure SwiftUI / bridge wiring on existing primitives:
- `WAClient.listSubGroups(parentJID:)` (existing) — enumerates sub-groups
- `WAClient.leaveGroup(jid:)` (existing) — leaves one group
- Bridge `events.GroupInfo` already drives chat-row removal post-leave — no custom cleanup

No bridge / Go changes. No new tests (pure UI wiring with bridge calls).

## Item 1 — Sidebar chip tap

### Component: SessionViewModel transient field

```swift
enum PendingChatInfoSection: Equatable { case pendingRequests }
var pendingChatInfoSection: PendingChatInfoSection? = nil
```

Consumer (ChatInfoView) resets to nil after applying so re-tapping the same chip re-triggers.

### Component: ChatListView chip → Button

`ChatListView.swift:883-897` — wrap the existing chip `HStack` in `Button`:

```swift
Button {
    selection = chat.id
    session.pendingChatInfoSection = .pendingRequests
} label: {
    HStack(spacing: 2) {
        // existing icon + count + capsule contents
    }
}
.buttonStyle(.plain)
.help("\(pending) pending request\(pending == 1 ? "" : "s") — tap to review")
```

### Component: ChatInfoView scroll observer

Wrap the existing root scroll in `ScrollViewReader`. Tag the PENDING REQUESTS section (around line 2098) with `.id("pending-requests")`.

```swift
ScrollViewReader { proxy in
    ScrollView { /* existing body */ }
        .onChange(of: session.pendingChatInfoSection) { _, target in
            guard target == .pendingRequests else { return }
            withAnimation { proxy.scrollTo("pending-requests", anchor: .top) }
            session.pendingChatInfoSection = nil
        }
}
```

## Item 2 — Leave community

### Component: ChatInfoView button switch

`ChatInfoView.swift:192` — current single line:
```swift
Button("Leave", role: .destructive) { leaveGroup() }
```

Replace with parent-aware split:
```swift
if chat.isCommunityParent {
    Button("Leave community…", role: .destructive) {
        confirmLeaveCommunity = true
    }
} else {
    Button("Leave", role: .destructive) { leaveGroup() }
}
```

### Component: Confirmation alert

New `@State private var confirmLeaveCommunity: Bool = false` near other ChatInfoView state.

```swift
.alert("Leave community?", isPresented: $confirmLeaveCommunity) {
    Button("Leave", role: .destructive) { leaveCommunity() }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("You will be removed from \"\(chat.name)\" and all of its sub-groups.")
}
```

### Component: `leaveCommunity()`

Mirror existing `leaveGroup()` shape (line 324-333):

```swift
private func leaveCommunity() {
    let parentJID = chat.jid
    let parentName = chat.name
    Task.detached(priority: .userInitiated) { [client] in
        let subs = (try? client.listSubGroups(parentJID: parentJID)) ?? []
        for sub in subs {
            do { try client.leaveGroup(jid: sub.jid) }
            catch {
                NSLog("[yawac/leaveCommunity] sub-leave failed jid=%@ err=%@",
                      sub.jid, String(describing: error))
            }
        }
        do { try client.leaveGroup(jid: parentJID) }
        catch {
            NSLog("[yawac/leaveCommunity] parent-leave failed jid=%@ err=%@",
                  parentJID, String(describing: error))
        }
        NSLog("[yawac/leaveCommunity] done parent=%@ subs=%d",
              parentName, subs.count)
    }
}
```

Per-sub error tolerance: continue with remaining sub-groups even if one IQ fails (server may have already removed the user from a sub, etc.). Parent leave fires regardless. Bridge `events.GroupInfo` updates flow back through existing handler and remove the rows from `chats[]` — no custom in-VM cleanup needed.

## Error handling

- **Pending chip on non-paired account**: chip never renders (guarded by `vm.pendingRequestsChip(for:)` admin check)
- **Sub-group enumeration fails** (`listSubGroups` throws): proceed with parent-leave only — better than nothing
- **Leave on non-existent group**: server returns error, logged, no UI feedback (matches existing single-leave behavior)
- **Selection race** (chip tapped while chat is being torn down): `pendingChatInfoSection` flag is consumed by the NEXT ChatInfoView mount; SwiftUI handles the binding gracefully

## Testing

Manual smoke only — pure UI + bridge wiring. No unit-testable pure helpers extracted.

Verify on Debug build:
1. Open a community parent with pending requests → sidebar shows chip → tap → chat opens → ChatInfoView scrolls to PENDING REQUESTS section
2. Open community parent ChatInfoView → "Leave community…" button visible (was "Leave") → tap → confirm → sidebar removes parent + all sub-groups within seconds
3. Open a non-community group → "Leave" button (unchanged behavior)
4. Verify no regression on non-admin chat opens (chip already guarded by admin check)

## File summary

| File | Action |
|---|---|
| `yawac/ViewModels/SessionViewModel.swift` | + `PendingChatInfoSection` enum + transient var |
| `yawac/Views/ChatListView.swift` | wrap pending-chip `HStack` in `Button` |
| `yawac/Views/ChatInfoView.swift` | `ScrollViewReader`, `.id("pending-requests")` on section, `.onChange` observer, parent-vs-group button split, `confirmLeaveCommunity` state, alert, `leaveCommunity()` method |
| `docs/ROADMAP.md` | flip both ☐ → ✅ under Communities gaps |

No bridge / Go / test-file changes.

## Out of scope

- **Demote community parent → plain group** — whatsmeow has no RPC (create-time only)
- **Default-subgroup unlink** — server breaks announcements channel (documented limit, yawac already hides the action)
- **Newsletter / Channels** — upstream blocker (Platform == MACOS argo decoding)
