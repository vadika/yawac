# Yawac — Back Button (Chat Navigation Stack) · Implementation Spec

Target: SwiftUI (macOS 14+).
Visual reference: `Yawac Redesign.html` → Tweaks → Overlays → "Drilled in (back bar)".
Depends on the `YT` design tokens from `Settings — Coding Agent Spec.md` §0.

---

## 0. The use case

A user is in a **group chat**. They tap a member's name (in the header, a message author label, or the participants list). The app navigates to that member's **1:1 chat**. A **back button** must return them to the *exact* group they came from.

This generalizes: any chat can be opened *from* another chat, any number of hops deep
(group → member → a group that member is in → another member → …). "Back" pops one hop.

**Therefore the back affordance is a navigation STACK, not a boolean "previous group".**

---

## 1. Why a labeled bar, not a bare chevron

A lone `‹` is ambiguous — the user jumped here from somewhere non-obvious, so back must **name its destination**. The control is a slim breadcrumb bar that:

- Reads **"Back to {origin name}"** with the origin's small avatar.
- Sits in its own band **above** the chat header (never crowds title/avatar/actions).
- **Only renders when there is something to go back to** (stack depth > 1).
- Shows a **"{n} deep"** chip when more than one hop deep, so the stack is legible.
- Surfaces the keyboard shortcut **⌘[**.

---

## 2. Layout & style

A horizontal bar, **34pt tall**, full width of the conversation pane, directly above the chat header.

```
+--------------------------------------------------------------+
|  ‹  Back to  (a) Ammin & Kirsin ryhmä rämä      [2 deep]  ⌘[ |
+--------------------------------------------------------------+
|  (G) Gabriel                                          🔍 ℹ   |   <- existing chat header
|      online                                                  |
```

- Background: `SettingsPalette.sidebarBg`. Bottom border: 1pt `SettingsPalette.border`.
- Padding: leading 12pt, trailing 14pt.
- **Back button** (the tappable group):
  - `HStack(spacing: 7)`: chevron-left (12pt semibold) · "Back to" (`.secondary`) · 16pt origin avatar · origin name (semibold, `.primary`, `lineLimit(1)`, truncate tail).
  - Text color `SettingsPalette.accentText`; 12.5pt medium.
  - Padding: leading 4, trailing 8, vertical 4; 7pt corner radius.
  - **Hover**: background `SettingsPalette.accentSoft`.
  - Max width ~70% so a long origin name truncates instead of shoving the rest off.
- **Depth chip** (only when `depth > 1`): "{n} deep", 10pt SF Mono semibold, `SettingsPalette.textFaint`, 1pt `SettingsPalette.border` outline, 4pt radius.
- `Spacer()`.
- **Shortcut hint**: "⌘[", 10.5pt SF Mono, `SettingsPalette.textFaint`, 1pt `SettingsPalette.border` outline, 4pt radius.

---

## 3. Navigation model

Drive everything from a stack. Do **not** store a single "previousChat".

```swift
struct ChatRef: Identifiable, Equatable {
    let id: String              // JID
    let displayName: String     // resolved name — never a raw JID
    let avatar: AvatarSpec
    let kind: Kind              // .group or .direct
    enum Kind { case group, direct }
}

@Observable final class ChatNavigation {
    private(set) var stack: [ChatRef] = []

    var current: ChatRef? { stack.last }
    /// The chat "back" returns to — the entry below the top of the stack.
    var origin:  ChatRef? { stack.count > 1 ? stack[stack.count - 2] : nil }
    var depth:   Int      { max(0, stack.count - 1) }

    /// Open a chat fresh from the sidebar — resets the trail.
    func openRoot(_ chat: ChatRef) { stack = [chat] }

    /// Drill into a chat FROM the current one (tapping a member, etc.).
    func push(_ chat: ChatRef) {
        guard current?.id != chat.id else { return }   // don't push self
        stack.append(chat)
    }

    /// Pop one hop. No-op at the root.
    func back() { if stack.count > 1 { stack.removeLast() } }
}
```

### Triggers that `push`
- Tapping a member's name in the **chat header** (when it's a 1:1 you opened, or a group title that links elsewhere).
- Tapping a **message author** label inside a group.
- Tapping a row in the **participants** list of the Group Info panel.
- Tapping a **"groups in common"** row in the User Info panel.

### Triggers that `openRoot` (reset trail)
- Selecting any conversation from the **sidebar list**.
- Opening a chat from **search** results.

---

## 4. Wiring

```swift
// Above the chat header, inside the conversation pane:
if let origin = nav.origin {
    BackBar(originName: origin.displayName,
            originAvatar: origin.avatar,
            depth: nav.depth,
            onBack: nav.back)
        .transition(.move(edge: .top).combined(with: .opacity))
}

ChatHeader(chat: nav.current)   // header subject = top of stack
```

```swift
// Keyboard back — standard macOS:
.onKeyPress(.init("["), modifiers: .command) { nav.back(); return .handled }
```

Optional: also map the mouse **back button** (`NSEvent` button 3) and a two-finger swipe-right to `nav.back()`.

---

## 5. Behaviors

- Show the bar **iff `nav.origin != nil`**. At the root chat there is no bar.
- `depth` chip appears only when `depth > 1`.
- Animate the bar in/out from the top (move + fade, ~180ms). Respect Reduce Motion (no animation).
- The header **subject swaps** to `nav.current` — when drilled into Gabriel, the header shows "Gabriel · online", not the group. This proves navigation happened.
- Origin name in the bar must be the **resolved display name** (contact name, else formatted phone) — never a raw JID/LID.
- Back must restore the origin chat's **prior scroll position** (cache scroll offset per `ChatRef.id` when pushing).
- Pressing back repeatedly walks the whole trail down to the root, then stops.

---

## 6. Don'ts
- NO bare unlabeled chevron — the destination name is the whole point.
- NO single "previousChat" variable — chaining hops must each be reversible (use the stack).
- Don't push the same chat onto itself (tapping your own name = no-op).
- Don't show the bar for root chats opened from the sidebar.
- Don't display raw JIDs in the bar.
- Don't let the origin name push the depth chip / shortcut off-screen — truncate it.

---

## 7. Test cases
- Group → tap member → lands on member 1:1, bar reads "Back to {group}", depth chip hidden.
- Member 1:1 → tap a "group in common" → bar reads "Back to {member}", chip shows "2 deep".
- Press ⌘[ twice from 2-deep → returns to member, then to group, bar disappears at root.
- Open any chat from the sidebar while 3-deep → trail resets, no bar.
- Long origin name ("Vadim's group EPKY camp 2026") → truncates with ellipsis, ⌘[ stays visible.
- Reduce Motion on → bar appears/disappears instantly.
- Back restores the exact scroll position you left the origin at.
