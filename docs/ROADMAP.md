# yawac Roadmap

Inventory of missing features and known gaps, derived from a survey of the
current README features, `docs/TODO.md` known limitations, and a comparison
against the WhatsApp baseline. Each item is a candidate for a future
brainstorm → spec → plan cycle.

Status legend: ☐ not started · ◐ partial · ✅ done (kept here only when
relevant context lingers).

## Communication

- ☐ **Status / Stories** — view + post (whatsmeow supports).
- ☐ **Calls** — voice/video. Out of scope (companion-device limit).
- ☐ **Polls — create** (voting already works); whatsmeow `BuildPollCreation`
  exists with the documented `selectableOptionCount` clamp gotcha.
- ◐ **Stickers** — incoming render works; need pack browsing + send from
  pack.
- ☐ **Location sharing** — current + live.
- ☐ **Contact-card share** (vCard).
- ☐ **Disappearing messages** — outbound (whatsmeow does NOT auto-wrap in
  `EphemeralMessage`; yawac must wrap explicitly).
- ☐ **View-once** — enforce "viewed" state (whatsmeow returns full payload).
- ☐ **GIF picker** (tenor / giphy).
- ✅ **Mute chat** — 8h/1w/Always submenu in sidebar + header context
  menus; bell-slash badge + dimmed unread chip; banner/dock/reaction
  suppression; @-mention pierce; cross-device sync via events.Mute +
  cold-start reconcile. Shipped post-v0.3.0.

## Search

- ✅ **In-chat message search** — ⌘F find bar with ↑/↓ navigation,
  highlights, locale-aware tokenizer (FTS5).
- ✅ **Global message search** — sidebar `⌘K` Messages section, tap-to-jump
  with brief flash highlight.

## Groups

- ✅ **Group management** — create + edit name + edit description
  (admin-only) shipped in v0.4.0; live participant add (contacts +
  +phone fallback with `AddRequest` privacy-block surfacing) /
  remove / promote / demote and avatar edit (with crop sheet)
  shipped 2026-06-02.
- ✅ **Invite link / QR** — generate, copy, share, admin-only revoke
  with cooldown; ⌘K paste-to-join with preview + pending-approval
  state. Shipped 2026-06-02.
- ✅ **Mention autocomplete** — strip above composer with participants +
  `@everyone`; ↑↓/Tab/Enter/Esc; encodes `ContextInfo.MentionedJID`
  on send + edit. Shipped in v0.3.0.

## Channels / Communities

- ☐ **Newsletter / Channels** — upstream blocker: `Platform == MACOS`
  triggers `argo decoding is currently broken` (whatsmeow patch needed).
- ◐ **Communities** — parent / sub-group display done; sub-group
  directory + best-effort join (via invite link, surfaces
  approval-pending state) shipped. Missing: admin actions
  (link/unlink sub-groups, approve member requests).

## Productivity / macOS

- ☐ **Reply from native notification** (macOS notification action).
- ☐ **Spotlight / Quick Look** integration for media.
- ☐ **Export / print** conversation.
- ☐ **Per-chat mute + notification customization**.
- ☐ **Theme picker** (light / dark / auto; today: dark only).
- ☐ **Per-chat wallpaper**.
- ✅ **Keyboard-shortcut help sheet** — ⌘? opens a sheet listing
  shortcuts in Compose / Find / Messages / App sections.
- ☐ **Drafts saved per chat across restart**.

## Account / Privacy

- ☐ **Linked-devices** view + manage.
- ☐ **Privacy settings** (last seen / about / profile photo).
- ☐ **2FA** (account-level).

## Cleanup gaps (smaller)

- ✅ **AppKit mic glyph + 3 `design:.monospaced` labels don't scale** —
  shipped in v0.2.1 (commits `a412997`, `5ce07c7`, `c99361e`).
- ⊘ **`vm.chats` Equatable refresh** — dropped. Current `.onChange(of:
  vm.chats)` is required for delete → tombstone to reach active-search
  results; sub-key would regress the fix in `761c746`. See
  `docs/superpowers/specs/2026-05-30-cleanup-scale-and-date-design.md`.
- ✅ **Date / time-zone display polish** — shipped in v0.2.1 (commit
  `46c6b55`): localized "Yesterday", year on dates ≥ 180 days, locale-aware
  12/24h time.

## Out of scope (will not do)

- Voice / video calls (companion-device protocol limit).
- Multi-account / profile switching.

---

References:
- `docs/TODO.md` — upstream limitations + known issues.
- `README.md` — current feature list (authoritative for what exists).
