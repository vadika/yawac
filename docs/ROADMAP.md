# yawac Roadmap

Inventory of missing features and known gaps, derived from a survey of the
current README features, `docs/TODO.md` known limitations, and a comparison
against the WhatsApp baseline. Each item is a candidate for a future
brainstorm → spec → plan cycle.

Status legend: ☐ not started · ◐ partial · ✅ done · ⊘ dropped.

Split: **Important** (primitives, admin, privacy, productivity) drives the
next planning cycles. **Low-priority** (cosmetics, decorative pickers,
rare-use utilities) ships only when the important list is clear.

---

# Important

## Communication

- ☐ **Status / Stories** — view + post (whatsmeow supports).
- ◐ **Polls** — create + vote shipped; tallies + voter-by-option render
  in the bubble.
  Gaps:
    - ☐ Cross-device own-vote re-render from `HistoricalPollVote`
      event (after history sync the user's own selection may show
      empty until they vote again).
    - ☐ Anonymous polls — whatsmeow exposes no toggle; spec unclear
      if WhatsApp protocol supports it for mobile clients.
- ◐ **Location sharing** — static MapKit picker (search + current
  location via delegate one-shot) shipped in v0.8.0. Inbound
  LiveLocation renders with last known coord + "LIVE" badge.
  Gaps:
    - ☐ Live-location SEND (CoreLocation continuous updates +
      LiveLocationMessage protocol). Receive-only today.
    - ☐ Pin-drag re-geocode — model has `onPinDrag(to:)` wired but
      the legacy `MapAnnotation` API doesn't expose drag; needs a
      switch to the new `Map { Annotation { ... } }` shape.
- ◐ **Contact-card share (vCard)** — WhatsApp-formatted vCard with
  `waid` extension parameter, tappable "Message on WhatsApp"
  recipient action. Single-contact only. Shipped in v0.8.0.
  Gaps:
    - ☐ Multi-contact share (`ContactsArrayMessage`).
    - ☐ macOS Contacts.app source via `CNContactPickerViewController`
      (WA-contacts only today).
    - ☐ Inbound contacts missing the `waid` param (non-WA exports)
      render without the "Message on WhatsApp" button. Document only.
- ◐ **Disappearing messages — outbound** — chat-level timer (off /
  24h / 7d / 90d) set from ChatInfoView; outgoing wraps in
  `EphemeralMessage`. 1:1 hydration via inbound
  `ProtocolMessage{EPHEMERAL_SETTING}` carriers OR
  `ContextInfo.Expiration` on any regular inbound message (v0.8.0
  fix). Shipped in v0.8.0.
  Gaps:
    **v0.8.1 fix:** reply / edit / forward / reaction / poll-vote
    now wrap in `EphemeralMessage` per the chat's timer (edit accepts
    the param but defers to WhatsApp's edit-inherits-original
    convention). 1:1 cold-read worked around via an on-demand
    history backfill on first v0.8.1 boot.
- ◐ **View-once enforce** — incoming view-once renders "Tap to reveal"
  → reveals media once → locks + deletes on-disk file; outbound
  per-attachment toggle on image/video chips. `viewOnceLocked`
  survives scroll + restart. Shipped in v0.8.0.
  Gaps:
    **v0.8.1 fix:** one-shot history backfill on first boot re-flows
    pre-v0.8.0 image/video payloads through the v0.8.0 classifier,
    re-flagging them with `isViewOnce`.
    - ☐ Forward / Quote already hidden from context menu, but
      screenshot / copy-image is uncatchable. Same posture as
      WhatsApp; document only.

## Search

- ● **In-chat message search** — ⌘F find bar with ↑/↓ navigation,
  highlights, locale-aware tokenizer (FTS5). v0.8.4 added chip-strip
  filters for sender, kind, and date range (Today / Last 7 / 30 /
  90 / Custom…). Sender filter is JID-based (stable across
  push-name changes) since v0.9.4.
- ● **Global message search** — sidebar `⌘K` Messages section,
  tap-to-jump with brief flash highlight. v0.8.4 added chip-strip
  filters for chat, sender, kind, and date range. v0.9.9 fixed the
  hit-click → chat-swap + scroll-to-message race so the jump
  fires reliably across same-chat and cross-chat hits.

    **FTS schema saga (v0.9.2–v0.9.7):** `MessageFTS` schema went
    v2 → v5 to settle the Sender filter:
    - v0.9.2: filter-only search (empty query + chips returns hits;
      adds row count to the find bar).
    - v0.9.3: cache the paired account's own push name so own
      outbound rows get a non-empty `sender` value.
    - v0.9.4: add `sender_jid` UNINDEXED column; filter matches on
      JID so push-name changes don't fragment chip values.
    - v0.9.5–v0.9.6: canonicalize sender JIDs (LID → PN) and force
      a re-bootstrap on the first `.connected` after the initial
      bootstrap walk, since the setters arrive too late for the
      app-init pass.
    - v0.9.7: chip writes JID into `filters.sender` (was display
      name); label still resolves via the availableSenders lookup.

## Groups

- ◐ **Group management** — edit name + edit description (admin-only)
  shipped in v0.4.0; live participant add (contacts + +phone fallback
  with `AddRequest` privacy-block surfacing) / remove / promote /
  demote and avatar edit (with crop sheet) shipped 2026-06-02.
  **New group creation** (sidebar `+` menu) shipped in v0.7.1.
  Announce-mode + edit-info lock + member-add mode shipped in v0.8.2
  and v0.9.8 (see Shipped section).
  Gaps:
    - ☐ **Promote plain group → community parent** — whatsmeow's
      `CreateGroup{IsParent:true}` is create-time only. Post-hoc
      conversion isn't exposed upstream.
    - ☐ **Group "deletion"** — WhatsApp protocol has no destroy
      primitive. Members leave; group persists server-side until the
      last member is gone. Local `deleteChat` removes the row from
      the sidebar + cross-device-syncs the deletion (shipped); no
      true delete on the wire.

## Channels / Communities

- ☐ **Newsletter / Channels** — upstream blocker: `Platform == MACOS`
  triggers `argo decoding is currently broken` (whatsmeow patch needed).
- ◐ **Communities** — parent / sub-group display + directory +
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
  Gaps:
    - ☐ **Leave community** — multi-step "leave all sub-groups +
      leave parent" workflow. Today user leaves each sub-group +
      parent individually via Leave group on each chat info.
    - ☐ **Demote community parent → plain group** — whatsmeow has no
      RPC to undo `IsParent`; create-time only.
    - ☐ **Approve from sidebar chip tap** — sidebar pending-count
      chip is read-only; tapping doesn't jump to the PENDING
      REQUESTS section. Tap currently opens the chat as normal.
    - ☐ **Default-subgroup unlink** — server allows the IQ but it
      breaks the community's announcements channel. yawac hides the
      Unlink action for `isDefaultSubGroup` rows. No "delete
      community" workflow.

## Productivity / macOS

- ☐ **Reply from native notification** — UNNotificationAction with
  text-input on incoming banners; send-back via existing
  `sendText`. Modest plumbing — ~150 LoC.
- ☐ **Per-chat mute + notification customization** — extend
  existing mute (8h / 1w / Always) with custom durations + bell /
  sound toggles per chat. Touches sidebar ctx menu + ChatInfoView.
- ☐ **Wire cosmetic Settings toggles** (v0.9.13 follow-up) — the
  General + Display panels render the controls but the storage
  keys aren't read anywhere yet. Needs real wiring:
    - `yawac.launchAtLogin` → `SMAppService.mainApp.register()`
    - `yawac.menuBar.show` → `NSStatusItem` create / hide
    - `yawac.dock.keep` → `NSApp.setActivationPolicy(.regular | .accessory)`
    - `yawac.notifications.{enabled,preview,sound}` →
      `NotificationService` payload customization
    - `yawac.accentColor` → swap `Theme.accent` at render time
    - `yawac.translate.auto` → already-existing translation flow
      consumer.

## Account / Privacy

- ☐ **Push-name edit** — About + avatar shipped (v0.9.0 / v0.9.1,
  see Shipped). Push name (display name) is the only remaining
  profile field — whatsmeow has no top-level setter, so a
  `SETTING_PUSHNAME` app-state patch is needed. Phone-only for now.
- ☐ **2FA** (account-level).

## Messaging gaps (against shipped surface)

- ☐ **Cross-device-sync own outbound edits / reactions** — edits + own
  reactions made on the phone don't always re-merge into yawac's
  bubble without a fresh history sync.

> Reply-privately + self-chat "(You)" suffix shipped in v0.8.3 —
> see Shipped section.

---

# Low-priority

Cosmetics, decorative pickers, rare-use utilities. Ship only when
the important list is materially shorter.

- ◐ **Stickers** — incoming render works; bridge `SendImage`-style
  outbound send wired for the sticker `*.webp` payload, but no UI
  to pick / send from a sticker pack. Gaps: pack browser +
  tap-to-send + recents / favorites.
- ☐ **GIF picker** (tenor / giphy).
- ☐ **Per-chat wallpaper**.
- ☐ **Theme picker** (light / dark / auto; today: dark only).
- ☐ **Spotlight / Quick Look** integration for media.
- ☐ **Export / print** conversation.

---

# Shipped (✅)

Kept here for context — flip back to open only if a regression
surfaces.

- ✅ **CVM ingest coalesce + Set dedupe (F8)** (v0.9.31) —
  follow-up to the F1–F7 audit. `ConversationViewModel.ingest`
  previously ran per-event: O(n) `messages.contains(where:)` +
  per-event `messages.append` + `invalidateTimeline()`. Bursts
  during history-sync / reconnect drains painted the open chat
  one message at a time. Now mirrors the F3 ChatList pattern:
  50 ms flush window, single batched `messages.append(contentsOf:)`,
  single `invalidateTimeline()`. Dedupe goes through a
  `Set<String>` mirror of message ids (O(1) lookup; maintained
  at all ~21 `messages.append/.insert` sites + rebuilt after
  wholesale assignments in `applyHistorySnapshot` and
  `loadEarlier`). Queue-side dedupe uses a separate
  `pendingIngestIDs: Set<String>` so a 100-event burst stays
  O(N) overall, not O(N²). `deinit` cancels any pending flush
  task so a chat-switch mid-window doesn't leave 50 ms of dead
  sleep around.

- ✅ **Performance audit landings F1–F7** (v0.9.30) — Codex
  (gpt-5.4) audit findings sequenced as plan +
  subagent-driven execution. Plan at
  `docs/superpowers/plans/2026-06-07-perf-audit-fixes.md`.
    - **F1 (critical)** — `WAClient` event pump moved off
      `MainActor`. Detached background `Task` decodes + fans out;
      `subscribers` dict guarded by serial `DispatchQueue` with
      snapshot-and-yield to avoid `onTermination` re-entry.
      Sustained wake rate dropped from ~792/s to ~70-100/s in
      live smoke.
    - **F2 (high)** — `ConversationViewModel.loadHistory` /
      `loadEarlier` build a `Sendable`
      `ConversationHistorySnapshot` on a detached `Task` with a
      fresh background `ModelContext`. `applyHistorySnapshot`
      commits on `MainActor` and merges late arrivals (id-set
      union) so `ingest()` rows during the build window aren't
      clobbered.
    - **F3 (high)** — New `actor MessageWriter` owns a background
      `ModelContext`. `ingest` coalesces a 50 ms window; one
      `context.save()` per batch instead of per row. Save errors
      now logged (no longer silent).
    - **F4 (high)** — `ThumbnailCache` (`NSCache<NSString,
      NSImage>`, 256 entries / 64 MB) replaces inline
      `NSImage(contentsOfFile:)` in `MessageRow.imageBubble` /
      `stickerBubble`. Body reads cache; misses kick a detached
      decode + observable `revision` bump.
    - **F5 (high)** — `ChatListViewModel.init` defers the cold-
      start sweep. `buildBootstrap` runs `SQLiteDedupe` +
      `FetchDescriptor<PersistedChat>` on a detached `Task`;
      sidebar shows a `ProgressView` while
      `bootstrapping == true && chats.isEmpty`. Unique-key
      rebinds round-tripped through the main context to avoid
      SwiftData's silent-drop-on-background quirk.
    - **F6 (medium)** — `MessageIndex.forceRebootstrap` gated on
      a `{canonicalVersion, ownPushName, ownBareJID}` fingerprint
      persisted in `UserDefaults`. Skips the full FTS wipe on
      every `.connected` when inputs are unchanged.
    - **F7 (medium)** — `ConversationView` reads
      `vm.timeline()` from a cached `[TimelineItem]` keyed by an
      observable `timelineGeneration` counter. ~28
      `invalidateTimeline()` call sites cover every observable
      mutation. `messageRevisionToken` is now an O(1) Int read.
    - Codex audit blocker fix: `OpusVoicePlayer.swift` /
      `OggOpusDemuxer.swift` were created in v0.9.29 but never
      regenerated into `yawac.xcodeproj` because pbxproj is
      gitignored and `xcodegen generate` was never re-run. Fixed
      by re-running XcodeGen as part of the perf branch build.

- ✅ **Chat navigation stack + BackBar** (v0.9.14 → v0.9.17) —
  drilling into a chat from another chat (member tap, participant
  row, reply-privately, community sub-group, mention popover,
  quoted-message author) pushes onto a `ChatNavigation` stack. A
  34pt BackBar reads "Back to {origin name}" with the origin's
  16pt avatar, shows a "{n} deep" chip when the trail is more
  than one hop, and surfaces ⌘[. Sidebar selection and search-hit
  jumps reset the trail (openRoot). Origin name resolves via
  `session.displayName` — never a raw JID. Last-seen message id is
  captured per chat and replayed as the initial scroll anchor on
  back-pop. Reduce Motion suppresses the slide+fade. Spec at
  `docs/superpowers/specs/2026-06-06-chat-navigation-stack-spec.md`.

    **Bring-up saga (v0.9.15 → v0.9.17):**
    - v0.9.15: bind echo loop — drill swapped `currentJID`,
      NavigationSplitView wrote the new value back through the
      sidebar binding → `openRoot` truncated the stack. Added an
      `if new == currentJID { return }` guard.
    - v0.9.16: not enough — the guard fired but the sidebar was
      still pointed at `nav.currentJID`. When drill changed
      `currentJID`, NavigationSplitView still wrote *something*
      back. Switched sidebar to `nav.stack.first?.id` so it
      tracks the root, not the drilled chat.
    - v0.9.17: layout fix. Stack/observation/render all worked;
      BackBar was just invisible behind the title-bar lozenge
      because `.ignoresSafeArea(.container, edges: .top)` parked
      `headerBar` over the title-bar gutter. Moved BackBar below
      `headerBar` instead of above. Slight spec deviation from
      "directly above the chat header" — keeps it visible.

- ✅ **Settings redesign** (v0.9.13) — `SettingsView` rewritten as
  a 200pt rail + content pane (`NavigationSplitView`), six panels
  (General, Display, Translation, Privacy, Blocked, Account) per
  Claude Design handoff spec
  (`docs/superpowers/specs/2026-06-06-settings-redesign-spec.md`).
  Reusable Card / Row / SectionLabel / Select / Segmented / Pill
  components in `Views/Settings/`. `SettingsPalette` graphite
  tokens. Blocked list resolves display names + formatted phones,
  never raw JIDs. Privacy + Linked devices modals still reachable
  from the Account panel.
  Gaps:
    - ☐ Cosmetic-only toggles (Launch at login, menu bar, dock,
      notifications, accent color, translate-auto) — UI shipped,
      behavior wiring pending. See **Wire cosmetic Settings
      toggles** under Productivity / macOS.
    - ☐ `hiddenInset` title-bar style (traffic lights overlay rail
      top 44pt) — needs a `WindowGroup` modifier outside
      `SettingsView`; cosmetic only.
    - ☐ `UIScaleStep.compact` no longer reachable from the new
      Display panel (segmented S/M/L/XL maps to the other four).
      `from(_:)` rounds to S, so legacy stored values still
      display sensibly. Either remove `.compact` from the enum or
      restore a fifth pill.
- ✅ **Privacy settings** (v0.9.12) — Settings → Privacy sheet
  with 5 toggles: Last seen & Online, Profile photo, About, Read
  receipts, Add me to groups. Three-way Everyone / My contacts /
  Nobody for all except Read receipts (On / Off — whatsmeow rejects
  "contacts" for that one). Optimistic flip with revert-on-failure
  per row. Backed by `GetPrivacySettings` / `SetPrivacySetting`.
- ✅ **Linked-devices view** (v0.9.11) — Settings → Linked devices
  sheet lists every device paired to the WhatsApp account
  (`GetUserDevices` against own JID). yawac is flagged "THIS
  DEVICE". Remote revoke isn't exposed by whatsmeow (phone-only);
  sheet documents that and offers a self-only "Sign out of this
  device" action that calls existing `logout`.
  Gaps:
    - ☐ **Per-device platform / OS / last-active** — current rows
      show only the device JID + numeric slot. Server's
      `<iq xmlns="md"><list></list></iq>` response carries
      `platform` / `last_active` / `key_index` per `<device>`
      child, but `whatsmeow`'s `parseDeviceList` drops the extra
      attrs and `sendIQ` is unexported. Enrichment needs a
      `vadika/whatsmeow` fork patch (public `SendCustomIQ`
      wrapper *or* richer parse) + bridge + UI. Deferred to v1.x.
- ✅ **Voice-note waveform render (inbound)** (v0.9.10) — inbound
  bubbles now paint a 64-bar WhatsApp-style amplitude view backed
  by the `AudioMessage.Waveform` proto field. Playhead colors the
  played portion in `Theme.accent`; unplayed in `Theme.textMuted`.
  Older messages without waveform bytes fall back to the plain
  progress bar.
- ✅ **Group admin polish** (v0.8.2) — `SetGroupAnnounce` /
  `SetGroupLocked` toggles in ChatInfoView; ComposerView hides
  input for non-admins in announce-mode groups. Super-admin badge
  rendered with `Theme.superRole` purple.
- ✅ **Reply-privately + self-chat (You) label** (v0.8.3) — group
  ctx menu "Reply privately…" routes to DM with quote handoff;
  "(You)" suffix on sidebar + chat header for `<ownJID>@s.whatsapp.net`.
- ✅ **Search filters** (v0.8.4) — sender / kind / date / chat
  chips in ⌘F + ⌘K. Schema migrations v2 → v5 with JID-based
  sender filter, canonical LID→PN, filter-only path. See Search
  section above for the full saga.
- ✅ **Own profile edit (About + avatar)** (v0.9.0 → v0.9.1) —
  About editor + avatar pencil overlay live in the User Info pane
  (self-chat ChatInfoView), reusing the group-avatar
  AvatarCropSheet flow. Push name remains phone-only (no
  whatsmeow top-level setter; would need a
  `SETTING_PUSHNAME` app-state patch). Tracked separately under
  Account / Privacy.
- ✅ **Members can add new members** (v0.9.8) —
  `SetGroupMemberAddMode` toggle in ChatInfoView lets admins
  switch between `admin_add` and `all_member_add`.
- ✅ **Mute chat** — 8h/1w/Always submenu in sidebar + header context
  menus; bell-slash badge + dimmed unread chip; banner/dock/reaction
  suppression; @-mention pierce; cross-device sync via events.Mute +
  cold-start reconcile. Shipped post-v0.3.0.
- ✅ **Invite link / QR** — generate, copy, share, admin-only revoke
  with cooldown; ⌘K paste-to-join with preview + pending-approval
  state. Shipped 2026-06-02.
- ✅ **Mention autocomplete** — strip above composer with participants +
  `@everyone`; ↑↓/Tab/Enter/Esc; encodes `ContextInfo.MentionedJID`
  on send + edit. Shipped in v0.3.0.
- ✅ **Keyboard-shortcut help sheet** — ⌘? opens a sheet listing
  shortcuts in Compose / Find / Messages / App sections.
- ✅ **Drafts saved per chat across restart** — `PersistedChat.draft`
  with debounced 500 ms save on every `vm.draft` change, restored on
  chat open. Shipped in v0.5.0 (commit `1fe6b8f`).
- ✅ **AppKit mic glyph + 3 `design:.monospaced` labels don't scale** —
  shipped in v0.2.1 (commits `a412997`, `5ce07c7`, `c99361e`).
- ✅ **Date / time-zone display polish** — shipped in v0.2.1 (commit
  `46c6b55`): localized "Yesterday", year on dates ≥ 180 days, locale-aware
  12/24h time.
- ⊘ **`vm.chats` Equatable refresh** — dropped. Current `.onChange(of:
  vm.chats)` is required for delete → tombstone to reach active-search
  results; sub-key would regress the fix in `761c746`. See
  `docs/superpowers/specs/2026-05-30-cleanup-scale-and-date-design.md`.

---

# Out of scope (will not do)

- **Voice / video calls** — companion-device protocol limit.
- **Multi-account / profile switching**.

---

References:
- `docs/TODO.md` — upstream limitations + known issues.
- `README.md` — current feature list (authoritative for what exists).
