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
- ☐ **Mute chat** — `appstate.BuildMute` available, not wired in the UI.

## Search

- ☐ **In-chat message search** (search inside the current conversation).
- ☐ **Global message search** (full-text across all chats).

## Groups

- ◐ **Group management** — create exists; missing: live participant
  add/remove/promote/demote, edit name/topic/icon.
- ☐ **Invite link / QR** — generate.
- ☐ **Group description**.
- ☐ **Mention autocomplete** when typing `@`.

## Channels / Communities

- ☐ **Newsletter / Channels** — upstream blocker: `Platform == MACOS`
  triggers `argo decoding is currently broken` (whatsmeow patch needed).
- ◐ **Communities** — parent / sub-group display done; admin actions
  missing.

## Productivity / macOS

- ☐ **Reply from native notification** (macOS notification action).
- ☐ **Spotlight / Quick Look** integration for media.
- ☐ **Export / print** conversation.
- ☐ **Per-chat mute + notification customization**.
- ☐ **Theme picker** (light / dark / auto; today: dark only).
- ☐ **Per-chat wallpaper**.
- ☐ **Keyboard-shortcut help sheet**.
- ☐ **Drafts saved per chat across restart**.

## Account / Privacy

- ☐ **Linked-devices** view + manage.
- ☐ **Privacy settings** (last seen / about / profile photo).
- ☐ **2FA** (account-level).

## Cleanup gaps (smaller)

- ☐ **AppKit mic glyph + 3 `design:.monospaced` labels don't scale** with
  Interface size — known minor when introducing the multiplier; would close
  the consistency gap.
- ☐ **`vm.chats` Equatable refresh** — currently re-filters the active
  search on any mutation; could debounce / track a version int.
- ☐ **Date / time-zone display polish** — relative-date strings, header
  formats, locale.

## Out of scope (will not do)

- Voice / video calls (companion-device protocol limit).
- Multi-account / profile switching.

---

References:
- `docs/TODO.md` — upstream limitations + known issues.
- `README.md` — current feature list (authoritative for what exists).
