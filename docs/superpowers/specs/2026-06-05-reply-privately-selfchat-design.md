# v0.8.3 — Reply-Privately + Self-Chat Smoke

**Date:** 2026-06-05
**Status:** Approved (design)
**Topic:** Add right-click → "Reply privately" on group messages
(opens DM with the sender, sets reply quote referencing the group
message). Plus a smoke pass on the self-chat surface
(`<ownJID>@s.whatsapp.net`) — confirm composer + receipts +
sidebar treatment behave correctly, with light "(You)" labeling.

## Goal

Two small WhatsApp parity gaps:

1. **Reply privately** — common WhatsApp affordance: in a group,
   right-click a message and pick "Reply privately" to DM the
   sender with the message quoted. No special wire format; just a
   UX shortcut: navigate to DM + pre-fill a reply quote.
2. **Self-chat smoke** — WhatsApp surfaces a self conversation at
   `<ownJID>@s.whatsapp.net`. yawac lists it but the composer +
   receipt path treats it as a generic 1:1. Audit + light UI tag
   ("(You)" suffix on sidebar + chat header).

## Non-goals

- Server-side "reply privately" protocol — no such wire format
  exists; this is a client UX shortcut only. Quote payload uses
  the same `ContextInfo.QuotedMessage` as regular reply but the
  destination chat is the DM.
- Multi-account self-chat (out of scope, per "Out of scope"
  section in ROADMAP).
- Migrating existing self-chat persistence — already works as a
  generic 1:1.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ MessageContextMenu (group + not-fromMe messages):            │
│   "Reply privately" → onReplyPrivately(message)              │
│                                                              │
│ ConversationView:                                            │
│   onReplyPrivately(msg) → session.requestSelectChat(         │
│     msg.senderJID) → set new CVM.replyTarget = msg           │
│                                                              │
│ Self-chat treatment:                                         │
│   Chat row name suffix " (You)" when chat.jid == ownJID      │
│   ChatHeader: same suffix                                    │
└─────────────────────────────────────────────────────────────┘
```

**No bridge changes.** Pure Swift UX feature.

## Components

### Reply-privately

`MessageRow` gains `onReplyPrivately: ((UIMessage) -> Void)?`
optional closure (mirrors existing `onReply`).

`MessageContextMenu` gains a new menu item, gated on:
- Source chat is a group (`message.chatJID.hasSuffix("@g.us")`)
- Message is NOT from me (`!message.fromMe`)

```swift
if isGroupMessage && !message.fromMe {
    Button("Reply privately to \(senderName)…") {
        dismiss()
        onReplyPrivately()
    }
}
```

`ConversationView` wires the closure:

```swift
MessageRow(
    message: m,
    // ... existing args ...
    onReplyPrivately: { msg in
        Task { @MainActor in
            // Switch to DM.
            session.requestSelectChat(msg.senderJID)
            // Brief wait for ConversationViewModel to swap.
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Set reply target on the now-active VM (it's the
            // sender's DM CVM). Wire via session.pendingReplyTarget.
            session.pendingReplyTarget = msg
        }
    }
)
```

`SessionViewModel` gains a `pendingReplyTarget: UIMessage?` —
ephemeral state; the destination `ConversationViewModel` reads
+ clears it when it boots / receives focus.

`ConversationViewModel.task` checks `session.pendingReplyTarget`
on mount; if set + matches a message we know about (or even if not,
since the quote needs only the ID), populate `replyTarget` and
clear the session pendingReplyTarget.

### Self-chat treatment

`SessionViewModel.displayName(for: chatJID)` — if `chatJID ==
ownJID`, append " (You)" to the resolved name. Or simpler: helper
`isSelfChat(_ jid: String) -> Bool` that callers use to append the
suffix at render sites.

Two render sites:
- `ChatListView` chat row name
- `ConversationView` chat header

Tradeoff: modifying `displayName` is global (all surfaces get the
suffix). Modifying just two render sites is surgical. **Pick
surgical** — `displayName` is also used in mentions, notifications
etc., where "(You)" would be wrong.

```swift
extension SessionViewModel {
    func isSelfChat(_ jid: String) -> Bool {
        guard let client else { return false }
        return JIDNormalize.same(jid, client.ownJID, client: client)
    }
}

// In ChatListView row name:
Text(chat.name + (session.isSelfChat(chat.jid) ? " (You)" : ""))

// In ConversationView header:
Text(displayName + (session.isSelfChat(chat.jid) ? " (You)" : ""))
```

Smoke verification (no code change, just manual smoke):
- Self-chat sends work (composer fires + bubble appears).
- Receipt: fromMe=true echo paints checkmarks correctly.
- Sidebar row shows "(You)" suffix.

## Error handling

| Surface | Pattern |
|---|---|
| Reply-privately: target sender JID malformed | `session.requestSelectChat` is a no-op safely. UX falls back: nothing happens. Log only. |
| Reply-privately: pendingReplyTarget stale | CVM `task` clears the session field on mount even if the message isn't found in its own history. The quote still works because we set `replyTarget` regardless (only the message ID + quote text are needed for sending). |
| Self-chat label render | None — pure string append. |

## Testing

### Swift

- `SessionViewModelSelfChatTests` (new):
  - `isSelfChat(ownJID)` → true.
  - `isSelfChat("other@s.whatsapp.net")` → false.
  - `isSelfChat("g@g.us")` → false.
  - Empty `ownJID` → false (early return).

- Extend `MessageContextMenuTests` (if exists) to assert "Reply
  privately" item appears for group + not-fromMe, hidden otherwise.

### Manual smoke

- In a group chat, right-click any inbound message → "Reply
  privately to <sender>" item appears. Click → DM with that sender
  opens, composer carries the reply quote chip referencing the
  original group message. Type text + send → recipient sees a 1:1
  message with quote.
- Right-click own group message → "Reply privately" NOT in menu.
- Right-click message in 1:1 → "Reply privately" NOT in menu.
- Sidebar self-chat row shows "(You)" suffix.
- Open self-chat → ChatHeader name shows "(You)" suffix.
- Send self-message → bubble appears with checkmark; sidebar
  preview updates.

## Files touched

**New:**

- `yawacTests/SessionViewModelSelfChatTests.swift`

**Modified:**

- `yawac/Views/MessageRow.swift` — `onReplyPrivately` closure +
  pass to MessageContextMenu.
- `yawac/Views/MessageContextMenu.swift` — new "Reply privately"
  item, gated on group + not-fromMe.
- `yawac/Views/ConversationView.swift` — wire `onReplyPrivately`
  closure.
- `yawac/ViewModels/SessionViewModel.swift` — `pendingReplyTarget:
  UIMessage?` ephemeral state, `isSelfChat(_:)` helper.
- `yawac/ViewModels/ConversationViewModel.swift` — `task` reads +
  clears `session.pendingReplyTarget`.
- `yawac/Views/ChatListView.swift` — "(You)" suffix in chat row
  name when `isSelfChat`.
- `yawac/Views/ConversationView.swift` — same suffix in chat
  header.
- `project.yml` — bump `CFBundleShortVersionString` 0.8.2 → 0.8.3,
  `CFBundleVersion` 11 → 12.
- `docs/ROADMAP.md` — strike Reply-privately + Self-chat gaps.
