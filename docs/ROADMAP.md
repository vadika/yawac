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
    - ✅ Cross-device own-vote re-render from `HistoricalPollVote`
      event — landed as F90 in v0.10.18.
    - ☐ Anonymous polls — whatsmeow exposes no toggle; spec unclear
      if WhatsApp protocol supports it for mobile clients.
- ◐ **Location sharing** — static MapKit picker (search + current
  location via delegate one-shot) shipped in v0.8.0. Inbound
  LiveLocation renders with last known coord + "LIVE" badge.
  Gaps:
    - ☐ Live-location SEND (CoreLocation continuous updates +
      LiveLocationMessage protocol). Receive-only today.
    - ✅ Pin-drag re-geocode — tap-to-move pin via the new
      `MapReader { Map(position:) { Annotation } }` shape landed in
      v0.10.35 as F103.
- ◐ **Contact-card share (vCard)** — WhatsApp-formatted vCard with
  `waid` extension parameter, tappable "Message on WhatsApp"
  recipient action. Single-contact only. Shipped in v0.8.0.
  Gaps:
    - ✅ Multi-contact share (`ContactsArrayMessage`) — picker is
      now a checkbox list; ≥2 selections fire one
      `SendContactsArray` and render as a single multi-card bubble.
      Landed in v0.10.35 as F104.
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
    - ✅ **Leave community** — landed as F98 in v0.10.32.
    - ☐ **Demote community parent → plain group** — whatsmeow has no
      RPC to undo `IsParent`; create-time only.
    - ✅ **Approve from sidebar chip tap** — landed as F98 in v0.10.32.
    - ☐ **Default-subgroup unlink** — server allows the IQ but it
      breaks the community's announcements channel. yawac hides the
      Unlink action for `isDefaultSubGroup` rows. No "delete
      community" workflow.

## Productivity / macOS

- ✅ **Reply from native notification** — shipped as F64 in v0.10.5.
- ✅ **Per-chat mute + notification customization** — shipped as F74 in v0.10.6.
- ☐ **Per-chat notification rules beyond mute / unmute** —
  custom sound per chat, banner-vs-alert style, "show preview"
  per chat, VIP chats that bypass do-not-disturb, quiet-hours
  windows. Builds on the same plumbing as the mute customization
  row above. Privacy-conscious UX win — the official app has
  none of this.
- ✅ **Shortcuts / AppleScript integration** — App Intents path landed as F97 in v0.10.31. AppleScript sdef deferred.
> Menu-bar quick-send shipped as F87 in v0.10.14.
- ✅ **Folders / chat lists** — landed as F91 in v0.10.19.
- ✅ **Wire cosmetic Settings toggles** — shipped as F73 in v0.10.6.

## Account / Privacy

- ☐ **Multi-account** — link N WhatsApp accounts into one yawac
  window; account switcher in the sidebar so power users can
  drive personal + work + side-project numbers without juggling
  separate apps. The official Mac client is single-account, so
  this is likely the single strongest reason for a power user to
  pick yawac over it. Touches: per-account
  whatsmeow `*Client`, per-account SwiftData store + media
  cache, sidebar account chip + cmd-1..N keyboard switch,
  global notification routing tagged by account. Non-trivial —
  device count limits, paired-store isolation, and
  cross-account contact dedupe all have to land cleanly.
- ✅ **Push-name edit** — shipped as F96 in v0.10.29.
- ☐ **Local chat export / archive** — proper local backup of
  conversations as machine-readable (JSON/SQLite) + human-
  readable (HTML / Markdown). Meta deliberately makes phone-
  side export painful, and the privacy-conscious user wants
  this. We already persist everything in SwiftData; an export
  panel + file format is the gap. Optional encrypted bundle so
  the archive can sit safely in iCloud / Dropbox.
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

- ✅ **F122 — system messages inverted** (v0.10.50) — Encryption-key
  system rows showed as sidebar previews but were hidden in the
  conversation; now the opposite. CVM displayable filter keeps
  kind=system rows with body text; previewText gates kind before text;
  latestMessagePerChat SQL excludes system/protocol; refreshPreview
  fetches latest previewable row; bootstrap derived preview wins over
  the stale PersistedChat cache. Also: @mentions now resolve in
  quoted-reply snippets, composer reply chip, and global search hit
  snippets (missed surfaces from F121).
- ✅ **F121 — @lid mention resolution** (v0.10.49) — Group @mentions of
  LID identities rendered as `@+165562483245097`: displayName's
  "+digits" unknown-JID fallback from the `@s.whatsapp.net` candidate
  passed the `name != phone` check and masked the `@lid` candidate that
  holds the LID→PN mapping + pushname. Echo now kept only as last
  resort in both resolvers (bubble + chat-list preview). History audit
  (197 distinct mentioned ids): every id with any known identity now
  resolves; 50 silent-member phone mentions remain `@+phone` — protocol
  limit, no pushname fetch for arbitrary JIDs (verified against
  whatsmeow source). Fork bumped with upstream PR #1163 cherry-pick:
  join-request `phone_number` attrs now populate `whatsmeow_lid_map`.
- ✅ **F120 — responsiveness batch** (v0.10.48) — Main-thread audit over
  the hot paths (five parallel reviewers, 14 findings, 11 fixed / 3
  verified-invalid). Composer: `sendTyping` throttled to state change +
  10 s refresh (was one bridge RPC per keystroke), mention candidates
  built on appear/chat-switch, attachment chip previews decoded
  off-main at stage time. Chat list: `upsertPersisted(save:)` batches
  merge/reconcile loops into one `context.save()`; `totalUnread`
  written only on change. Voice notes: `OpusVoicePlayer.decodeBuffer`
  nonisolated, decode detached before playback. Boot: `connect()`
  nonisolated + detached, push-name hydration scan detached, bootstrap
  wait sleeps instead of `Task.yield()` spinning. ChatInfoView:
  link-sheet `listGroups` + `loadGroup` RPCs detached. Sender filter
  chips: FTS5 GROUP BY queries moved behind async loaders in find bar
  and global search.
- ✅ **F119 — automatic gap sweep** (v0.10.47) — Self-healing loop for
  lost messages. Replies persist their quoted target's chat + sender +
  message ID; `SQLiteDedupe.orphanQuotedRefs(sinceDays:)` scans for
  quoted targets absent from the store (read-only raw SQLite, 30-day
  window) and `SessionViewModel.runGapSweepIfNeeded()` asks the primary
  phone to resend each via `RequestMessageResend`
  (PLACEHOLDER_MESSAGE_RESEND) — recovered copies arrive as normal
  Message events and persist through the usual pipeline. Fires on
  `.connected`, 45 s after the F92 catch-up, throttled 24 h, capped at
  15 requests/run with 4 s spacing. No persisted attempted-set:
  unservable targets (deleted-for-everyone) retry at most once per day
  and age out of the window. Live verify: first run found 7 orphans,
  requested 7; combined with the F118 manual batch, 11 of 18
  decode-regression losses recovered (2 confirmed revoked stubs, 5
  pending phone response). Detection limit: only losses someone
  replied to are discoverable — silent gaps have no client-side trace.

- ✅ **F118 — live media decode regression fix + offline-gap message
  recovery** (v0.10.46) — User report: picture visible on phone missing
  in app. Investigation found TWO bugs. (1) Root cause of the loss:
  since `01a78db` (Jun 6, v0.9.2x) `JMedia` emitted `is_ptt` with
  `omitempty` while Swift `BridgeMedia` declared it non-optional on the
  false assumption that synthesized Decodable honors stored-property
  defaults (it does not) — EVERY live media message without the key
  failed decode in `WAClient.decode`, fell through to `.unknown`, and
  vanished with zero trace for a month. History-sync backfills masked
  most losses; whatever the phone never re-sent stayed lost. Fixed:
  `isPTT: Bool?` (callers already `?? false`), audited all remaining
  Go-omitempty vs Swift-required fields (is_ptt was the only mismatch),
  added permanent `[yawac/msg-decode]` failure log + decode regression
  test. (2) Recovery path: enabled whatsmeow
  `AutomaticMessageRerequestFromPhone` (PLACEHOLDER_MESSAGE_RESEND peer
  request — WA Web's "Waiting for this message" mechanism) so decrypt
  failures self-heal from the primary phone; added `[yawac/undecrypt]`
  logging (bridge previously swallowed `UndecryptableMessage` silently)
  and manual `RequestMessageResend(chat, sender, id)` bridge API +
  Swift wrapper. Empirically verified end-to-end: located the lost
  picture's ID via orphan-reaction sweep (reactions referencing
  messages absent from the store = free gap detector), requested it
  from the phone, message persisted and rendered. Bridge tests
  190/190. Follow-up candidate: F119 gap sweep (orphan-reaction /
  orphan-quote scan → per-chat `RequestOlderHistory` anchored
  backfill) for the two remaining known orphan gaps (Jul 1, Jun 27).

- ✅ **F117 — move PR #1151 poll extractor to bridge** (v0.10.45) —
  Fork was carrying tulir/whatsmeow PR #1151 (closed unmerged upstream)
  for the `HistoricalPollUpdates()` walk over `HistorySync` blobs. The
  walk only touches public whatsmeow API (`h.Data.GetConversations`,
  `wm.GetPollUpdates`, `pu.GetPollUpdateMessageKey`). Moved 88 LOC of
  extraction + 17 LOC of `HistoricalPollVote` struct into
  `bridge/history.go` as unexported `historicalPollUpdates()` +
  exported `HistoricalPollVote`. Fork branch dropped to
  `yawac-2026-07-04-nopoll` (tip `a0d4b7e975f9`), now carrying only
  three PRs (#1160, #1168, #1171). Zero rebase-forever cost for a
  patch upstream rejected. Bridge tests: 186/186. No behavior change.

- ✅ **F116 — whatsmeow fork rebase on upstream 2026-06-30** (v0.10.44) —
  Fork branch `yawac-2026-07-04` (tip `e4ae908359c8`) cherry-picks the
  four carried patches (PR #1151 poll-vote extractor, PR #1160 binary
  decoder resilience, PR #1168 signal session lock, SkipBrokenAppState
  opt-in) onto upstream `b572e5bcb92b` (Jun 30). Pulls in:
  `client: ignore connect success before pairing is completed` (may
  reduce reconnect-loop message drops when the socket flaps
  mid-authenticate), two proto refreshes (v1041871181, v1042386815),
  timelock mex notification handling, tctokens on more request paths,
  cstoken cleanup, passkey pairing scaffolding. Bridge tests: 186/186.
  Does NOT close the group-media-retry gap (still upstream-open) —
  offline drains of group image messages still get dropped when the
  socket flaps during delivery.

- ✅ **F115 — ponytail-audit-2 phase C (stdlib polish)** (v0.10.43) —
  Twelve micro-cleanups across four files. Net -66 LOC.
  - **ConversationViewModel.swift**: `reactors` / `voteCounts` /
    `voters` rewritten to one-line stdlib (`Dictionary(grouping:by:)`
    + `.mapValues`). `flushReceipts` two-pass max-bump collapsed to
    one `merge` call. `applyHistorySnapshot` five `for` overwrite
    loops + one unread-id loop folded into `merge` /
    `formUnion`. -39 LOC.
  - **bridge/messages.go**: dropped reaction-dispatch success
    log noise. Added `parseChatJID` helper and collapsed 7 empty-
    component guards across SendText, ForwardText, ForwardMedia,
    SendTextReply, SendLocation, SendContact, SendContactsArray.
    Collapsed 11 `classifyKindUnwrapped` "text" arms into one
    multi-condition case (same shape as `dispatchMessage`).
    Dropped two `_ = X` no-op lines in `extractSnippet`. Hoisted
    duplicate `contextInfoFromMessage(inner)` call in
    `dispatchMessage`. Dropped redundant base64 guard in
    `mediaFromAudio` (`base64.EncodeToString` returns `""` for
    nil/empty). -11 LOC.
  - **ChatInfoView.swift**: dropped redundant `addPanelOpen`
    Bool (always in lockstep with `addPanelModel != nil`).
    Collapsed `userBody` push-name if/else into one
    `metadataRow` call. Replaced `ImageBox` Identifiable
    wrapper with `.sheet(isPresented:)` + the
    `confirmRemoveBinding` pattern already used 3x in the file
    — incidentally fixed a latent UUID-regen bug where the
    `.sheet(item:)` `get` returned a fresh `ImageBox(image:
    ...)` with a new UUID every body eval. -8 LOC.
  - **WAClient.swift**: F112 missed 4 `?? []` decode sites
    still calling raw `JSONDecoder().decode` — folded to
    `Self.decodeJSON(json)`. Shrunk `encodeMentionsJSON` to
    one-line ternary, dropped duplicate doc comment. Collapsed
    `listMutedChats` inline struct `E` to one-line fields +
    one-line CodingKeys. -8 LOC.

- ✅ **F114 — ponytail-audit-2 phase B (mass dedup)** (v0.10.42) —
  Two structural dedups from the same audit pass. Net -160 LOC.
  - **ChatInfoView admin toggles → one helper.** Three identical
    `applyAnnounceToggle` / `applyLockedToggle` /
    `applyMemberAddModeToggle` funcs collapsed into a single
    `applyGroupBoolToggle(_:keyPath:errorBinding:persist:)`. The
    four admin toggle cards (ANNOUNCE / LOCKED / MEMBER ADD /
    JOIN APPROVAL) collapsed into a single `adminBoolToggleCard`
    view. The two `Disappearing messages` cards (1:1 path and
    group-admin path) collapsed into a single
    `disappearingMessagesCard(currentSeconds:chatJID:)`. The two
    `schedule…ErrorAutodismiss` raw Task.sleep helpers were
    replaced with the existing `.autodismiss($binding)` modifier
    already used 8 other places in the file. ChatInfoView.swift:
    -123 LOC.
  - **bridge/messages.go** `extractContextInfoExpiration` was 8
    near-identical `if X := m.GetX(); X != nil { if ci :=
    X.GetContextInfo(); ci != nil { ... }}` arms. Folded to one
    `contextInfoFromMessage(m)` call (covers 6 of 8 types) plus
    two short inline arms for the missing types
    (ContactMessage, LocationMessage). bridge/messages.go: -37
    LOC. The B5 `resolveTargetSender` helper was scoped out
    after reading the three call sites side-by-side — the third
    (`SendTextReply`) diverges (returns String, different
    fallback) and a 2-caller helper saves less LOC than the
    helper itself adds. The other phase-B-and-C audit items
    remain on the table for a later pass.

- ✅ **F113 — ponytail-audit-2 phase A (correctness + perf)** (v0.10.41) —
  Four surgical fixes from the second targeted audit pass over the
  five largest components (ConversationViewModel, ChatInfoView,
  ChatListViewModel, WAClient, messages.go).
  - **@ObservationIgnored** on `ChatListViewModel.session` (weak
    back-pointer set post-init, never read in a body) and on seven
    internal-only `var`s in `ConversationViewModel`
    (`downloadTasks`, `retriesRequested`, `didAutoRefetchExpired`,
    `findTask`, `pendingEdits`, `pendingRevokes`, `draftSaveTask`).
    Per the @Observable trap memory, every plain `var` on an
    @Observable class fires willSet→invalidate on mutation; these
    eight were silently re-bodying any view that touched the
    enclosing model.
  - **Quadratic merges → linear** in
    `ChatListViewModel.mergeGroups` and `mergeContacts`. Both used
    `chats.firstIndex(where:)` / `chats.contains(where:)` per
    incoming item — initial group / contact sync after pair ships
    hundreds to thousands of items. Now hoist an `idxByJID`
    Dictionary / `known` Set once and mutate in-place across the
    batch. O(n·k) → O(n+k).
  - **buildEarlierSnapshot dedup.** The older-page body switch was
    a 32-line copy of the centralized `Self.uiMessage(from:)`
    builder, missing the contact / contacts arms and the full
    metadata projection (edited, revoked, star, pin, forwarded,
    viewOnce, quote). Replaced with a one-line
    `displayable.map { Self.uiMessage(from: $0) }`. Earlier-page
    rows now show the same metadata as first-page rows — corrective
    behavior change, strictly additive (no removed rows).
  - Diff: +15/-42 LOC across two files; all tests green.

- ✅ **F109 + F111 + F112 — ponytail-audit phase 3 (partial)** (v0.10.40) —
  Three independent refactor passes from the audit, no behavior
  change. F110 (drop `WAClient.bump()` counters + Diagnostics
  call-counts section) deferred — touches a user-visible panel.
  - **F111.** `ContactPayload.vcard` is now a computed property
    deriving from `VCardBuilder.build(jid:name:phone:)` rather
    than a stored String. The builder is pure-deterministic and
    yawac never surfaces any vCard field beyond name / phone /
    waid (MessageRow only reads the waid for the "Message on
    WhatsApp" button). `fromVCard` keeps the inbound `vcard:`
    parameter to extract the waid → jid + phone, but drops the
    field from the returned struct. The follow-up commit adds a
    `!card.jid.isEmpty` guard on the WhatsApp button so an
    inbound vCard without a waid doesn't render a button that
    routes to "@s.whatsapp.net", and deletes
    `JIDNormalizeTests.testKeyIsCanonical` (orphaned by F108).
  - **F109.** Seven single-impl protocols deleted: GroupCreator,
    RequestUpdater, CommunityCreator, SubGroupLinker,
    SubGroupCreator, JoinRequestClient,
    TranslationEngineProtocol. Each existed solely as a test
    seam with `WAClient` (or the TranslationEngine actor) as the
    sole production conformer. Closure injection delivers the
    same testability with less abstraction surface: each
    consumer takes the `@Sendable` closure(s) it actually
    calls, production wires `client.<method>`, tests pass inline
    literals recording the call. Real implementations on
    WAClient and TranslationEngine stay where they were.
  - **F112.** Extracted `WAClient.decodeJSON` generic helper to
    fold 29 identical `try JSONDecoder().decode(X.self, from:
    Data(json.utf8))` call sites in WAClient. The audit's
    original `.convertFromSnakeCase` suggestion was unsafe —
    Swift converts `chat_jid` → `chatJid` (lowercase d), not
    `chatJID`; applying it would force a cascading rename of
    every property on every type. The per-event local structs
    inside `decode(kind:payload:)` and `try?`-flavored sites
    are intentionally untouched.

- ✅ **F108 — ponytail-audit renames + shrinks** (v0.10.39) —
  Phase 2 of the audit. Zero behavior change, -90 LOC net across
  21 files. Cuts: `SettingsPalette` deleted (3 unique keys folded
  into `Theme` under a "Settings panels" section, 73 call sites
  migrated to `Theme.*`); `JIDNormalize.key` deleted (10 sites
  migrated to `JIDNormalize.canonical`); `Theme.icon` forwarder
  deleted (call sites moved to `Theme.ui`); `MapSnapshotCache`'s
  internal memory dict dropped (already cached by
  `ThumbnailCache.mapCache` one layer up); `OrderedDict` (39-line
  custom LRU) inlined into a fileprivate `PendingMap` at the
  ConversationViewModel call site — only two ivars used it;
  `WAClient.jsonArrayString` helper extracted, folding 11
  duplicate JSON-encode call sites + the existing
  `encodeMentionsJSON`; `BridgeMedia.init(from:)` custom decoder
  replaced with a `var isPTT: Bool = false` defaulted field
  (Swift 5.9+ honors stored-property defaults). Phase 3 (single-
  impl protocols, `WAClient.bump()` counters,
  `ContactPayload.vcard` field → computed, `WAClient.decode`
  snake_case boilerplate) still open.

- ✅ **F107 — ponytail-audit dead-code purge** (v0.10.38) —
  Phase 1 of a wider over-engineering pass. Zero behavior change,
  -575 LOC across 20 files. Cuts: `bridge/offline_drain.go`
  (issue-#6 diagnostic, F100 fixed the underlying race), the
  paired `bridge/offline_drain_test.go`, the OfflineSyncCompleted
  payload trimmed to just `server_count` (Swift never read the
  other fields); `yawac/Services/WakeRateProbe.swift` +
  `WakeRateProbe.start()` boot wire (post-audit instrumentation);
  `AvatarLog` enum + every call site in `AvatarCache.swift`,
  `AvatarView.swift`, and `bridge/avatars.go` (env-gated logger
  never enabled in ship); `ThumbnailCache.flushAll()` (zero
  callers post-F105); `yawac/Utilities/ImageEncoders.swift` (zero
  callers); `bridge.Version()` + `bridgeVersion` constant + paired
  `bridge_test.go` (zero Swift consumers);
  `yawac/ViewModels/GroupsViewModel.swift` (15-line @Observable
  wrapper inlined at its sole caller);
  `ChatRef.Kind` enum + field (written, never read);
  `yawacTests/OwnProfileEditTests.swift` (covered by
  SessionViewModelSelfChatTests), `yawacTests/SmokeTests.swift`,
  `yawacTests/AppPathsTests.swift` (test framework guarantees,
  not us). Phase 2 (rename / alias sweep: SettingsPalette →
  Theme, JIDNormalize.key → canonical, etc.) and Phase 3 (single-
  impl protocols + bump counters) remain.

- ✅ **F106 — mirror push-name across LID↔PN forms** (v0.10.37) —
  Group bubbles for a 1:1 contact fell back to the bare LID digits
  ("+<15-digit-lid>") instead of the saved push-name because
  `ingestPushName` wrote the entry only at `JIDNormalize.bare(jid)`.
  The same person's 1:1 message arrives as `<phone>@s.whatsapp.net`
  but their group sender is `<lid>@lid`, two different keys in
  `contactNames`. Switched the write to walk
  `JIDNormalize.allForms(jid, client:)` so every push-name lands at
  the bare + canonical PN + reverse-resolved LID keys whenever
  whatsmeow's LID map knows the mapping. Existing keys are
  preserved (the function still only inserts when no other name is
  known). Fix is one function in SessionViewModel; live messages
  populate immediately, in-memory state from before the upgrade
  fills in as new traffic arrives or on restart.

- ✅ **F105 — drop ThumbnailCache idle flush** (v0.10.36) —
  `ThumbnailCache.scheduleIdleFlush` (F34) wiped every NSCache 5
  minutes after `didResignActive` then bumped all three revisions
  on return, so coming back to a long-idle yawac repainted every
  visible bubble from a cold decode — the "all pictures and avatars
  blink" symptom. `NSCache.totalCostLimit` already caps memory and
  the OS reclaims under pressure, so the manual flush only ever
  traded a visible regression for a savings the system can produce
  on its own. Deleted the resign/become-active observers + the
  scheduler + the pendingFlush field; kept `flushAll()` for a
  hypothetical future low-memory hook.

- ✅ **F103 + F104 — pin-drag re-geocode + multi-contact vCard** (v0.10.35) —
  Two roadmap gaps closed without new protocol surface.
  - **F103.** LocationPickerSheet swaps the legacy
    `Map(coordinateRegion:annotationItems:)` for
    `MapReader { Map(position:) { Annotation } }` and attaches
    `.onTapGesture(coordinateSpace: .local)` + a
    `.simultaneousGesture(DragGesture(minimumDistance: 8))` so a
    click or drag-release anywhere on the map calls the
    already-wired `model.onPinDrag(to:)`. A plain `.gesture(...)`
    lost priority to Map's built-in pan/zoom recognizer and never
    fired in smoke; `simultaneousGesture` runs alongside it. The
    250ms-debounced reverse-geocode in the model updates
    `resolvedName` / `resolvedAddress` on its own.
  - **F104.** `Client.SendContactsArray` (whatsmeow
    `ContactsArrayMessage` wrap) + inbound classifier arm in the Go
    bridge. gomobile cannot bridge `[]string`, so the boundary
    takes `vcardsJSON string` and unmarshals Go-side, mirroring
    `createGroup`'s convention. New `UIMessage.Body.contacts([ContactPayload])`
    case decodes from the new `contacts_array` JSON field.
    `ContactPickerSheetModel` switches from single-`String?` to
    `Set<String>` selection with `toggle(_:)` + `buildPayloads()`;
    the sheet renders one toggle button per row with a SF Symbol
    checkmark indicator; send label flips to "Send N contacts" at
    N ≥ 2. `ConversationViewModel.sendPendingAttachments` branches
    on `cards.count`: 1 keeps the existing single-contact path
    (back-compat), ≥2 fires `WAClient.sendContacts` once and
    appends one multi-card bubble. `PersistedMessage.contactsJSON`
    (new optional column, lightweight migration) round-trips the
    array across restarts; while wiring the hydration arm the
    pre-existing single-`.contact` cold-start path was missing
    too and got the same arm. `MessageRow` renders a "<N> contacts"
    header plus one stacked row per card, each reusing the
    single-contact helper so the per-row "Message on WhatsApp"
    stays wired.

- ✅ **F101 + F102 — composer image-paste + folder-rail drag-drop** (v0.10.34) —
  Two UI regressions: pasting any image into the chat composer was a
  no-op, and reordering folder icons / dragging chats onto folders had
  silently never worked since F91 shipped.
  - **F101 (paste).** `ComposerView.pasteAttachmentsFromPasteboard`
    read NSURL with no options, so Chrome/Safari "Copy Image" (which
    puts the source `https://` URL on the pasteboard alongside the
    bitmap) hit the URL branch first and tried to stage the web URL
    as a local file. Added `.urlReadingFileURLsOnly: true` so the URL
    branch only fires for `file://` (Finder copy), and web-image /
    screenshot paste falls through to the NSImage→PNG branch.
  - **F102 (folder rail).** Three layered bugs all hit at once:
    (1) the custom UTIs `dev.vadikas.yawac.chatjid` + `.folderid`
    were declared via `UTType(exportedAs:)` but never registered in
    `UTExportedTypeDeclarations`, so LaunchServices treated them as
    unknown and `.dropDestination(for:)` / `.onDrop(of:)` never got
    items; (2) two `.dropDestination` modifiers stacked on the same
    view registered only the first, so the folder-reorder target was
    shadowed by the chat-add target; (3) `FolderRailItem` was a
    Button — its tap-target competed with `.draggable` (same root
    cause as the v0.10.22 `.draggable → .onDrag/NSItemProvider`
    workaround). Plist entries added, two `.dropDestination`s
    collapsed into one `.onDrop([.folderID, .chatJID])` that
    dispatches by NSItemProvider type, and `FolderRailItem` is now a
    plain View with `.onTapGesture`. The dead
    `FolderIDTransferNSObject` wrapper from the v0.10.22 workaround
    is removed.

- ✅ **F100 — Issue #6 ROOT CAUSE: late-subscriber misses pump fan-out** (v0.10.33) —
  GitHub issue #6 chased through F83/F84/F89/F92/F93/F94 — each closed a
  different failure mode, none was the actual root. F99 debug session
  (whatsmeow fork cloned + instrumented) traced the message lifecycle:
  whatsmeow `handleEncryptedMessage` → bridge dispatch → Swift event
  pump → subscriber fan-out. Found: `WAClient.startPump` snapshots
  current subscribers and yields each event to them. SessionViewModel
  subscribes early via its own event loop; ChatListViewModel subscribes
  ~1-2s later in `ContentView.task` AFTER `runBootstrap()` wait +
  groups/contacts refresh. Every offline-drain message fired in that
  window was yielded to SessionViewModel only, missing
  ChatListViewModel.ingest entirely. Bytes arrived, bridge dispatched,
  one subscriber consumed them; the OTHER subscriber never saw them.
  Empirical proof: 21 messages dispatched, 1 reached `ingest` (the one
  that arrived AFTER ContentView subscribed).
  - **Fix.** WAClient gains a `_pendingEvents: [Event]` replay buffer
    (capped 1000) protected by the existing `subscribersQueue`. The
    pump always appends to the buffer in addition to fanning out live.
    `eventStream()` drains the buffer to the newly-registering
    subscriber atomically under the same lock. Late subscribers get
    the full backlog of events since the last drain. Existing
    subscribers get the live yield as before — no duplicates.
  - **Verified.** F99 instrumentation showed 4 of 4 offline-drain
    group messages now persist to `ZPERSISTEDMESSAGE` correctly.
  - **F99 probes reverted.** NSLog instrumentation in `ChatListViewModel
    .ingest`, `MessageWriter.enqueue`, `SessionViewModel.boot` removed;
    whatsmeow fork patches reverted; `bridge/go.mod` `replace` directive
    restored to the github.com/vadika/whatsmeow pin.
  - **Caveat.** Phone-side-already-read messages where WhatsApp's
    server cleared the offline buffer are still unrecoverable per
    protocol (F93 confirmed `preview.messages=0` for those cases).
    F100 closes the OTHER failure mode where bytes did arrive but
    yawac was racing its own subscriber registration.

- ✅ **F98 — Communities polish: sidebar chip tap + leave-community workflow** (v0.10.32) —
  Two community-management gaps closed.
  - **Sidebar pending-request chip is now tappable.** Previously
    a read-only badge; tap opens the chat AND scrolls ChatInfoView
    to the PENDING REQUESTS section. Implementation:
    `SessionViewModel.pendingChatInfoSection: PendingChatInfoSection?`
    transient field, `ChatListView` chip wrapped in `Button`,
    `ChatInfoView` body wrapped in `ScrollViewReader` + `.onChange`
    observer that runs `proxy.scrollTo("pending-requests", anchor: .top)`
    and consumes the flag. Help-text gains "— tap to review".
  - **Leave community workflow.** ChatInfoView's leave button on a
    community parent (`g.isParent`) now reads "Leave community" and
    opens a community-aware confirmation: "You'll be removed from X
    and all of its sub-groups." Confirm enumerates sub-groups via
    `WAClient.listSubGroups(parentJID:)`, fires `WAClient.leaveGroup(jid:)`
    per sub (per-sub errors logged, loop continues), then for the
    parent. `applyIncomingDelete(chatJID:)` makes sidebar updates
    feel instant; bridge `events.GroupInfo` handler covers the
    rest. Non-parent chats keep the original "Leave" wording.
  - **ChatInfoView refactor ripple.** Adding the leave-community
    button pushed `ChatInfoView.body` past Swift's type-check
    complexity limit. Side-effect cleanup: three inline
    `Binding(get:set:)` confirm-dialog bindings extracted to
    computed properties (`confirmRemoveBinding`,
    `confirmDemoteBinding`, `confirmUnlinkBinding`); two inline
    Task closures extracted to private methods
    (`reloadAfterNewSubGroup`, `performUnlinkSubGroup`). No
    behavior change — just smaller body literals so the compiler
    can finish typing the chain.
  - **No bridge / Go changes.** No unit tests (pure UI wiring).
    Manual smoke deferred to user post-Sparkle.
  - **Spec / plan.** `docs/superpowers/specs/2026-06-18-communities-polish-design.md`
    + `docs/superpowers/plans/2026-06-18-communities-polish.md`.
  - **Out of scope (blocked).** Demote community parent → plain
    group (whatsmeow no RPC); default-subgroup unlink (server
    breaks announcements); Newsletter/Channels (upstream
    Platform == MACOS argo decoding).

- ✅ **F97 — App Intents for Send / Open Chat / Mark Read / Search** (v0.10.31) —
  Power-user automation surface that the official WhatsApp Mac
  client can't match. Four App Intents wired through a fresh
  `yawac/Intents/` folder:
  - **`SendWhatsAppMessage(chat, body)`** — resolves chat via the
    shared `ChatResolver` (phone digits or substring name match,
    `@s.whatsapp.net` + `@lid` fallback), invokes
    `WAClient.sendText`, returns `Sent message <ID>`.
  - **`OpenWhatsAppChat(chat)`** — resolves chat, drives the
    existing `SessionViewModel.openRootChat`, calls
    `WindowToggler.bringToFront()` to surface the window.
  - **`MarkWhatsAppChatRead(chat)`** — resolves chat, calls
    `ChatListViewModel.markRead`.
  - **`SearchWhatsAppMessages(query)`** — writes the query through
    transient `SessionViewModel.pendingShortcutQuery`; ContentView
    observer forwards into the live `ChatSearchViewModel`.
  - **Discoverability.** `YawacShortcutsProvider: AppShortcutsProvider`
    registers all four with phrases like "Send WhatsApp message via
    yawac" so Shortcuts.app, Spotlight, and Siri pick them up on
    first launch.
  - **Dependency wiring.** `AppDependencyManager.shared.add(dependency: session)`
    in the WindowGroup's `.onAppear` (not `init()` — `@State` isn't
    readable from `App.init`) so `@Dependency private var session:
    SessionViewModel` resolves inside `perform()`.
  - **Coverage.** `openAppWhenRun: true` — live `WAClient` +
    SwiftData store required, headless invocation not supported.
  - **Resolver tests.** `yawacTests/ChatResolverTests.swift` — 8
    pure-function cases (empty / phone-net / phone-lid / phone
    normalize / exact name / substring case-insensitive / ambiguous
    / not-found).
  - **Spec / plan.** Design at `docs/superpowers/specs/2026-06-18
    -shortcuts-app-intents-design.md`; plan at
    `docs/superpowers/plans/2026-06-18-shortcuts-app-intents.md`.
  - **Skipped (deferred to future cycle).** AppleScript `.sdef` /
    `NSScriptCommand` path; send-with-attachment intent; reply-to-
    message intent; multi-account targeting.

- ✅ **F96 ponytail follow-up — saveSelfField helper + test defer** (v0.10.30) —
  Post-commit ponytail review on F96 (v0.10.29) found two yagni:
  `saveSelfAbout` + `saveSelfPushName` shared ~17 LoC of identical
  shape (capture-mark-save-baseline-error pattern), and
  `TestSetSelfPushNameUnpaired` was missing `defer c.Close()` for
  consistency with the other tests in the same file. Extracted
  `saveSelfField(draft:baseline:saving:error:persist:)` to fold
  both save handlers into one body; added the missing defer.
  Net: a few LoC saved + tightened pattern for future profile
  fields. Sets the precedent for the new "always ponytail before
  commit" rule.

- ✅ **F96 — Push-name edit** (v0.10.29) —
  Completes the profile-edit story alongside avatar (v0.9.0) and
  about (v0.9.1). The roadmap entry claimed whatsmeow had no
  top-level push-name setter, but upstream
  `appstate.BuildSettingPushName(string) PatchInfo` exists and
  goes through the standard `Client.SendAppState` flow.
  - Bridge: `Client.SetSelfPushName(name string) error` mirrors
    the `SetSelfAbout` pattern — trim, validate non-empty,
    `SendAppState(ctx, appstate.BuildSettingPushName(trimmed))`.
  - Swift: `WAClient.setSelfPushName(_:)` shim + push-name text
    field next to the existing About edit in `ChatInfoView`.
    Prefills from `client.ownPushName` on sheet open.
  - Source of truth stays on the phone — server echoes the change
    back via appstate sync, no local cache update needed.
  - Tests: bridge `TestSetSelfPushNameUnpaired` +
    `TestSetSelfPushNameRejectsEmpty`.
- ✅ **F95 — Ponytail code refactor sweep** (v0.10.28) —
  Repo-wide ponytail audit identified 30 over-engineering findings.
  Code-only sweep (docs untouched per user request). Net ~220 LoC
  removed across 10 commits. No behavior change.
  - Phase 1 deletes: legacy `scripts/release.sh` (`bump-cask-test.sh`
    kept — CI uses it); inlined 3 verified single-caller Swift helpers
    (`snippetText`, `applyMediaRetrySucceeded`, `headerStatus`) and
    1 Go wrapper (`firstDevice`); moved `rank(Status)` switch to
    `Status.sortOrder` computed property. (8 bridge test files kept
    — all had substantive assertions; `sectionLabel` and
    `dstEphemeralSec` kept — multi-callers.)
  - Phase 2 stdlib swaps: `looksLikeExpiredError` uses static
    `Set<String>` + `.contains(where:)` instead of 7 sequential
    `.contains()` calls; replaced
    `.reduce(0){$0 + ($1.alreadySeen ? 1 : 0)}` with
    `.count(where:)`; inlined `BridgeIDPair` 2-init struct as
    named tuples at 3 call sites.
  - Phase 3 extracts: `.autodismiss(_:after:)` ViewModifier folds 8
    repeated `.task(id:err)` patterns in ChatInfoView.swift;
    consolidated 2 duplicated ~28-LoC UIMessage construction blocks
    into existing `uiMessage(from:)` static helper.
  - Phase 4: removed MapSnapshotCache in-session negative cache
    (MKMapSnapshotter is naturally rate-limited; disk cache handles
    success path).
  - **Skipped from audit:** docs trimming (ROADMAP + plans archive),
    `DateFormatter` consolidation (all already `private/fileprivate
    static let`), `AvatarSemaphore→DispatchSemaphore` (actor-based
    async semaphore — DispatchSemaphore.wait() blocks cooperative
    thread), `buildEarlierSnapshot` metadata hydration (intentionally
    minimal), MediaCache/AvatarCache unification (architectural
    surface — separate cycle), TranslationStore reshape (caller
    surface — separate cycle).

- ✅ **F94 abandoned — synthetic future-anchor probe** (v0.10.27) —
  F94 (v0.10.26) shipped a per-chat type-5 `requestOlderHistory`
  with synthetic FUTURE anchor (now+1 day, fake msgID
  `PROBE-FUTURE-<uuid8>`) to test whether the phone honors the
  timestamp without validating msgID. User repro confirmed: probe
  fires (4/4 logged) and 2 ON_DEMAND chunks return, but the target
  chat (where user read messages on phone while yawac offline)
  stays at the pre-probe timestamp. Phone validates msgID OR
  returns only already-known older content. Reverted. Re-pair is
  the only recovery path for the read-on-primary subset.
  - Removed `requestPerChatFutureAnchorProbe()` method and the
    `Task { await ... }` wiring in the `.connected` handler.
  - F83 / F84 / F89 / F92 / F93 all stay.

- ✅ **F94 — Per-chat future-anchored type-5 probe (experimental)** (v0.10.26) —
  Issue #6 long-tail probe after F93 (v0.10.25) verified phone
  ships zero bytes for read-on-primary-device messages. The
  documented `BuildHistorySyncRequest` semantic is "messages
  BEFORE the given anchor". Probe: pass a synthetic FUTURE
  anchor (now+1 day, fake msgID) per chat with recent activity
  on every `.connected`. If phone honors the timestamp without
  validating msgID against its local DB, this pulls the most
  recent N messages per chat including the read-on-phone subset.
  - **Fan-out.** Loops over chats with `lastTimestamp` within
    the last 24h. 50 msgs per chat, 100 ms throttle between
    sends so we don't burst-hammer the phone.
  - **Anchor.** `oldestTimestampSec = now + 86400`,
    `oldestMsgID = "PROBE-FUTURE-<uuid8>"`. Senderjid = chatJID
    (correct for 1:1; best-effort for groups).
  - **Diagnostics.** `[yawac/catchup-probe] firing for N
    chats` and `fired M/N` lines in `/tmp/yawac.log`. If chunks
    land, they flow through the existing `applyHistorySync`
    classifier → normal persistence path.
  - **Gated.** Reuses the `historyBackfillCompleted` check from
    F92 — only fires after the one-shot deep sync.
  - **Caveat.** Pure experiment. Phone may reject unknown msgID
    outright or ignore the request silently. If post-v0.10.26
    repro shows target chat still missing newer messages, F94
    is abandoned — only re-pair recovers.

- ✅ **F93 — Offline-drain UndecryptableMessage instrumentation** (v0.10.25) —
  v0.10.23/24 F92 catch-up + chunk-arrival log confirmed the phone
  responds to type-6 FULL_HISTORY_SYNC_ON_DEMAND but only ships a
  tiny diff slice (50 msg / 1 conv for a 30-day window). User's
  read-on-phone-while-yawac-offline messages are not in those
  chunks. Need to determine ground truth: do the bytes reach the
  bridge layer at all?
  - Extended F83's `offlineDrainTracker` with a fourth tick path
    for `*events.UndecryptableMessage`. Whatsmeow emits this event
    when it tried to decrypt but couldn't. Two subcases:
    - `IsUnavailable=true`: sender device DID NOT send a ciphertext
      to this device — exactly the "primary device consumed,
      offline buffer cleared" case.
    - `IsUnavailable=false`: ciphertext arrived but couldn't be
      decrypted — key state mismatch (signal session race).
  - `bridge/events.go` adds a new `case *events.UndecryptableMessage`
    that ticks the tracker WITHOUT dispatching to Swift (diagnostic
    only). The tick short-circuits outside the in-flight offline
    drain window so non-offline decrypt failures don't pollute the
    log.
  - Updated the `OfflineSyncCompleted` log line + bridge dispatch
    payload to include `undecryptable=N (unavail=M ciphertext=K)`.
  - Three bridge tests cover: ticks on `IsUnavailable=true`,
    ticks on `IsUnavailable=false`, no-op outside in-flight window.
  - **Next step (post v0.10.25 user repro):** if `unavail > 0` →
    protocol limit confirmed → file upstream whatsmeow issue +
    document as known. If `ciphertext > 0` → fix subcase via
    PLACEHOLDER_MESSAGE_RESEND. If both 0 → bytes never arrive →
    open whatsmeow issue.

- ✅ **F92 hardening — reconnect catch-up wider + shorter throttle + chunk-arrival diagnostics** (v0.10.24) —
  v0.10.23's F92 catch-up fires correctly (`[yawac/catchup]
  sending FULL_HISTORY_SYNC_ON_DEMAND count=7` + `SendPeerMessage
  ok` visible in /tmp/yawac.log) but the phone responds with
  HistorySync chunks asynchronously, seconds after SendPeerMessage
  returns. If the user quits yawac quickly to inspect the log,
  chunks never arrive. The 5-min throttle then blocks a re-fire on
  the next launch.
  - **Throttle 5 min → 30 s.** Reconnect-flap protection still
    works (a 30 s window prevents the kernel from spinning if
    the network drops repeatedly), but legitimate user-driven
    relaunches now re-fire the catch-up. Phone-side dedupes
    naturally via the FULL_HISTORY_SYNC_ON_DEMAND request ID
    collision.
  - **Window 7 → 30 days.** Covers users who close yawac for a
    week or two before relaunching.
  - **ON_DEMAND chunk arrival diagnostic.** New
    `[yawac/catchup] received ON_DEMAND chunk progress=N
    chunkMessages=M conversations=K` log line in
    `/tmp/yawac.log`. When the phone responds, the chunk now
    leaves a trace we can match against the SendPeerMessage line.
  - **User guidance.** Leave yawac running 30-60 s after launch
    to let chunks settle.

- ✅ **F92 — Reconnect catch-up history sync** (v0.10.23) —
  Issue #6 regression: user reports messages read on the phone
  while yawac was offline never sync after reconnect. F83/F84/F89
  closed the in-bridge silent-drop failure modes (SQLITE_BUSY,
  signal session race), but `/tmp/yawac.log` analysis shows a
  separate WhatsApp protocol behavior is now the cause: when the
  primary device (phone) reads a message, the server marks it
  delivered to all linked devices and clears the offline buffer.
  yawac then gets only "notifications" (read-state hints), no
  actual message content. Server-side, not fixable in bridge.
  - **Workaround.** On every `.connected` event after the one-shot
    full backfill, fire a 7-day FULL_HISTORY_SYNC_ON_DEMAND
    (type 6) catch-up request via the existing
    `Client.requestFullHistorySync` path. Phone re-ships those
    7 days of history — the recently-cleared messages re-arrive
    through the normal `applyHistorySync` classifier, dedupe by
    message ID at persist time.
  - **Throttle.** 5-minute minimum between catch-ups, tracked via
    `@UserDefault("yawac.lastReconnectCatchupAt")`. Prevents
    reconnect-flapping (visible in logs as `connection reset by
    peer` bursts during weak network) from hammering the phone.
  - **Logout reset.** `logout()` clears the throttle timestamp
    alongside `historyBackfillCompleted` so a re-pair starts
    fresh.
  - **Diagnostics.** New `[yawac/catchup]` log lines in
    `/tmp/yawac.log`: `skip — last fired Xs ago`,
    `sending FULL_HISTORY_SYNC_ON_DEMAND count=7`, or `failed: …`.

- ✅ **F91 v4 — Drag-reorder fix + "All" scope segment** (v0.10.22) —
  Iteration on v0.10.21 user feedback.
  - **Drag-reorder.** v0.10.21 fixed a stale-`idx` capture in the
    drop closure but folders still didn't actually react to drag
    because SwiftUI's `.draggable(FolderIDTransfer(...))` on a
    `Button` competes with the button's tap-target — on macOS the
    button hit-test wins before the drag distance threshold is
    met. Replaced with the older `.onDrag { NSItemProvider }`
    pattern + matching `.onDrop(of: [.folderID])` drop handler.
    Added `FolderIDTransferNSObject` wrapper conforming to
    `NSItemProviderWriting`. Chat-drop on the same item still
    uses `.dropDestination(for: ChatJIDTransfer.self)` because
    the source is a chat row (not a button), where `.draggable`
    works fine.
  - **"All" scope.** Added `.all` segment to `KindScope`, default
    selection. 4 buttons: All / Direct / Groups / Communities.
    Tapping "All" or the active segment clears back to All.
    `.matches(_:)` returns `true` for `.all` over any chat.

- ✅ **F91 v3 — Folders iteration: scope row restored + "+" button + drop ⌘ menu** (v0.10.21) —
  Post-v0.10.20 user feedback iteration.
  - Removed the `CommandMenu("Folders")` ⌘0..⌘9 wiring + the
    `FolderCommands` struct. Rail click is the only selection input
    now. AppStorage launch-restore stays.
  - Restored a 3-button horizontal Direct / Groups / Communities
    scope row at the top of the chat list. Toggleable (tap to
    apply, tap again to clear); persisted via @AppStorage
    `yawac.kindScope`. Layers ON TOP of the rail's
    Folder / All chats / Archived selection — orthogonal kind
    filter applied after `chatsFor`. No "All" segment — the
    rail's All chats sentinel is the no-kind-filter default.
  - Added a small "+" button at the bottom of the folder rail
    (below the Archived sentinel). Tap → emits `RailEvent
    .newFolder(insertIndex: vm.folders.count)` which the parent
    handles by surfacing `NewFolderSheet`. Discoverable affordance
    that doesn't require a right-click.
  - Verified folder drag-reorder ([previously T13 in v0.10.19])
    works as designed: both `.draggable(FolderIDTransfer)` source
    and `.dropDestination(for: FolderIDTransfer.self)` target on
    the custom `FolderRailItem`. Fixed stale-index capture: `to`
    index now looked up by `folder.id` at drop time rather than
    relying on the closure-captured `idx` from `enumerated()`.

- ✅ **F91 hotfix — in-memory Chat.folderIDs sync** (v0.10.20) —
  v0.10.19 shipped with `FolderRailViewModel.addChat` mutating
  `PersistedChat.folderIDs` on disk but leaving the in-memory
  `ChatListViewModel.chats[i].folderIDs` cache stale. `chatsFor(
  .custom(folderID:))` reads the in-memory copy, so the chat list
  rendered empty even though the disk row carried the folder tag.
  Fix: pass a `weak chatList: ChatListViewModel?` reference into
  the rail VM at construction; rail mutations now call
  `chatList?.refreshFolderIDs(for: jid)` which re-reads
  PersistedChat.folderIDs back into the in-memory cache. Affects
  add (drag + context menu), remove, and folder delete (scrubs
  every chat).

- ✅ **F91 — Folders / chat lists (Telegram-style rail)** (v0.10.19) —
  Vertical folder rail on the left of the chat list. Custom
  user-defined folders (`PersistedFolder` SwiftData model, name-only;
  no per-folder icon picker v1) live above two sticky smart
  sentinels: **All chats** and **Archived**. The latter replaces the
  prior inline expandable archived section — archived chats are now
  hidden from the main list and surface only via the Archived rail
  icon.
  - **Membership.** Three input paths: drag a chat row onto a custom
    rail item (`ChatJIDTransfer` custom UT type
    `dev.vadikas.yawac.chatjid`), right-click the chat → "Add to
    folder…" submenu with per-folder checkmarks (toggles
    membership), and "Add to folder…" inside that submenu's trailing
    "New folder…" item. Storage is a Codable `[String]` `folderIDs`
    field on `PersistedChat`; `addChat` is Set-semantics idempotent.
  - **Rail CRUD.** Right-click a custom folder → Rename / Delete
    folder… / New folder…. Delete cascades a scrub of every chat's
    `folderIDs`. Rename + Create flow through a small
    `NewFolderSheet` (1-field name prompt).
  - **Reorder.** Drag custom folder rail items up/down via a
    second `FolderIDTransfer` UT type (`dev.vadikas.yawac.folderid`).
    `sortIndex` re-assigns by working order on drop. Smart
    sentinels not draggable.
  - **Unread badges.** Red top-right capsule on each rail item =
    sum of `unread` across chats in the folder; "99+" cap. Archived
    chats count ONLY toward the Archived sentinel — they don't bump
    a custom folder badge they were tagged into pre-archive.
  - **⌘0..9 quick switch.** New `CommandMenu("Folders")` wired in
    `yawacApp.swift`. ⌘0 = All chats; ⌘1..9 = first 9 custom
    folders by rail order. Writes through `@AppStorage("yawac
    .selectedFolderID")` which the rail observes; folders beyond
    ⌘9 reachable only via rail click. Archived not bound to any
    shortcut (rare-use).
  - **Behavior change vs prior build.** The 4-segment scope picker
    (`@AppStorage("yawac.chatListScope")` driving All / Direct /
    Groups / Communities) is REMOVED — the rail subsumes it. The
    inline expandable Archived section in the chat list is REMOVED
    — archived chats now live in the Archived rail entry only.
    Replaces ROADMAP entry "Folders / chat lists".
  - **Local-only.** Folders are NOT cross-device synced. Each
    yawac install has its own folder set. Multi-account splitting
    is out of scope (covered by future Multi-account work).
  - **Spec / plan.** Design at `docs/superpowers/specs/2026-06-17
    -folders-chat-lists-design.md`; TDD plan at
    `docs/superpowers/plans/2026-06-17-folders-chat-lists.md`.
    Subagent-driven execution.

- ✅ **F90 — Historical poll-vote consumer fix (own-vote substitution
  on peer-created polls)** (v0.10.18) — F88 wired the fork's PR #1151
  helper end-to-end but gated the bridge's empty-Voter substitution on
  `r.PollCreationFromMe` — a field that tells us who created the poll,
  not who cast the vote. The helper at `types/events/historicalpollvotes
  .go` leaves `Voter` empty whenever the update key has `FromMe=true`,
  regardless of poll authorship; the only consistent interpretation is
  "vote from us". Failure case: peer creates poll, user votes from
  phone → bridge persists vote with `voterJID=""` → Swift
  `mySelections(for:)` keyed against `client.ownJID` finds nothing →
  bubble shows the user didn't vote even though they did.
  - **Fix.** Drop the `PollCreationFromMe` gate. Extract the per-record
    translation into a pure helper `historicalRecordToVote(r,
    ownBareJID) JPollVote` so the substitution rule is unit-testable
    without a `*Client`. Substitute `ownBareJID` whenever `r.Voter` is
    the zero JID (and the client is paired). Unpaired client → no
    substitution; SQLite row recoverable on next sweep after pairing.
  - **Tests.** Bridge: table-driven `bridge/history_test.go` covering
    own-vote on own/peer poll, peer-vote on own/peer poll 1:1,
    peer-vote in group with Participant, empty-selection vote-clear,
    unpaired-client guard. Swift: `yawacTests/ConversationView
    ModelPollHistoryTests.swift` covers `applyPollVote` ↔
    `mySelections(for:)` round-trip + `buildHistorySnapshot` hydration
    from `PersistedPollVote` rows. `StubPollHistoryClient: WAClient`
    overrides `ownJID` (same pattern as `StubSelfChatClient`).
  - **Diagnostic.** New per-sweep log line `[yawac/poll-history]
    sweep records=N self=M peer=K` in `/tmp/yawac.log` so substitution
    activity is visible on the existing paired account without
    re-pair. After the user-facing **Full sync** button fires, `self
    > 0` confirms the F90 substitution is live.
- ✅ **F89 — whatsmeow S-tier PRs cherry-picked (#1160, #1168, #1171)**
  (v0.10.16) — Three open upstream PRs picked onto the fork on top
  of F88. Total ~400 LoC across whatsmeow; one bridge wiring line.
  - **PR #1160 — decoder no-panic.** `binary.consumeFrames` has no
    recover, so any malformed frame (non-string node tag, zero-length
    parity-flagged packed string, empty Unpack payload) crashed the
    whole goroutine. Now returns errors; `handleFrame` already drops
    them. Fuzz target + table tests included. Pure crash resilience.
  - **PR #1168 — signal session lock.** Per-address lock around the
    full load-encrypt-store cycle in `encryptMessageForDevices` and
    around `decryptDM`. Prevents the send-while-receive race that
    caused either "message with old counter" silent drops at the
    recipient or 22.5 MB of spurious skipped-message-key allocations
    on the upstream profile. Lock is per-address so unrelated chats
    don't block. **Likely closes our issue #6** (messages received on
    phone while yawac offline, never synced after reconnect).
  - **PR #1171 — `Client.SkipBrokenAppStatePatches` opt-in.** New
    field on `Client`; defaults off. yawac flips it `true` in
    `bridge/client.go`. When the appstate sync hits a permanently
    bad patch (`ErrMismatchingLTHash` or `ErrKeyNotFound`), the
    cursor is advanced past it (`PutAppStateVersion` with a zeroed
    hash) and the fetch is retried — bounded skip-loop, 300 ms
    throttle × 200 cap. Skipped patches lose their archive/mute/pin
    mutations; same trade-off WhatsApp Web takes on snapshot reset.
    Fixes upstream issues #382, #518, #651, #858 — the perpetually-
    stuck `regular_low` chain. Default behavior unchanged for any
    other whatsmeow consumer.
  - **Fork upkeep** — Cherry-picks landed clean (no conflicts) on top
    of the F88 fork tip (a91337b). `docs/whatsmeow-patches.md`
    rewritten to list all four carried patches.

- ✅ **F88 — whatsmeow upgrade to upstream tip (eaa388b + PR #1151)**
  (v0.10.15) — Bumped pin from `8d37001` (May 16) to fork tip
  `a91337b` based on upstream `eaa388b` (Jun 16). 25 upstream commits
  pulled in. Notable wins for yawac: LID-aware historical message
  secrets + privacy tokens (`595ceb0`, supersedes our prior PR #1148
  patch), own web-message LID parse fix (`4e62216`), ack-all-nodes +
  panic recovery in `handleEncryptedMessage` (`a7ea563`, adjacent to
  issue #6's missing-message pattern), stale-entry cleanup in the
  LID↔PN cache (`563bcaa`), `qrchan` atomic-bool conversion + listen
  on `expectedDisconnect` (`256f4d7`), `sqlstore` container teardown
  on upgrade failure (`88b76e5`), proto bumps to v1040847988.
  - **Fork upkeep** — Prior patches PR #1120 + PR #1148 are now
    upstream; only PR #1151 (historical poll-vote tally extractor for
    `events.HistorySync.HistoricalPollUpdates()`) is still carried.
    The fork branch was force-pushed to upstream tip + the one
    cherry-pick. `docs/whatsmeow-patches.md` rewritten to reflect the
    new state and bumping procedure.
  - **Bridge API drift** — `Client.DownloadMediaWithPath` lost its
    `fileLength int` argument (`d707fc2` removed length checks) and
    gained an `allowNoHash bool` argument (`52afebe`). Updated both
    call sites in `bridge/media.go`. Legacy URL fallback removal
    (`9ff5508`) is safe — yawac has always downloaded via
    `DirectPath`.
  - **Transitive bumps** — `go.mau.fi/libsignal v0.2.1 → v0.2.2`,
    `go.mau.fi/util v0.9.9 → v0.9.10`, plus golang.org/x/crypto, net,
    sys, text, tools, sync, mod, exp, coder/websocket, edwards25519.

- ✅ **F87 — Menu-bar quick-send popover + ⌘⇧Y global hotkey**
  (v0.10.14) — Fills the roadmap `Important → Productivity/macOS →
  Menu-bar quick-send` slot. Send a text message without surfacing
  the main window. F73 mounted the `NSStatusItem` stub; F87 added
  the popover, the chat picker, the composer, and the Carbon global
  hotkey on top.
  - **`yawac/UI/GlobalHotkey.swift`** — `@MainActor final class`
    wrapping Carbon `RegisterEventHotKey(kVK_ANSI_Y, cmdKey|shiftKey,
    'yawc', 1)`. Carbon path (vs `NSEvent.addGlobalMonitorForEvents`)
    skips the Accessibility-permission prompt; same approach
    Raycast / Alfred use. `eventHotKeyExistsErr` is swallowed +
    logged via `NSLog("[yawac/hotkey] ...")` so a conflict with
    another app doesn't crash. Unit tests cover register/unregister
    idempotency + the conflict swallow.
  - **`yawac/UI/QuickSendChatPicker.swift`** — search field + filtered
    `List`. Pure-data static `filter(chats:query:recentLimit:)`
    helper: DESC sort by `lastTimestamp`, empty-query path truncates
    to `recentLimit = 15`, non-empty query bypasses the cap and
    matches case-insensitive `name` substring OR (digit-only query)
    JID user-component `hasPrefix`. View memoizes the sort across
    body evals via a count-keyed `@State` cache so keystrokes don't
    pay O(n log n) per re-render. Up/Down arrow navigation +
    `.onSubmit` selection. Unit tests cover the 5 filter behaviors.
  - **`yawac/UI/QuickSendComposer.swift`** — text composer with
    pure-async `attemptSend(chatJID:draft:sender:onClose:) async ->
    SendOutcome` so the send-driver is unit-testable without a real
    `WAClient`. `canSend(draft:)` trims `.whitespacesAndNewlines`.
    Cmd-Enter sends; error banner shows the bridge error for 4s
    (race-safe — clear only if `self.error == msg`). Unit tests
    cover empty-draft block, success-closes-popover, failure-keeps-
    open-with-error.
  - **`yawac/UI/QuickSendPopover.swift`** — root view. Three
    render paths: `session.client == nil` placeholder, picker,
    composer. Three-tier `resolvedName(for:)` helper —
    `session.displayName` → chat row's `.name` → raw JID. The
    composer's `send:` closure does NOT capture a `WAClient`
    reference at construction; it reads `session.client` lazily
    at fire time so the cached popover doesn't carry a stale
    client across `logout()` → `boot()` re-pair churn.
  - **`yawac/UI/MenuBarController.swift`** — F73's status-item
    controller now also owns a `NSPopover` + a `GlobalHotkey`.
    Left-click toggles the quick-send popover (was: bring main
    window forward). Right-click context menu gains a new "Show
    Main Window" item — the old left-click affordance moved here.
    `install()` / `tearDown()` bundle the status item + popover
    + hotkey lifecycle under the `yawac.menuBar.show` preference
    (F73). `togglePopover()` (the public entry called by both
    left-click and the Carbon callback) activates yawac via
    `NSApp.activate(ignoringOtherApps: true)` so the popover gets
    focus without surfacing the main window.
  - **`yawac/yawacApp.swift`** — gated the menu-bar install
    behind a "not running under XCTest" check
    (`ProcessInfo.processInfo.environment["XCTestConfigurationFile
    Path"] != nil`) so `GlobalHotkeyTests` doesn't race the host
    app for ⌘⇧Y.
  - **Outbound persistence path.** whatsmeow does NOT echo own
    outbound sends back as `events.Message` — confirmed by the
    F51 optimistic-send comment in `ConversationViewModel.swift`.
    Quick-send synthesizes a `BridgeMessage` from
    `BridgeSendResult` and injects it via new
    `WAClient.dispatchSynthetic(_:)`, which yields the event to
    every existing subscriber (chat list + open conversation
    view). Single emit → both subscribers update via the same
    code path real inbound messages take: sidebar tip refreshes,
    open chat scrollback appends the row immediately, FTS upsert
    fires through `ChatListViewModel.ingest`'s writer queue.
  - **Spec / plan.** Brainstorm + design at
    `docs/superpowers/specs/2026-06-17-menu-bar-quick-send-design.
    md`; TDD plan at `docs/superpowers/plans/2026-06-17-menu-bar-
    quick-send.md`. Subagent-driven execution: one implementer +
    spec-compliance reviewer + code-quality reviewer per task,
    fix loops where reviewers flagged issues, final E2E manual
    verification on the running Debug binary.

- ✅ **F86 — Brand the linked-device entry as "yawac · macOS"**
  (v0.10.13) — Phone's WhatsApp linked-devices list showed yawac as
  "whatsmeow · other platform · other device" with the generic
  fallback icon. Two fields control this on the wire and both ship as
  whatsmeow's stock defaults at pair time:
  - `store.DeviceProps.Os` — phone reads this verbatim as the
    human-visible device name. Was `"whatsmeow"`; now `"yawac"`.
  - `store.DeviceProps.PlatformType` — enum that drives the icon.
    Was `UNKNOWN (0)`; now `CATALINA (12)`, which is the slot
    WhatsApp's own macOS Desktop client uses, so the phone shows a
    macOS icon. CHROME/FIREFOX/etc. would have worked too but pick
    the wrong icon (browser glyphs); DESKTOP (7) is generic. CATALINA
    matches reality — yawac IS a native macOS app.
  Lives in `bridge/client.go` next to the F1-era
  `applyDeeperHistorySyncDefaults` override and runs from the same
  package `init()` so the override lands before any
  `whatsmeow.NewClient` call (DeviceProps is a package-level singleton
  consulted only at registration).
  **Caveat: pair-time lock-in.** Whatsmeow sends DeviceProps once,
  during the pairing handshake. The phone records the values it sees
  there and they show in the linked-devices list forever after.
  Existing paired clients running v0.10.13+ continue to show as
  "whatsmeow · other platform" until the user explicitly Logs Out +
  re-pairs. Worth doing once (and freshly re-pulling deep history at
  the same time, given F56) but not forced.

- ✅ **F85 — SwiftData store maintenance: ANALYZE + periodic VACUUM
  + auto_vacuum=INCREMENTAL** (v0.10.12) — followup to the discussion
  about whether SQLite is the right backend for yawac's message store
  at scale. Conclusion: yes — WhatsApp / Signal / Telegram all use
  SQLite; alternative engines (DuckDB / LMDB / Realm / PostgreSQL)
  are either worse-suited or impractical for a desktop chat client.
  What was missing was housekeeping: per-connection pragmas
  (`cache_size`, `mmap_size`, `synchronous`, `temp_store`) can only
  be set on the connection that uses them, and SwiftData's public
  `ModelConfiguration` exposes none of them — so those require a
  drop-down to `NSPersistentStoreCoordinator` to ever take effect
  on the right connections. Out of scope here; document and move on.
  What IS shippable through a side raw-SQLite connection (same
  pattern as F37 + F45):
  - **`PRAGMA auto_vacuum=INCREMENTAL`** — persistent header pragma.
    Effective once the next `VACUUM` rebuilds the page layout. Lets
    a future `PRAGMA incremental_vacuum(N)` reclaim pages without
    holding the EXCLUSIVE lock a full `VACUUM` requires.
  - **`ANALYZE` every launch** — refreshes `sqlite_stat1` so the
    query planner keeps picking the F45 raw-SQL indices as row
    distributions shift over time. Costs ms.
  - **`VACUUM` every 30 days** — compacts the store and reclaims
    pages freed by F37's transaction-log prune. Holds EXCLUSIVE; on
    our scale it's seconds (50.7 MB store completed in 148 ms, store
    dropped to 46.9 MB). Skipped on launches inside the 30-day
    window. Tracked via `UserDefaults` key `yawac.lastDBVacuum`.
  Runs from a `Task.detached(priority: .utility)` after
  `SwiftDataIndexes.ensure(at:)` lands. The maintenance connection
  sets `busy_timeout=30000` (longer than F84's whatsmeow 5s window
  because VACUUM is a multi-second operation that wants headroom).
  Logging is via `NSLog` under `[yawac/maint]` so the Diagnostics
  panel + Console.app + `log show` all surface failures. Verified
  hot-path `EXPLAIN QUERY PLAN`:
  ```
  SEARCH ZPERSISTEDMESSAGE USING INDEX yawac_idx_msg_chat_ts (ZCHATJID=?)
  SEARCH ZPERSISTEDREACTION USING INDEX yawac_idx_react_target (ZTARGETMESSAGEID=?)
  SEARCH ZPERSISTEDPOLLVOTE USING INDEX yawac_idx_poll_msg (ZPOLLMESSAGEID=?)
  ```
  All 9 yawac_idx_* indices materialized; no full SCAN remaining.

- ✅ **F83-F84 — Issue #6: messages received while yawac down stay
  missing after reconnect** (v0.10.11) — User report (@feedface,
  GitHub issue #6): "group message does not update if yawac was
  closed and the message read on iPhone. There seemed to be a sync,
  but the message is not there." User-confirmed reproduction:
  yawac down → phone receives message → yawac up → message absent
  in sidebar + scrollback → "Load earlier" and "Full sync" don't
  fetch it → re-pair DOES surface it.
  - **F83 — OfflineSync diagnostic instrumentation.** Added handlers
    for `*events.OfflineSyncPreview` (fires when server announces
    offline-buffered counts) and `*events.OfflineSyncCompleted`
    (fires when drain ends) — bridge/events.go previously had no
    case for either, silently dropping them. New
    `bridge/offline_drain.go` tracker records the announced
    `total/appdata/messages/notifications/receipts` from preview,
    counts each subsequent `*events.Message` and `*events.Receipt`
    arriving during the in-flight window, and logs both to
    `/tmp/yawac-offline.log` so the gap (server said N, got M) is
    visible. GUI app's stderr is detached by macOS Launch Services,
    so a stable file path is used as the diagnostic sink.
    Dispatched as new bridge events `OfflineSyncPreview` /
    `OfflineSyncCompleted` for future Swift-side surfacing.
  - **F84 — `busy_timeout=5000` + `synchronous=NORMAL` on
    whatsmeow's SQLite store.** F83 instrumentation didn't catch
    OfflineSync events firing in a fresh session — drain wasn't
    activating because something further upstream was already
    failing. Inspecting `/tmp/yawac.log` surfaced the actual
    smoking gun: 52 `[whatsmeow ERROR] Failed to store message
    secret keys in history sync: database is locked (5)
    (SQLITE_BUSY)` errors, plus `[whatsmeow ERROR] Failed to
    decrypt prekey message: failed to save identity ... database
    is locked (5) (SQLITE_BUSY)` — meaning the Signal-Protocol
    prekey decryption was dropping incoming messages because the
    identity-save lost the write-lock race. The bridge's
    `openContainer` only set WAL mode; modernc.org/sqlite
    defaults `busy_timeout` to 0, so any concurrent writer
    immediately returned `SQLITE_BUSY` instead of waiting.
    Concurrent goroutines (decryption, history-sync, contact
    reconcile, identity-save) race for the WAL writer slot; the
    loser drops its in-flight message silently. Whatsmeow logs the
    error and skips the message; the bridge never sees a
    corresponding `*events.Message`; yawac never persists it.
    Re-pair works because it wipes Signal state — there's nothing
    to contend with during initial bootstrap. Fix: extend the DSN
    in `bridge/store.go:openContainer` with
    `_pragma=busy_timeout(5000)` so concurrent writers wait up to
    5s for the lock instead of failing immediately, plus
    `_pragma=synchronous(NORMAL)` (the safe WAL pairing — durable
    across app crash, only at risk on power loss within the WAL
    checkpoint window; whatsmeow store losses on power loss are
    acceptable since the phone has the canonical copy). Verified:
    in identical post-launch session, SQLITE_BUSY count dropped
    52 → 1.

- ✅ **F80-F82 — Cold-cache chat-switch residual: avatar preheat,
  preheat budget, raw row id for scrollTo** (v0.10.10) — followups
  to F78+F79. Investigator-driven scan of the residual ~1-2s
  cold-cache freeze surfaced three orthogonal fixes; iterative
  `sample` runs after each landing narrowed the root cause.
  - **F80 — Dedupe sender JID before `canonicalize` in avatar
    preheat.** `ConversationViewModel.buildHistorySnapshot` walked
    the full `messages.reversed()` array calling
    `canonicalize(m.senderJID)` per row. `canonicalize` lowers to
    `JIDNormalize.canonical` → `client.resolveLIDToPN` — a sync
    CGo bridge crossing for every `@lid` sender (~100µs each).
    Large groups paid 2500+ bridge calls (~250ms) even though only
    ~60 unique senders ever cleared the existing
    `seenAvatarKeys` canonical dedupe. Added a raw-JID
    `seenSenderRaw` Set walked BEFORE `canonicalize`, so the
    bridge fires at most ~60 times.
  - **F81 — Trim image+video preheat budget 30 → 20.** Cold
    ImageIO JPEG decode (`AppleJPEGReadPlugin::decodeImageImp`)
    appeared 127 times in the F79 sample. Visible bottom window
    is ~10 rows; 20 covers it with chevron-down headroom while
    ~halving the cold-decode wall.
  - **F82 — Drop explicit `.id(msg.id)` modifier; raw `msg.id`
    in `TimelineItem.id`; migrate jumps to
    `.scrollPosition(id:anchor:)`.** Post-F79 + F80 + F81 sample
    showed `proxy.scrollTo` STILL eating 3882/9567 samples
    (~41%) on unread-anchor chat-opens. Stack chained
    `ScrollViewProxy.scrollTo` → `LazyStack.firstIndex` →
    `_ViewList_Node.firstOffset` → `DynamicBody.updateValue` →
    `ViewBodyAccessor.updateBody` → `MessageRow` body →
    `NSDataDetector.enumerateMatches`. SwiftUI's
    `ForEachState.firstOffset` had to construct every row's
    body to resolve its `.id(msg.id)` explicit modifier value,
    and each body eval ran NSDataDetector for link detection.
    `TimelineItem.id` was prefixed (`"m-\(m.id)"`) so dropping
    the explicit modifier required matching ids — landed
    together: TimelineItem.id for `.message` returns raw
    `m.id`, the `.id(msg.id)` modifier inside ForEach is
    removed, jumps go through a new
    `@State scrollAnchorID: String?` bound to
    `.scrollPosition(id: $scrollAnchorID, anchor: .top)` on the
    ScrollView. Post-fix sample: `ScrollViewProxy.scrollTo` = 1
    sample / 10231 (~0.01%); main thread 30% idle in
    `mach_msg`; remaining time is normal SwiftUI layout work
    (CA::Transaction commit, NSView layoutSubtree, LazyStack
    placement). Cold-cache chat-switch freeze gone. UX shift:
    find/quote hits land at viewport top instead of vertically
    centered — still in view, just not centered.
  Also raced-fixed in F82: synchronously set
  `didInitialScroll = true` before the rewindow Task to prevent
  re-entry of the first-paint branch when the Task's
  `messages = ...` assignment fires another `onChange(of:
  vm.messages.count)`.

- ✅ **F78-F79 — Chat-switch ~10s beachball on large groups**
  (v0.10.9) — User-reported "after long idle, switching between large
  groups is vveeeeeery slow, ~10 seconds". Idle correlation was
  incidental; the freeze reproduced on any chat-open into a large
  group with persisted history near the F31v2 10k-row load cap.
  Two coupled fixes from a `sample`-driven investigation.
  - **F78 — Stop calling `proxy.scrollTo` on the full 10k-row list.**
    First sample (PID 84931, pre-fix) showed 5371/8451 samples
    (~64%) main thread blocked in `ScrollViewProxy.scrollTo` →
    `LazyStack.firstIndex` → `ForEachState.firstOffset` →
    AttributeGraph `input_value_ref_slow` walking every preceding
    row's layout. `ConversationView` had `.defaultScrollAnchor(.bottom)`
    on the ScrollView since F9 but also called `proxy.scrollTo(last
    .id, .bottom)` in three places: first-paint when anchor is the
    last message, count-grew-to-last branch (newCount > lastSeenCount),
    and timelineGeneration onChange (F54 reaction/edit ride-to-bottom).
    All three are redundant — `defaultScrollAnchor(.bottom)` lands
    initial layout at the bottom natively, sticks on append, and
    preserves user offset when scrolled up reading history. Killed
    those three scrollTo calls. F54's atBottom guard and F55's
    explicit atBottom=true post-scroll workaround go away with them.
    `proxy.scrollTo` remains only for genuine non-bottom jumps
    (find/quote hit via `pendingScrollToID`; first-paint when the
    chat has unread or a cached back-pop anchor).
  - **F79 — Rewindow with `beforeCount: 0` for initial non-bottom
    scroll.** Second sample (PID 59476, post-F78) showed the
    beachball had migrated to the F36 rewindow path: 4684/8820
    samples (~53%) still in `proxy.scrollTo` → `ForEachList
    .firstOffset` → `DynamicBody.updateValue` → `MessageRow` body
    → `NSDataDetector.enumerateMatches` (link detection in text
    bubbles). The unread-anchor path called
    `rewindowAround(targetID:)` with the default `jumpWindowSize/2 =
    1250` rows BEFORE the target; `proxy.scrollTo(target, .top)`
    must lay out every preceding row to compute the target's pixel
    offset, and each row body runs NSDataDetector synchronously.
    1250 × NSDataDetector = seconds. Added `beforeCount: Int?`
    parameter to `rewindowAround`; initial-scroll path passes `0`
    so the target lands at slice index 0 and `scrollTo(.top)`
    offset compute is O(0). User sees first-unread at viewport top
    and scrolls down through unread; "Load earlier" surfaces older
    rows on demand. Quote / find jumps keep the centered window
    for scroll-up context.
  - **Result:** third sample (PID 62372, post-F78+F79) shows
    scrollTo down to 717/7774 samples (~9%); 3218 samples (~31%)
    mach_msg idle (event loop responsive). Residual ~1-2s cold-
    cache freeze on truly cold groups (SwiftData faults +
    `applejpeg_decode` cold ImageIO) tracked as a separate
    investigation — different fix surface (preheat tuning, eager
    contact-map fetch, avatar decode prewarm).

- ✅ **F77 — Stale "typing…" indicator after received message**
  (v0.10.8) — User reported the peer presence dot/bubble would
  appear after an inbound message arrived even though the sender
  wasn't typing, and would stay stuck until app relaunch.
  Root cause: `vm.peerTyping` was set directly from each
  `.chatPresence` event with no TTL or fallback timer. WhatsApp's
  protocol expects the sender's client to refresh the `composing`
  state every ~10s while the peer is actively typing, and to send
  a `paused` packet on stop. If the `paused` packet is dropped
  (network blip, sender app backgrounded mid-type, socket
  reconnect, message + composing bundled together with paused
  lost) the indicator sticks because no further event resets it.
  Fresh ConversationViewModel on chat-switch defaulted
  `peerTyping = false`, which explained the relaunch / chat-swap
  workaround.
  Fix: introduced `ConversationViewModel.setPeerTyping(_:)` with
  a 15s auto-clear `Task` re-armed on every `true` event and
  cancelled on every `false`. 15s = 1.5× whatsmeow's composing
  refresh cadence — keeps the indicator alive through a missed
  refresh from active typing but self-heals dropped `paused`.
  `peerTyping` is now `private(set)`; the single existing write
  site in `ConversationView`'s event loop routes through the new
  setter. Deinit cancels the timer alongside the existing
  ingest-flush task.

- ✅ **F76 — Hotfix: launch crash from F73 dock policy in App.init()**
  (v0.10.7) — v0.10.6 shipped with `NSApp.setActivationPolicy(...)`
  called from `YawacApp.init()`. NSApplication isn't ready that
  early in the SwiftUI lifecycle (App.init() runs before
  NSApplicationMain has installed `NSApp`), so the call tripped a
  Swift runtime assertion (`EXC_BREAKPOINT` / `_assertionFailure`)
  and the process exited immediately on launch. Existing
  v0.10.5 / v0.10.6 users auto-updating via Sparkle hit a
  launch-loop until the hotfix lands. Moved the activation-policy
  read+apply into the `WindowGroup`'s `.onAppear`, alongside the
  menu-bar bind+enable that already used that pattern for the same
  reason. Init now only sets up `ModelContainer` + spawns the
  detached prune/index/etc. tasks, no `NSApp` touch.

- ✅ **F72-F75 — Single-instance + settings wiring + per-chat mute**
  (v0.10.6) — bundle.
  - **F72** — `LSMultipleInstancesProhibited = true`. Stops macOS
    from spawning a second yawac process when the user taps a
    notification and Launch Services routes activation to a stale
    bundle path (5+ register entries from build artifacts over
    the dev's lifetime).
  - **F73** — four Settings toggles now actually do something:
    `yawac.notifications.enabled` gates `NotificationService.notify`
    early-return; `yawac.notifications.preview` blanks the body
    field but keeps the title; `yawac.notifications.sound` selects
    Default / Pop / Glass / None via `UNNotificationSound(named:)`;
    `yawac.dock.keep` flips `NSApp.activationPolicy`; `yawac
    .menuBar.show` mounts an `NSStatusItem` (click → main window
    forward — placeholder for future Menu-bar Quick-Send popover);
    `yawac.launchAtLogin` register/unregister via
    `SMAppService.mainApp`. `.onAppear` re-syncs the launch-at-
    login AppStorage value from system truth so a manual
    System Settings removal doesn't leave the toggle stuck on.
  - **F74** — per-chat mute customization. `PersistedChat` gained
    `bellEnabled: Bool = true` (lightweight migration — plain
    default-value Bool, no `#Index`). ChatInfoView gained a
    Sound toggle and a Mute → "Until…" `DatePicker` for
    arbitrary expiry. Existing 8h / 1w / Always presets stay.
    Bell-off renders banners silent; mute still suppresses
    banners entirely — independent knobs.
  - **F75** — `NotificationService.buildNotificationContent`
    extracted as a pure function taking `NotificationPrefs`. All
    side-channel state (per-chat bell + global toggles) flows in
    as parameters so the gating matrix is unit-testable without
    `UserDefaults` mocking. 8 XCTest cases cover the matrix.

- ✅ **F64-F71 — Bundle: notif reply + IQ instrumentation +
  battery-drain fixes + business chats** (v0.10.5) — large bundle
  out of one investigation session driven by user-reported phone
  battery drain + invisible WhatsApp Business chats.
  - **F64 — Reply from native notification.** Banner exposes
    inline Reply text-input action; typing + Send dispatches via
    bridge without bringing yawac front. UNNotificationCategory
    "MESSAGE" + UNTextInputNotificationAction, handler routes to
    `client.sendText` in `Task.detached`.
  - **F65 — Bridge call-count instrumentation.** Per-method
    invocation counter on `WAClient` (NSLock-protected, nonisolated
    bump); exposed via `callCountsSnapshot()`. Powered the F67-F70
    investigations.
  - **F66 — Diagnostics panel UX.** Replaced per-section refresh /
    reset buttons with a single top-of-panel toolbar (Refresh all
    / Reset counters / Copy as JSON). JSON dump for paste-into-
    bug-report. Includes window_started_at + window_seconds so
    counts come with a measurement window.
  - **F67 — Session-wide media-retry dedupe.** Same broken
    message no longer re-issues `requestMediaRetry` IQ on every
    chat-switch (set lived per-CVM, wiped on swap; now lives on
    SessionViewModel for process lifetime). Cut retries 875 → 331
    in same session.
  - **F68 — Always-mark-expired on retry failure.** Previously
    only specific error strings ("phone retry returned no path",
    "403/404/410", "sha mismatch") flipped `mediaExpired`; all
    other failures left the flag unset so the next chat-open
    re-tried. Phone has already said no — mark it regardless.
  - **F69 — Snapshot `downloadTargets` cap (12 newest media).**
    Each chat-open used to kick a download for every media-
    bearing message in the visible window; most failed (server
    aged the bytes out), each kicked a retry IQ. Cap at 12;
    older media surfaces a "tap to load" state via downloadErrors
    + the existing per-row retry button.
  - **F70 — `autoRefetchExpiredBatch` cap (12 newest expired).**
    Mirror of F69 for the expired-refetch path that fires once
    per chat-open after the requestOlderHistory anchor returns.
    Combined effect: 875 → 86 retries in equivalent sessions
    (~90% cut; phone banner blink + battery drain proportional).
  - **F71 — WhatsApp Business message classification.** Bridge
    `classifyKindUnwrapped` returned `"system"` for any unhandled
    type, and `history.go` drops `"system"` rows before persist
    — so InteractiveMessage / TemplateMessage / ButtonsMessage /
    ListMessage / OrderMessage / ProductMessage / InteractiveResponse
    / ListResponse / TemplateButtonReply / ButtonsResponse /
    HighlyStructured ALL got dropped silently. Business chats
    looked empty (PersistedChat shells with zero
    ZPERSISTEDMESSAGE rows). Added classifier cases mapping all
    11 to `"text"` + `bestEffortBusinessText(...)` helper that
    pulls the best human-readable body via the per-type
    accessors. Business chats now appear with their actual
    message content.

- ✅ **F63 — File drag-drop into composer sent the link, not the
  file** (v0.10.3) — dragging an image from Finder onto the
  conversation pasted the `file://...` URL into the message body
  instead of staging the image as an attachment. Root cause:
  ConversationView mounted `.onDrop(of: [.fileURL])` on the outer
  pane, but SwiftUI's `TextField` (NSTextField under the hood)
  has an AppKit-level `NSDraggingDestination` that consumes URL
  drops first and inserts the URL as text. The SwiftUI drop
  modifier never fired. Fix: mount `.onDrop(of: [.fileURL])` on
  the composer's outer `VStack` (the parent of the TextField) so
  the drop is caught before AppKit's NSTextField handler. The
  drop routes through the same `vm.stageAttachment(at:)` the
  paperclip button uses, so image / video / audio / document
  classification falls out of `attachmentKind` automatically.

- ✅ **F62 — Kill RightClickCatcher per-row updateNSView storm**
  (v0.10.2) — Plan B from the stability/debt wave. Samples during
  full-history-sync showed `RightClickCatcher.updateNSView` +
  `TimelineItem.id.getter` × N as the dominant beachball source:
  any mutation to `vm.receiptStatus` / `reactionsBySender` /
  `localPaths` (all `@Observable` dicts) invalidates every
  observer regardless of which key changed, so every visible
  MessageRow re-evaluated its body on every receipt event, and
  each re-eval fired an AppKit bridge call to update the
  right-click catcher overlay's closure.
  First attempt — `MessageRow: Equatable` + `.equatable()` at the
  ForEach callsite — broke LazyVStack's lazy materialization,
  causing a ~15s pause on chat switch as SwiftUI eagerly compared
  every row. Reverted.
  Landed shape — `StableRightClickOverlay: View, Equatable` wraps
  just `RightClickCatcher` keyed on `message.id`. `.equatable()`
  on the wrapper short-circuits its subtree when the id is
  stable — `updateNSView` no longer fires on receipt-storm body
  re-evals. The captured closure holds Bindings to MessageRow's
  per-row `@State contextMenuAnchor` / `showContextMenu`, both
  per-identity stable across body evals, so a stale closure still
  resolves the right popover anchor. Chat-switch path
  unaffected (id changes → `==` false → re-renders); LazyVStack
  laziness preserved (only the overlay subtree is equatable).

- ✅ **F61 — Diagnostics inspector panel** (v0.10.1) — read-only
  `Settings → Diagnostics` view to surface internal state when a
  user reports a bug. Built first in the stability/debt wave
  before refactoring the conversation re-render storm (Plan B)
  so future investigations have data instead of guesses. Four
  sections:
  - **Sync state**: `fullSync.{inFlight,attempted,progress,chunks,
    fresh,dupe}`, the `historyBackfillCompleted` UserDefaults
    flag, connection state, syncing banner.
  - **JID lookup probe**: paste any JID; see `JIDNormalize.bare`,
    `JIDNormalize.canonical` (LID→PN translated), and
    `session.displayName(for:)` results live. Confirms where a
    name lookup falls through (bare miss vs canonical miss vs
    fallback prefix).
  - **SQLite indices**: ✅/❌ per `yawac_idx_*` index expected by
    `SwiftDataIndexes.ensure`. Catches the "F45 raw-SQL fallback
    didn't fire" regression class quickly.
  - **Stored history stats**: total persisted messages, distinct
    chats, oldest/newest timestamps, distinct senders, distinct
    senders with non-empty push-name, push-name coverage %. Plus
    a refresh button — the queries cost ms but bound the rate to
    user taps.
  No mutation, no side-effects; all `sqlite3_open_v2 READONLY`
  one-shots on `.onAppear`. Skipped wiring to `SwiftDataIndexes
  .statements` because it's `private` — duplicated the nine names
  with a sync-required comment.

- ✅ **F60 — Recognizable fallback for unresolved @lid senders**
  (v0.10.0) — group participants without any name source (no
  push-name in PersistedMessage, no entry in
  `whatsmeow_contacts`, not delivered by any PUSH_NAME chunk) used
  to render as raw 15-digit `@lid` numbers in the inspector
  participants list — confused users into thinking yawac dropped
  data. The 4-phase systematic-debug investigation confirmed those
  rows ARE in `whatsmeow_contacts` but with all name fields empty,
  and there's no companion-device API that fetches push-names for
  arbitrary JIDs from the server (phone WhatsApp learns names from
  message activity older than what ships to companion).
  `SessionViewModel.displayName(for:)` now uses the LID→PN
  canonical form for the fallback prefix when available, so an
  unresolved `202512137232447@lid` renders as `+3725060015`
  instead of the random LID number. Names still fill in
  retroactively as: (a) the participant sends a new message
  (push-name carried on the live event), (b) a future PUSH_NAME
  chunk includes them, (c) the user saves the contact manually.

- ✅ **F57-F59 — Sync beachball + group-sender JID resolution**
  (v0.9.67) — followups to v0.9.66's deep-history fix.
  - **F57 — Dynamic ingest debounce during full sync.**
    `ConversationViewModel.ingest` flushed every 250ms regardless
    of sync state. With a full-history sync floor delivering
    bursts of messages into a chat the user has open, every flush
    re-evaluated the entire visible MessageRow set; the
    `TimelineItem.id.getter` × N + `RightClickCatcher.updateNSView`
    × visible-rows cost beachballed the UI. Now `chatList?
    .session?.fullSync.inFlight` gates the debounce: 250ms during
    normal traffic, 2000ms during sync. Open conversation gets
    one big batch update per 2s window instead of constant
    dribble.
  - **F58 — Push-name ingest on history load.**
    `buildHistorySnapshot` now extracts each PersistedMessage's
    `senderPushName` into a `pushNames: [String: String]` field
    on `ConversationHistorySnapshot`.
    `applyHistorySnapshot` ingests them into
    `session.contactNames` via `ingestPushName(jid:name:)`. Group
    senders whose push-names landed at message intake time but
    never made it into `contactNames` (history loaded before the
    sender's message arrived in the live stream) now resolve on
    chat open.
  - **F59 — PUSH_NAME chunk → Swift event ingest.** PUSH_NAME
    history-sync chunks carry batches of `{jid → pushname}` pairs
    that bridge persisted to whatsmeow's local Contacts store but
    never told Swift about. Names became visible only after a
    `listContacts()` reconcile, and even then only at @s.whatsapp
    .net form — `@lid`-sender lookups missed when the LID→PN map
    had no entry. New bridge dispatch `"push_names"` event emits
    each chunk's `[(jid, name)]` batch verbatim;
    `ContentView.swift` calls `session.ingestPushName` per pair
    so names land at the exact JID form whatsmeow received
    (typically the same `@lid` form the senderJID will use).

- ✅ **F56 — Deep-history backfill skipped on fresh install**
  (v0.9.66) — pair fresh, see only the INITIAL_BOOTSTRAP chunk's
  messages, never the years of history the phone has. Root cause:
  `requestHistoryBackfillIfNeeded` guarded on an existing oldest
  PersistedMessage row to use as an anchor; with zero messages
  the function flipped `historyBackfillCompleted = true` and
  early-returned without sending the request. But the type-6
  `FULL_HISTORY_SYNC_ON_DEMAND` packet doesn't use an anchor —
  bridge sets `HistoryFromTimestamp = now` +
  `HistoryDurationDays = count`. Anchor fields exist only for
  source-compat. Fix: always send the request after the one-shot
  gate, passing empty anchor strings when no persisted row exists.
  Fresh users now get the deep history pull (up to 10 years) on
  first reconnect after pair, same as existing installs.

- ✅ **F49v2 + F55 — Typing-inset + chevron stuck visible**
  (v0.9.65) — followups to the v0.9.64 typing-indicator + reaction
  scroll fixes.
  - **F49v2** — original F49 reserved bottom padding on the
    LazyVStack AND kept the typing indicator as a sibling outside
    the ScrollView. The two shifts compounded: ~30pt of empty
    space appeared between the last message and the typing
    indicator, and `BottomVisibilityTracker`'s
    `onAppear/onDisappear` semantics on the last row broke
    (chevron-down stuck visible). Moved the typing indicator into
    a `safeAreaInset(edge: .bottom)` on the ScrollView; SwiftUI
    handles the content inset automatically. No more
    double-spacing.
  - **F55** — `BottomVisibilityTracker` swaps its branches when
    `isLast` flips on a new tail row. In a LazyVStack the new
    last row's `onAppear` is unreliable (often skipped if the row
    was offscreen at append time), so even after `proxy.scrollTo`
    put the row in the viewport, `atBottom` could stay `false` →
    chevron-down visible despite the user actually being at the
    bottom. Both auto-scroll paths (`messages.count` and
    `timelineGeneration` follows) now explicitly set
    `atBottom = true` after their `scrollTo`.

- ✅ **F48-F54 — Live-test bug bundle** (v0.9.64) — fresh-pair
  testing surfaced seven independent bugs; bundled into one release
  to keep cadence sane.
  - **F49 — Typing indicator clipping the bottom message.** When
    the "typing…" indicator appeared below the ScrollView, the
    ScrollView's frame shrank and the last bubble sat under the
    new edge. Reserve the indicator's height inline via
    `.padding(.bottom, vm.peerTyping ? 32 : 8)` on the LazyVStack
    so the last row stays visible.
  - **F50 — "All" scope segregating directs below groups.** Fresh
    direct messages never bubbled to the top of the All tab
    because the scope rendered Pinned → Communities → Groups →
    Direct as fixed sections; a brand-new DM landed at the top of
    the Direct *section*, far below all the groups. All now
    renders a single timeline-sorted "Chats" section (matches the
    native client). Community parents keep their sub-group
    indented grouping inline. Direct / Groups / Communities
    scopes still segregate by type.
  - **F51 — Optimistic send.** Native WhatsApp paints the
    outgoing bubble + clears the composer the instant you press
    Enter; yawac stalled until the synchronous CGo bridge call
    returned. Composer is now cleared first; a placeholder
    UIMessage (id `local:<UUID>`) is appended + `receiptStatus =
    .sent` so the bubble paints instantly; the bridge call runs
    inside `Task.detached`. When it returns, the temp row is
    replaced with one carrying the real bridge-assigned messageID
    so future receipts route correctly. Errors roll back the
    optimistic row + restore composer state. `WAClient.sendText`
    made `nonisolated` to match `sendTextReply`.
  - **F52 — Receipt-batch debounce.** Every inbound receipt event
    wrote `receiptStatus[id] = status` per messageID, and the
    SwiftData / Observation graph invalidates every observer of
    the dict on every subscript write. During sync bursts that
    pegged main with body re-evals. Now pending receipts queue
    into a 50ms flush window that collapses to one merged write
    per id (sent→delivered→read upgrades resolved before commit).
  - **F53 — System / protocol envelopes overwriting chat
    preview.** Bridge emits encryption-key-changed events with
    non-empty `text` ("Encryption key with X@lid changed.") and
    `kind == "system"`. Preview path checked text first, so the
    sidebar last-message line filled with churny system text
    instead of the real last message. `applyChatRowUpdate` now
    early-returns for `kind == "system" || "protocol"` — preview,
    timestamp, and unread bookkeeping all skip. History still
    persists these rows via the writer pipeline.
  - **F54 — Auto-scroll on reaction.** Adding an emoji reaction
    extended a message bubble's content (reaction strip below the
    bubble) but didn't bump `messages.count`, so the existing
    `.onChange(of: vm.messages.count)` scroll-to-bottom hook
    never fired. `applyReaction` now calls `invalidateTimeline`,
    and ConversationView watches `vm.timelineGeneration` —
    re-anchors to bottom only if the user was already at the
    bottom (won't yank them back if scrolled up reading history).

- ✅ **F48 — Added-contact name reverting to JID** (v0.9.64) — after
  user added a contact via the "Add to contacts…" sheet, the
  sidebar row updated to the chosen name immediately, but the
  conversation header + inspector pane kept showing the raw phone
  JID. Two bugs in `SessionViewModel.ingestContacts`:
  1. **Unconditional empty-name overwrite.** `contactNames[c.jid] =
     c.name` ran for every contact returned by `client.listContacts()`
     during the F19 history-sync reconcile. For freshly-added
     contacts whatsmeow hasn't echoed the locally-set name back from
     the server yet, so the bridge contact row's `name` field is
     empty — overwriting the `applyIncomingContact`-deposited
     "Boris Tobotras" with `""`. Now guards on `!c.name.isEmpty`.
  2. **Missing bare-key normalization.** Write path used
     `contactNames[c.jid]`; read path (`displayName(for:)`) uses
     `contactNames[bare]`. For device-suffixed sender JIDs the keys
     never collided. Both sides now go through `JIDNormalize.bare`.

- ✅ **F46-F47 — Sidebar freeze + fresh-pair UX + sync-burst beachball**
  (v0.9.63) — bundle of perf/UX fixes targeting Boris's
  splitter-during-sync freeze and three fresh-install bugs
  observed during paired-from-scratch testing. Original freeze
  report (RU): «Запускаю yawac, появляется баннер „Syncing
  history", тащу разделитель сайдбара вправо — всё подвисает
  намертво».
  1. **Memoize chat-list display rows.** `ChatListView.body` used
     to call an O(C) filter/sort/group builder on every body
     eval. During a splitter drag SwiftUI re-evals body at
     gesture-event rate; with 1.5k chats the per-frame O(C) pass
     pegged main. Renamed to `rebuildDisplayRows()` and cached
     output in `@State cachedRows`. Rebuild fires from `.onChange`
     wires on every input (`vm.chats`, `vm.inviteLinkPreview`,
     `search.query`, `search.filteredChats`, `search.suggestion`,
     `search.messageHits`, `search.filters`,
     `search.globalChatFilter`, `archivedExpanded`, `scopeRaw`)
     plus a `.task` for initial population. Splitter drags now
     touch zero builder work.
  2. **NavigationSplitView sidebar width default.** Fresh installs
     opened with a too-narrow sidebar (~150pt) that truncated
     chat names to "Yritin s..." / "PINN...". Added
     `.navigationSplitViewColumnWidth(min: 240, ideal: 300, max:
     420)` to the sidebar column. macOS persists user-resized
     width per-window after first launch.
  3. **Groups re-fetch in history-sync reconcile.** Fresh paired
     accounts showed raw JIDs (`358407236636-1495133272@g.us`)
     in the chat list because the initial app-state sync hadn't
     completed by the time `groups.refresh()` ran once at
     pairing. Added a second `client.listGroups()` off-MainActor
     fetch inside `SessionViewModel.scheduleHistorySyncReconcile`
     (the 250ms/5s-debounced reconcile pass that already
     re-fetches contacts). `mergeGroups` updates existing chats
     in place — names land, `isCommunityParent` flag lands, so
     the Communities scope tab populates too. Also marked
     `WAClient.listGroups()` `nonisolated` to match
     `listContacts()` so it can run off MainActor.
  4. **Conversation ingest debounce 50ms → 250ms.** Opening a
     chat during heavy initial-sync ingest beachballed the UI:
     every batched `messages.append` re-evaluated every visible
     `MessageRow`, and each row's `RightClickCatcher`
     NSViewRepresentable ran `updateNSView` at sync-event rate
     (~600 calls/s). Bumping the existing ingest-flush coalesce
     window from 50ms to 250ms cuts re-render rate 5× during
     burst sync while feeling instant for normal traffic
     (network latency dwarfs the extra 200ms anyway).
  Note on what was tried + reverted: an explicit
  `.frame(height: row.fixedHeight)` on each chat-list row caused
  SwiftUI to enter a recursive `StackLayout.placeChildren` loop
  that hard-froze the app on cold start. Reverted; LazyVStack
  measures intrinsic row size for now.

- ✅ **F45 — drop VersionedSchema, manage indices via raw SQL only**
  (v0.9.62) — emergency hotfix for v0.9.61. The VersionedSchema +
  lightweight migration approach from F44 crashed at launch on
  affected users with `NSInvalidArgumentException: 'Duplicate version
  checksums detected.'`. Root cause: `#Index<T>` declarations don't
  enter SwiftData's entity attribute graph, so V1 (no index) and V2
  (with index) compute identical CoreData entity checksums; CoreData
  rejects the migration plan as malformed. The crash didn't surface
  on the developer machine because of latent V2 metadata from an
  earlier attempt; only clean v0.9.60 → v0.9.61 upgrades hit it.
  1. Removed `PersistedMessageSchemaV1`, `PersistedMessageSchemaV2`,
     and `PersistedMessageMigrationPlan`. Reverted `yawacApp.init()`
     to the unversioned `ModelContainer(for: PersistedMessage.self,
     …)` variadic.
  2. Removed all three `#Index<T>` declarations from
     `PersistedMessage.swift`. The macro is unsalvageable for
     already-shipped models: bare addition destroys rows (v0.9.59),
     and the VersionedSchema wrapper crashes (v0.9.61). Treat it as
     unavailable for any entity that exists on a user's disk.
  3. Kept `SwiftDataIndexes.ensure(at:)` — this is the part that
     actually works. After `ModelContainer` is built, a detached task
     opens the SwiftData store as raw SQLite and runs `CREATE INDEX
     IF NOT EXISTS` for the nine indices (chatJID / timestamp /
     compound for PersistedMessage; chatJID / targetMessageID /
     timestamp for Reaction; chatJID / pollMessageID / timestamp for
     PollVote). Idempotent + ms-cheap.
  4. Deployment target reverted macOS 15 → macOS 14. With `#Index`
     gone, nothing else in the codebase needed macOS 15.
  Verified: `EXPLAIN QUERY PLAN` for the chat-scoped predicate
  reports `SEARCH ZPERSISTEDMESSAGE USING INDEX yawac_idx_msg_chat_ts`
  (was `SCAN`).

- ✅ **F43 — Revert #Index data-loss + restore macOS 14 support**
  (v0.9.60) — emergency hotfix for v0.9.59. The `#Index<T>` macros
  added to PersistedMessage / PersistedReaction / PersistedPollVote
  in v0.9.59 changed the SwiftData schema hash without a
  VersionedSchema + SchemaMigrationPlan; lightweight migration
  silently dropped every row from those three entities on first
  launch (PersistedChat survived because no index was added).
  Hotfix:
  1. Removed all three `#Index<...>` declarations from
     `PersistedMessage.swift`. SwiftData reads the existing data
     fine without them; chat-scoped fetches go back to full-table
     scans, but the off-main work in F42 still keeps the UI
     responsive.
  2. Reverted deployment target from macOS 15 back to macOS 14 —
     the bump was tied to `#Index` (only available macOS 15+); with
     the macro gone, restoring the broader install base costs
     nothing.
  3. Local recovery for the v0.9.59 affected user: SwiftData's
     `default.store.bak.<unix-ts>` (auto-snapshotted by the F37
     transaction-log prune flow) restored 43.6k rows.
  Follow-up: re-add indices via a proper VersionedSchema /
  SchemaMigrationPlan, gated behind a tested migration path.

- ✅ **F42 — Chat-switch + scroll-to-message responsiveness**
  (v0.9.59) — four coordinated fixes targeting the 1-2s freeze on
  chat switch and message-preview jump:
  1. **Thumbnail preheat decode off MainActor.** Snapshot builder
     (`buildHistorySnapshot`, nonisolated) now runs the ImageIO
     downsample for the visible-window image / video / avatar
     bubbles before returning; `applyHistorySnapshot` does a
     pointer-store into `ThumbnailCache` on main — microseconds
     vs. the prior 600-1200ms on-main decode.
  2. **Per-cache-type revision split.** Single `ThumbnailCache.revision`
     became `imageRevision` / `videoRevision` / `avatarRevision`. Each
     view subscribes only to the revision relevant to its bubble
     kind, eliminating cross-bubble re-eval storms that surfaced as
     "all media + avatars blinking" during chat switch.
  3. **5-minute idle gate on `flushAll`.** F34's instant flush on
     `didResignActive` made every Cmd-Tab return repaint every
     bubble cold; now flush is scheduled for +5min, cancelled on
     `didBecomeActive`. Memory-reclaim survives for genuinely
     backgrounded sessions; quick app switches stay warm.
  4. **SwiftData fetches off MainActor.** `rewindowAround`,
     `requestOlderHistory`, `refreshPollTallies` switched to
     detached background `ModelContext` fetches; only the final
     `messages =` assign stays on main. (v0.9.59 also added
     `#Index<T>` macros for compound indices but they were reverted
     in v0.9.60 — see F43.)
- ✅ **F41 — Sparkle auto-update** (v0.9.56) — Sparkle 2 wired
  end-to-end on top of F40's notarized builds. New SPM dep
  `sparkle-project/Sparkle`. `yawacApp` owns a
  `SPUStandardUpdaterController(startingUpdater: true)` that fires
  a background update check on launch; a "Check for Updates…"
  menu item under the app menu drives a manual check. Info.plist
  carries `SUFeedURL`
  (`github.com/vadika/yawac/releases/latest/download/appcast.xml`)
  and the EdDSA `SUPublicEDKey`. CI release path: `release-edge.sh`
  signs the final dist zip with `sign_update`, emits a single-item
  `appcast.xml` carrying `sparkle:edSignature` + `length` +
  download URL, and the workflow uploads the appcast alongside the
  zip as a release asset. Private signing key lives in the
  `SPARKLE_ED_PRIVATE_KEY` GitHub secret. Update flow:
  user launches yawac → background fetch of latest appcast →
  newer item found → Sparkle verifies the signature with the
  embedded public key → installs in-place.

- ✅ **F40 — Developer ID signing + notarization** (v0.9.55) —
  Cask installs no longer require the `xattr -dr
  com.apple.quarantine` postflight hack; Gatekeeper accepts the app
  on first launch with no prompt. `release-edge.sh` signs with
  `Developer ID Application: Vadim Likholetov (WJ65XC5777)`, then
  `xcrun notarytool submit --wait` + `xcrun stapler staple`. The CI
  release workflow imports the .p12 into a temp keychain from a
  GitHub secret, runs notarytool with an app-specific password, and
  staples the ticket onto the .app inside the dist zip. New
  `yawac/yawac.entitlements` carries the three hardened-runtime
  entitlements the Go runtime (whatsmeow bridge) needs to start
  under codesign: `cs.allow-jit`,
  `cs.allow-unsigned-executable-memory`, and
  `cs.disable-library-validation`. Local dev builds without the
  signing env still fall back to ad-hoc — same `release-edge.sh`
  path. Unblocks Sparkle (next).

- ✅ **F39v2 — adaptive count for at-floor tail** (v0.9.54) —
  After F39's at-floor pruning, deep backfill typically converges on
  1–2 stubborn chats (a large group with thousands of older
  messages) while the rest reach their phone-side floor by round 2.
  With `countPerChat` fixed at 200, those stragglers needed many
  rounds × 60 s wait = ~30 minutes wall-clock to drill, and a tap
  could hit the 30-round cap with the chat still deepening. When
  the residual deepening set is ≤5 chats, `runDeepBackfill` now
  bumps `countPerChat` 200 → 500. whatsmeow's recommended count is
  50; we're already at 200 (4×). Phone may silently truncate above
  some server-side ceiling — no-op if so; ≈2.5× depth per round on
  stragglers if honored.

- ✅ **F39 — at-floor tracking + fresh/dupe sublabel + 30-round cap**
  (v0.9.53) — Systematic-debugging investigation of "full history
  fetch refetches the same messages" found phone was shipping 98%
  new rows per round; perception came from (1) fanning out 152
  per-chat requests every round even after most chats had returned
  no-deeper, and (2) the sublabel showing only `N chunks • M
  messages` with no signal of how many were actually new vs.
  already-in-DB. `runDeepBackfill` keeps a per-chat consecutive
  "did not deepen" counter; after 2 consecutive rounds a chat joins
  an `atFloor` set; subsequent rounds skip it via
  `fanOutPerChatBackfill`'s new `excludeJIDs` parameter.
  `FullSyncState` gains `fresh: Int` + `dupe: Int`; bumped per flush
  from `ChatListViewModel.ingest`. `AccountPanel.fullSyncSublabel`
  shows `N chunks • X new, Y already had` during inFlight and
  `Last run: X new, Y already had across N chunks` idle.
  `maxRounds` bumped 10 → 30; at-floor pruning + the
  zero-deeper exit gate keep healthy syncs short while letting a
  single tap dig deeper into long histories.

- ✅ **F38 — reserve image / video bubble size from sender dims**
  (v0.9.52) — Scrolling through a media-heavy chat showed every
  image bubble drawing in two passes: a 240 × 180 placeholder, then
  the decoded image swapping in at its actual aspect ratio and
  reflowing surrounding layout (user: "I see how the images are
  drawn"). Whatsmeow ships `Width`/`Height` on every `ImageMessage`
  + `VideoMessage`; the bridge was already serializing them and the
  Swift `BridgeMedia` decoder already had the fields. We just
  weren't persisting or rendering them. `PersistedMessage` gets
  `mediaWidth` + `mediaHeight` (lightweight migration; pre-F38 rows
  unaffected). `MessageWriter`'s insert path threads them in; the
  upsert path re-merges them on history-sync replays so older
  persisted-without-dims rows backfill the moment the sender's
  chunk lands again. `UIMessage` mirrors the fields. `MessageRow`'s
  `imageBubble` / `videoBubble` ask a new `mediaBubbleSize` helper
  for the bubble's final rectangle (pinned to 320 × 240 while
  preserving aspect; legacy 240 × 180 fallback when dims are
  missing). Placeholder + decoded paint share the same rectangle —
  the swap is now a content fade-in instead of a layout reflow.

- ✅ **F37 — deep-backfill SwiftData off MainActor** (v0.9.51) —
  Full-history sync had been beachballing through every F30v*
  iteration. A 30 s main-thread `sample` during sync pinned the
  cause: 60% of MainActor time inside
  `SessionViewModel.fanOutPerChatBackfill` running 1033 per-chat
  `FetchDescriptor<PersistedMessage>` calls inline, and 40% inside
  `scheduleHistorySyncReconcile` firing the 6-pass chat reconcile
  loop ≈4×/s on MainActor. `oldestTimestampPerChat` +
  `fanOutPerChatBackfill` now resolve their per-chat anchors in a
  detached `Task` with its own background `ModelContext`, then walk
  the result list back on MainActor only to dispatch the
  already-fire-and-forget peer sends + the throttle sleep. The
  reconcile debounce stretches 250 ms → 5 s during
  `fullSync.inFlight`. `ChatListViewModel.ingest`'s flush bulk-
  publishes `chats[]` via a shadow array (one @Observable publish
  per flush instead of per-outcome) and caches `jid → index` once
  (was O(#chats) `firstIndex(where:)` per outcome). And: the
  SwiftData store had grown to 239 MB, 207 MB of which was the
  CoreData transaction log (ATRANSACTION + ACHANGE) intended for
  CloudKit sync yawac doesn't use; added a startup
  `pruneSwiftDataHistory` task that drops log rows older than 7 days
  via raw `sqlite3 DELETE`. Existing user DBs shrink to actual-data
  size on next launch. Main thread is ~60% idle during full sync
  post-fix (was sub-percent).

- ✅ **F36 — jump-to-quoted re-window + brighter highlight**
  (v0.9.50) — Tapping a quoted-reply chip used to beachball the
  main thread, drop taps entirely, or scroll to a target so
  subtly highlighted that the user couldn't tell anything
  happened. Root cause was SwiftUI's `ScrollViewReader.scrollTo`
  on a LazyVStack with thousands of variable-height rows —
  LazyVStack lazily instantiates rows for paint, but scrollTo
  has to walk and lay out every preceding row to compute the
  target offset; with F31's 10000-row load that meant a multi-
  second main-thread block. `jumpToQuoted` now re-windows
  `messages` to a `jumpWindowSize` (2500) row slice centered on
  the target's timestamp before kicking the scroll; SwiftUI
  only has to scroll within 2500 rows. Cost: prior scroll
  position is replaced by the target window. Highlight bumped
  from 18% / 1.2 s to 45% fill + 2 pt accent outline / 2.5 s
  so the destination is unmistakable. `quotedStrip`'s
  `Button(label:)` swapped for explicit
  `.contentShape(.rect).onTapGesture` — macOS SwiftUI Buttons
  inside LazyVStack-with-thousands-of-rows can lose taps to
  the parent gesture chain. `ConversationView` drops the
  `withAnimation` wrapper around `proxy.scrollTo` —
  interpolating across the unmaterialized gap was a second
  contributor to the freeze.

- ✅ **F35 — inline system notices** (v0.9.49) — yawac filtered
  out protocol + system messages everywhere so the user never saw
  the "encryption key with X changed" + "disappearing messages
  turned on/off" notices that WhatsApp shows inline. Bridge gains
  `dispatchIdentityChange` (server-pushed only — `Implicit=true`
  local untrusted-identity errors skipped) and
  `dispatchEphemeralSystemRow`. The latter wires both the live
  `dispatchMessage` EPHEMERAL_SETTING branch and the historical
  `dispatchWebMessage` path so a HistorySync replay surfaces past
  toggles too. Existing `EphemeralTimerChanged` event preserved —
  the ChatInfoView timer chip behavior is unchanged. Swift ingest
  paths allow `kind="system"` rows with a non-empty `text` body
  through; three snapshot-construction sites and the live
  `UIMessage(_ b: BridgeMessage)` init route `.system` body
  construction through the persisted text when present. Per-chat
  one-shot sweep drops `"system"` from the deleted-kind list.
  `MessageRow.rowContent` special-cases `.system(text)` to render
  in date-separator style — hairlines flanking centered text, no
  bubble — so notices read as in-band rather than as messages.

- ✅ **F34 — flush ThumbnailCache on didResignActive** (v0.9.48) —
  F31 bumped the four NSCache budgets (image 256 MB, video 128 MB,
  avatar 64 MB, map 32 MB = ~480 MB worst case) to stop the
  "all avatars are blinking" eviction storm on the 10000-message
  `LazyVStack`. Side effect: an idle yawac in the background kept
  the full budget resident, and macOS Activity Monitor flagged
  yawac as significant energy use (~2 GB physical footprint).
  Subscribe to `NSApplication.didResignActiveNotification` and
  `flushAll` the four caches + inflight / negative sets when the
  user switches away. The existing on-demand decode path
  transparently repopulates visible bubbles on re-activate.
  `flushAll` is public so a future low-memory hook can call it
  too.

- ✅ **F33 — stable reaction chip order** (v0.9.47) —
  `ForEach(Array(Set(reactions)), id: \.self)` shuffled the chip
  order on every body eval because `Set` iteration order is
  unspecified. Visible as reaction chips "blinking" and the
  reactor count appearing to jump between adjacent emojis (two
  thumbs-up variants observed on a single message). Sort the
  deduped emoji array so the order is stable across renders.

- ✅ **F32 — group bubble redesign + mark-as-read** (v0.9.46) —
  Inbound group messages now mirror the sidebar chat-list rhythm:
  avatar sits to the LEFT of the bubble (28 pt; tap opens DM),
  sender name fills the top-left, and a timestamp overlay hugs
  the bubble's top-right corner regardless of body width.
  `footerView` suppresses the bottom timestamp for inbound group
  rows (it now lives on the header line). Own messages + 1:1
  inbound keep the bubble-bottom timestamp behavior. Bubble width
  follows content — short messages stay narrow, the header
  doesn't pin the row to full width. Also added a "Mark as read"
  item at the top of the sidebar chat-row context menu (shows
  only when `chat.unread > 0`); clears the local counter via
  `vm.markRead`. Useful for chats whose unread was inflated by
  the F30 deep backfill before F31 stopped the inflation.

- ✅ **F31 — full chat load + unread non-inflation + cache budgets**
  (v0.9.45) — three coupled fixes for the user-visible "I ran Full
  history sync but the chat still only shows ~14 months and the
  unread count is in the thousands" report. `loadHistory` now always
  fetches up to `extendedHistoryLimit` (bumped 500 → 10000), so a
  chat with 4242 persisted messages loads them all in one shot
  instead of capping at the F9 60-row chat-switch default. F2 made
  the snapshot build detached so first-paint isn't on the critical
  path; LazyVStack only instantiates the visible window. Anchor
  logic for `unread > messages.count` now lands on `messages.first`
  (oldest loaded) instead of `messages.last` so the user sees the
  deepest unread row, not the bottom.
  `ChatListViewModel.applyChatRowUpdate` no longer bumps
  `chat.unread += 1` for backfill replays — F30's deep multi-round
  ships thousands of OLD messages that all looked "new" to ingest,
  inflating unread counters into the thousands. Now only bumps when
  the message timestamp advances the chat tip (genuine new arrival),
  and new-chat rows only seed `unread = 1` when the first message is
  within ~5 min of now. NSCache budgets sized for the new load:
  image 256 / 64 MB → 1024 / 256 MB, video 256 / 32 MB → 1024 /
  128 MB, avatar 512 / 16 MB → 4096 / 64 MB. Previous budgets
  evicted on every scroll → re-decode storm → "all avatars are
  blinking" as the user observed.

- ✅ **F29+F30 — honest progress + multi-round backfill** (v0.9.44)
  — v0.9.43 progress bar lied (phone reports `progress=100` on
  every ON_DEMAND chunk; first chunk auto-cleared `inFlight` so
  the row blinked) and FULL_HISTORY_SYNC_ON_DEMAND (type 6) is
  silently dropped by the phone on repeat. **F29** drops the
  lying percent: indeterminate `ProgressView()` until phone
  reports something useful; in-flight sublabel switches to
  `Requesting history from phone…` then `<chunks> chunks •
  <messages> messages`; new idle sublabel `Phone replied with no
  new history` distinguishes "never tried" from "tried, got
  nothing." Removed the `progress >= 100` auto-clear; gated
  `armFullSyncTimeout`'s post-sleep clear on `Task.isCancelled`
  so cancelled re-arms don't race fresh chunks back to
  `inFlight=false` (was clearing the flag 2.5 s after the first
  chunk, observed live). Bumped silence-timeout 60 s → 5 min.
  **F30** rewires the button to a multi-round per-chat fan-out:
  each round snapshots `oldestTimestampPerChat`, fires type-5
  `HISTORY_SYNC_ON_DEMAND` with `count=200` per chat
  (fire-and-forget so dispatch isn't blocked by SendPeerMessage
  latency), waits 60 s for the F3 batched writer to commit,
  re-samples. Loops up to 10 rounds; exits early when no chat
  got deeper. Type-6 still fires once per tap as
  belt-and-suspenders. Live run on a 152-active-chat account:
  1560 chunks, 3806 messages added across 7+ rounds before the
  phone exhausted its reachable history.
- ✅ **Crash fix — Dictionary(uniqueKeysWithValues:) on dupes**
  (v0.9.44) — F30's overlapping per-chat windows re-delivered
  the same message id across rounds.
  `ChatListViewModel.ingest`'s outcome-pairing dictionary
  panicked with `Fatal error: Duplicate values for key`. Swapped
  four call sites in `ChatListViewModel` + one in `ChatListView`
  to `Dictionary(_:uniquingKeysWith:)` keeping the first.

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
