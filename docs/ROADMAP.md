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

- ✅ **Full history sync settings control (F28)** (v0.9.43) —
  Settings → Account → "Full history sync" row that fires the
  F27 deep-history backfill on demand. Bridge `dispatchHistory`
  now ships `progress` (0–100), `chunk_order`, and
  `chunk_messages` alongside the existing `sync_type` +
  `conversations` payload. `SessionViewModel` carries a new
  observable `FullSyncState { inFlight, progress, chunks,
  messages }` updated by every contentful chunk
  (`INITIAL_BOOTSTRAP` / `RECENT` / `FULL` / `ON_DEMAND`); a
  60 s silence-timeout clears the in-flight flag if the phone
  goes quiet. `AccountPanel` shows the row's sublabel ticking
  (`0% • chunk 1 • 50 messages`) and renders a linear
  `ProgressView` underneath while `inFlight`. Spec at
  `docs/superpowers/specs/2026-06-09-full-history-sync-control-design.md`.

- ✅ **Deeper history sync (F25–F27)** (v0.9.42) — historical
  spread was ~3 messages per chat at pair time because yawac used
  whatsmeow's default `store.DeviceProps`. Instrumented
  `dispatchHistory` confirmed: phone shipped one
  `INITIAL_BOOTSTRAP` chunk with `progress=100` (done) containing
  621 messages across 211 chats, even though oldest_ts=2022 — the
  phone HAS the history, it just isn't asked for more. Three
  fixes:
    - **F25 (L1)** — override `store.DeviceProps` at bridge
      init() (before `whatsmeow.NewClient`): `RequireFullSync =
      true`, `FullSyncDaysLimit = 3650`, `FullSyncSizeMbLimit =
      2048`, `HistorySyncConfig.OnDemandReady = true`,
      `CompleteOnDemandReady = true`. Phone now ships
      `RECENT` chunks with `progress < 100` (multi-chunk
      delivery). Measured: 621 → 4,563 messages from the same
      account on first reconnect after fix (7.3×) without
      re-pairing.
    - **F26 (L2)** — the one-shot `historyBackfillCompleted`
      UserDefaults gate flipped on the FIRST `.historySync`
      event of any SyncType. Initial sync ships several
      content-free chunks (`PUSH_NAME` with 1000 pushnames + 0
      messages, `INITIAL_STATUS_V3` with 1 status + 0 messages).
      If one of those arrived first the gate locked
      `requestHistoryBackfillIfNeeded` off permanently. Gated
      the flag flip on `SyncType ∈ {INITIAL_BOOTSTRAP, RECENT,
      FULL, ON_DEMAND}`.
    - **F27 (L3)** — `RequestFullHistorySync` previously called
      whatsmeow's `BuildHistorySyncRequest`, which builds the
      per-chat `HISTORY_SYNC_ON_DEMAND` variant
      (`PeerDataOperationRequestType` 5, phone-capped to ~50
      messages). The account-wide deep-history variant is
      `FULL_HISTORY_SYNC_ON_DEMAND` (type 6) and whatsmeow has
      no builder for it. Now hand-construct the type-6 request
      directly with `FullHistorySyncOnDemandConfig{HistoryFromTimestamp=now,
      HistoryDurationDays=count}` plus a random `RequestID`.
      `requestHistoryBackfillIfNeeded` post-pair now fires the
      deep variant the phone actually honors.

- ✅ **Hoist per-render formatters + cache richText (F24)** (v0.9.41)
  — same pattern as F23. Allocation-heavy Foundation objects were
  rebuilt inside SwiftUI body evaluation, once per visible row
  per re-render. Lifted to process-scoped statics:
  `MessageRowStatics.linkDetector` (`NSDataDetector`),
  `MessageRowStatics.mentionRegex` (`NSRegularExpression`),
  `Linkify.detector`, `Chat.weekdayFmt` / `monthDayFmt` /
  `monthDayYearFmt` (sidebar row dates),
  `SidebarSearchHits.hitDateFmt` (global ⌘K hit dates),
  `ConversationView.lastSeenFmt` (`RelativeDateTimeFormatter`
  for the presence subtitle). Plus `MessageRow.richText` output
  now goes through `RichTextCache`
  (`NSCache<NSString, RichTextBox>`, countLimit 512) keyed by
  raw text — mention resolution + URL detection + styling
  reuses the cached `AttributedString` on subsequent renders.
  Stale-mention edge case (contact-name change before LRU
  evict shows the old name) accepted as rare in practice.

- ✅ **LanguageDetector scaled + persisted cache (F23)** (v0.9.40)
  — `LanguageDetector.detect` ran from `translatableText` on
  every visible message every body eval (SwiftUI re-renders on
  `timelineGeneration` bumps, `ThumbnailCache.revision` bumps,
  receipt updates, etc.). The prior cache had four problems:
  `countLimit = 64` evicted on chats with more visible messages
  than slots; nil "couldn't classify" results weren't cached at
  all so the recognizer re-ran on every render for those texts;
  the key was `text.hashValue` which is per-process randomized
  and has collision risk; cold launches started with an empty
  cache. Replaced with an `NSString`-keyed `NSCache` at
  countLimit 512, a sentinel string for negative results
  stored next to positives, and a disk cache at
  `~/Library/Caches/<bundle>/LanguageDetector.json` loaded
  once on first call and flushed on a 2 s debounced timer when
  new entries arrive. Re-opens of yawac now skip detection
  entirely for previously-seen text.

- ✅ **2026-06-08 audit follow-up (F17–F22)** (v0.9.39) — six
  findings from the second Codex (gpt-5.4) pass after v0.9.38
  shipped. Plan at
  `docs/superpowers/plans/2026-06-08-perf-audit-followup.md`.
    - **F17 (high)** — `MessageIndex` is `@Observable` and the
      `db: OpaquePointer?`, `canonicalizer`, `ownBareJID`,
      `bareJIDMissingAtBoot`, and `ownPushName` properties were
      auto-tracked. `distinctSendersInChat` /
      `distinctSendersGlobal` call `ensureSchemaLocked()` —
      which lazily assigns `db` on first call — during SwiftUI
      body evaluation (`ConversationFindBar` Sender chip,
      `ChatListView` Sender chip). Same trap as F14. Marked all
      five `@ObservationIgnored`; `progress` stays observable
      for the bootstrap UI.
    - **F18 (high + medium)** — `ThumbnailCache.mapImage` and
      `MapSnapshotCache.snapshot` both re-ran
      `MKMapSnapshotter` on every body eval when the previous
      attempt returned nil. Same shape as F15. Added
      `mapNegative: Set<String>` to ThumbnailCache and
      `negative: Set<String>` to MapSnapshotCache; both
      short-circuit on a previous failure.
    - **F19 (high)** — every `.historySync` event ran
      `client.listContacts()` (CGo bridge) + `resolveNames` +
      `mergeContacts` + `ingestContacts` + three reconcile
      passes + `loadBlocklist` inline on the MainActor
      event-stream consumer. Initial sync delivers a burst.
      Coalesce into a 250 ms-debounced flush owned by
      `SessionViewModel`; move `listContacts` to
      `Task.detached` so the CGo marshal/unmarshal stays off
      MainActor. Made `WAClient.listContacts` `nonisolated` to
      enable the detached call.
    - **F20 (medium)** — `persistReaction` did a SwiftData
      fetch + save per reaction event on MainActor. Routed
      through `MessageWriter.enqueueReactions` with a 50 ms
      coalesce; one save per batch. Notification gating stays
      per-event on MainActor.
    - **F21 (medium)** — `applyIncomingEdit / Revoke /
      LocalDelete / Star / MessagePin` each did a fetch + save
      per event on MainActor. Cross-device sync trickles
      dozens. Added a `MessageMutation` Sendable enum and
      `MessageWriter.enqueueMutations(_:)`; the 5 methods now
      queue + flush. `currentConversation?.applyIncoming*`
      stays on MainActor for live UI updates; sidebar preview
      refresh is batched.
    - **F22 (medium)** — `applyMediaRetry` fetched a
      `PersistedMessage`, JSON-patched the media ref, saved,
      and re-armed download logic inline on MainActor.
      SwiftData side moved to `Task.detached` with a fresh
      `ModelContext`; MainActor handles only the VM state
      update (`downloadErrors`, `downloadTasks`,
      `ensureDownloadFromHistory`) after the background save
      commits.

- ✅ **Downsample-decode at cache load (F16)** (v0.9.38) — group
  chats with three+ large photos visible at once still blinked
  after F15. Two related issues: (1) `NSImage(contentsOfFile:)`
  is lazy — CoreAnimation re-decoded the JPEG on every
  `CA::Transaction::commit`, visible as a per-scroll flash; and
  (2) full-res decode of a 12 MP phone photo is ~48 MB RGBA, so
  the cache's 64 MB image budget held only one or two entries
  and the three visible bubbles evicted each other on every
  redraw. Replaced every `NSImage(contentsOfFile:)` /
  `NSImage(data:)` call site (image bubble, sticker bubble,
  avatar, video, all four preheat paths) with
  `CGImageSourceCreateThumbnailAtIndex` plus a per-surface max
  pixel size (image / sticker / video 720 px; avatar 200 px).
  ImageIO decodes + downsamples in one pass; the resulting
  CGImage is bitmap-backed (no lazy provider) so CoreAnimation
  blits straight to the IOSurface without re-decoding. Cached
  entries shrink from ~50 MB to ~0.5–2 MB, so NSCache holds the
  whole visible window plus plenty of off-screen rows.

- ✅ **Avatar negative-cache (F15)** (v0.9.37) — `status@broadcast`
  and other chats with many distinct senders that have no profile
  picture pinned the main thread at ~750 wake/s with constant JPEG
  re-decode in the CoreAnimation commit path. Root cause: when
  `AvatarCache.ensure(jid:using:)` returned an empty URL (no
  picture on file), `ThumbnailCache.storeAvatar` saw `image ==
  nil` and returned without caching anything — so the next
  `AvatarView` body eval missed the cache, kicked another fetch,
  fetch returned nil, loop. Each loop iteration bumped the
  shared `revision` counter (eventually) and SwiftUI re-rendered
  every visible row, forcing Core Animation to re-decode every
  JPEG message thumbnail on commit. Added an
  `avatarNegative: Set<String>` that `avatarImage(forCacheKey:fetcher:)`
  short-circuits on, populated by `storeAvatar` when the fetcher
  returns nil. `invalidateAvatar` clears the negative entry too
  so a freshly-uploaded profile picture is picked up on the next
  body eval. Live smoke on `status@broadcast`: sustained wake
  rate ~750/s → ~77/s.

- ✅ **ThumbnailCache observation-loop hotfix (F14)** (v0.9.36) —
  v0.9.35 install showed 146% CPU + 1.9 GB RAM under load.
  `sample` revealed the main thread pinned in a SwiftUI
  Observation cascade:
  `GraphHost.flushTransactions → ViewBodyAccessor.updateBody →
  ObservationRegistrar.willSet → ObservationCenter.invalidate`
  on repeat. Root cause: `ThumbnailCache` is `@Observable`, but
  the four `inflight: Set<String>` properties (image, video,
  avatar, map) were plain `private var`, so the macro auto-tracked
  them. Every body eval that called `cache.image(forPath:)` etc.
  inserted into the inflight Set, fired `willSet`, invalidated
  every observer, re-evaluated the body, inserted again — runaway
  loop. Marked all four sets `@ObservationIgnored`. Sustained CPU
  drops from 146% to 0% on the same workload.

- ✅ **Bubble layout fixes (F13)** (v0.9.35) — surfaced during
  F1–F12 smoke. `MessageRow.imageBubble` /  `stickerBubble`
  used `RoundedRectangle.fill().frame(maxWidth: ..., maxHeight: ...)`
  for the cache-miss placeholder, but the fill has zero intrinsic
  size so the bubble collapsed to a thin strip with only the
  timestamp overlay visible. Switched to fixed
  `.frame(width: 240, height: 180)` (image) and `140 × 140`
  (sticker). Separately, `translatableText` wrapped each Text in
  a VStack and rendered the Translate button below; multi-line
  Text under-measured its wrapped height and SwiftUI laid the
  Translate label on top of the last visible text line (visible
  in long Russian-language reply messages). Added
  `.fixedSize(horizontal: false, vertical: true)` to every
  `baseStyle` branch so Text reports its real wrapped height;
  bumped the VStack spacing 2 → 4.

- ✅ **Video thumb cache + 4-way preheat (F11+F12)** (v0.9.34) —
  extended the F10 pattern across every remaining
  `@State NSImage?` + `.task(id:)` view.
    - **F11 (video).** `VideoThumbnailView` previously kept a
      per-instance `@State thumb` and async-loaded inside
      `.task(id: path)` — even on SHA disk-cache HIT, every
      bubble flashed a gray placeholder for one frame before the
      `NSImage` landed. `ThumbnailCache` now owns a second
      `NSCache<NSString,NSImage>` for video thumbs with
      `videoImage(forPath:)` (synchronous get) and
      `preheatVideo(_:)` (snapshot-time warm-up). The cache
      shares the existing 50 ms-coalesced revision bump.
      `VideoThumbnailView`'s body is now a pure cache read.
      `buildHistorySnapshot` ferries the last ~30 video rows'
      SHA-cached PNG `Data` (5 MB per-file cap);
      `applyHistorySnapshot` preheats before assigning
      `self.messages`.
    - **F12 (avatars, replies, shared-media, maps).** Same
      pattern existed in `AvatarView` (every chat row + every
      message row), `ReplyPreview.ReplyThumb` (every replied-to
      message), `SharedMediaCell` (chat-info media grid), and
      `MessageRow.MapSnapshotImage` (location bubbles).
      `ThumbnailCache` gained separate caches for avatars
      (countLimit 512, 16 MB) and maps (64, 32 MB), plus
      `avatarImage(forCacheKey:fetcher:)`, `invalidateAvatar`,
      `mapImage(lat:lng:)`, and `preheatAvatar(_:)`. All four
      views now read the cache directly; the per-instance
      `@State` + `.task(id:)` flicker sources are gone.
      `AvatarView` still subscribes to the existing
      `.avatarCacheInvalidated` `NotificationCenter` broadcast
      and routes it through `ThumbnailCache.invalidateAvatar`.
      `buildHistorySnapshot` additionally collects up to 60
      distinct sender-avatar disk `Data` blobs (5 MB per-file
      cap) from the last visible window;
      `applyHistorySnapshot` preheats them BEFORE the messages
      assignment.

- ✅ **Thumbnail batched revision + visible-window preheat (F10)**
  (v0.9.33) — `ThumbnailCache` previously bumped `revision &+= 1`
  per decode. A chat with N visible images triggered N row-body
  re-evals over successive frames — visible as image flicker on
  open. Now `store(path:image:)` schedules a single 50 ms-coalesced
  revision bump per burst of decodes so sub-window decodes settle
  into one re-render. Plus: `ConversationViewModel.buildHistorySnapshot`
  reads raw file `Data` for the last ~30 image/sticker rows whose
  media is on disk (per-file cap 5 MB). `applyHistorySnapshot`
  calls `ThumbnailCache.preheat(_:)` BEFORE assigning `self.messages`,
  so the `LazyVStack`'s first paint of visible image bubbles hits
  the cache synchronously instead of starting from placeholders.

- ✅ **Bottom-anchored chat scroll + smaller first slice (F9)**
  (v0.9.32) — `ConversationView`'s `LazyVStack` previously laid
  out from the top of the message array (oldest first), then a
  `DispatchQueue.main.async` scroll-to-bottom fired one runloop
  later. Users saw the oldest rows render briefly before the view
  jumped to the newest. Added `.defaultScrollAnchor(.bottom)` so
  the `LazyVStack` instantiates rows from the newest edge on
  first paint. Dropped `ConversationViewModel.historyLoadLimit`
  150 → 60 so the initial snapshot carries fewer rows for the
  `LazyVStack` to lay out; older rows page in via the existing
  `loadEarlier` path on scroll-up.

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
