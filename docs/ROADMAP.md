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
- ✅ **Polls — create** — composer paperclip menu opens a sheet
  (question + 2–12 options + multi-select toggle); bridge wraps
  `BuildPollCreation` + `SendMessage`; optimistic bubble + persistence
  via existing `PersistedMessage.pollJSON`. Shipped 2026-06-02.
- ◐ **Stickers** — incoming render works; need pack browsing + send from
  pack.
- ✅ **Location sharing** — static MapKit picker (search + current
  location + drag pin) shipped in v0.8.0. Inbound LiveLocation
  renders with last known coord + "LIVE" badge. Live-location send
  remains deferred.
- ✅ **Contact-card share (vCard)** — WhatsApp-formatted vCard with
  `waid` extension parameter so recipients see a tappable "Message on
  WhatsApp" affordance. Single-contact only; macOS Contacts.app
  integration deferred. Shipped in v0.8.0.
- ✅ **Disappearing messages — outbound** — chat-level timer (off /
  24h / 7d / 90d) set from ChatInfoView; outgoing messages wrap in
  `EphemeralMessage`. Shipped in v0.8.0. (whatsmeow does NOT
  auto-wrap; yawac wraps explicitly.)
- ✅ **View-once enforce** — incoming view-once reveal once, then
  locks + deletes the on-disk media; outbound per-attachment toggle
  on image/video chips. Shipped in v0.8.0.
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

- ✅ **Group management** — edit name + edit description
  (admin-only) shipped in v0.4.0; live participant add (contacts +
  +phone fallback with `AddRequest` privacy-block surfacing) /
  remove / promote / demote and avatar edit (with crop sheet)
  shipped 2026-06-02. **New group creation** (sidebar `+` menu)
  shipped in v0.7.1 — composer + multi-select participant picker
  hits `WAClient.createGroup`.
- ✅ **Invite link / QR** — generate, copy, share, admin-only revoke
  with cooldown; ⌘K paste-to-join with preview + pending-approval
  state. Shipped 2026-06-02.
- ✅ **Mention autocomplete** — strip above composer with participants +
  `@everyone`; ↑↓/Tab/Enter/Esc; encodes `ContextInfo.MentionedJID`
  on send + edit. Shipped in v0.3.0.

## Channels / Communities

- ☐ **Newsletter / Channels** — upstream blocker: `Platform == MACOS`
  triggers `argo decoding is currently broken` (whatsmeow patch needed).
- ✅ **Communities** — parent / sub-group display + directory +
  best-effort join shipped earlier; admin actions (link / unlink
  sub-groups, approve / reject join requests with sidebar pending
  chip, "require admin approval to join" toggle) and create-new-
  community / create-new-sub-group flows shipped in v0.7.1.
  Approval-mode toggle is gated server-side to community parents
  and standalone non-community groups — community sub-groups
  inherit from the parent and reject `SetGroupJoinApprovalMode`
  with `400 bad-request`. Pending-request count refresh is bounded
  by foreground polling (whatsmeow does not emit an inbound
  `JoinRequest` event).

## Productivity / macOS

- ☐ **Reply from native notification** (macOS notification action).
- ☐ **Spotlight / Quick Look** integration for media.
- ☐ **Export / print** conversation.
- ☐ **Per-chat mute + notification customization**.
- ☐ **Theme picker** (light / dark / auto; today: dark only).
- ☐ **Per-chat wallpaper**.
- ✅ **Keyboard-shortcut help sheet** — ⌘? opens a sheet listing
  shortcuts in Compose / Find / Messages / App sections.
- ✅ **Drafts saved per chat across restart** — `PersistedChat.draft`
  with debounced 500 ms save on every `vm.draft` change, restored on
  chat open. Shipped in v0.5.0 (commit `1fe6b8f`).

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
