# Reverse-engineering the WhatsApp media-retry protocol

Briefing for the agent / contributor who picks up the unresolved
group-history-media decryption gap left at the end of the
`media: cool-down + auto-refetch for expired history bytes` and
related commits (v0.1.0+b6868f5).

## The exact gap

For LID-addressed group history media, `Client.MediaRetry` events sometimes
fail to decrypt with whatsmeow's existing key derivation:

```go
gcmutil.Decrypt(
    hkdfutil.SHA256(mediaKey, nil, []byte("WhatsApp Media Retry Notification"), 32),
    evt.IV,
    evt.Ciphertext,
    []byte(evt.MessageID),
)
```

Two failure modes observed in production (yawac builds on whatsmeow):

| Mode | Symptom | Cipher size | What it means |
|---|---|---|---|
| A | `failed to decrypt notification: cipher: message authentication failed` | 215–271 B | Our HKDF inputs don't produce the GCM key the phone used. |
| B | Decrypt OK, `result=NOT_FOUND` | 40–42 B | Phone parsed our receipt fine; can't find the (msgID, participant) tuple. |

Mode B proves the standard mediaKey-only derivation IS correct for SOME
rows (key matches), so the failure isn't blanket-wrong-key. Six salted
HKDF variants using `whatsmeow_message_secrets.key` (the per-message
32-byte secret WhatsApp stores) as input in different positions, with
varying AAD shapes (msgID, msgID||sender), all failed to decrypt Mode A
rows. So the protocol detail — if it exists — is not the obvious
"throw messageSecret at HKDF" recipe.

Empirically, **re-pairing the client recovers the affected media** —
the primary device re-emits history-sync with current keys, which our
upsert path now persists. So the bytes exist on the phone; the linked
device's cached key is stale, and there's a wire format we haven't
mapped that the phone uses to resolve this without a re-pair.

Baileys (`Utils/messages-media.ts`), mautrix/whatsapp
(`pkg/connector/mediarequest.go`), and whatsmeow upstream main are
byte-identical here. None of them recovers Mode A either. Confirmed
2026-05-27.

Related closed-as-not-planned upstream report covering the upstream
403-on-old-media symptom: https://github.com/tulir/whatsmeow/issues/933

## Goal

Identify the wire-level delta between

- what whatsmeow's `SendMediaRetryReceipt` emits / `DecryptMediaRetryNotification`
  expects, AND
- what WhatsApp Web actually sends and successfully consumes for the
  same kind of message,

then upstream a patch (or carry it in our fork).

## Why our earlier browser-based attempts failed

Documented for context — don't repeat these without changing approach:

1. WhatsApp Web obfuscates everything. No `window.Store`, no exposed
   debug context, no enumerable webpack chunks. The Meta `__d`/`require`
   module system doesn't expose its registry.
2. Every WebSocket frame is Noise-XX encrypted (32-byte handshake +
   AES-GCM transport). Reading raw `ws.send`/`ws.message` bytes via JS
   gives noise ciphertext — useless without the static + transport
   keys, which live in the bundled JS's private closure.
3. The MCP browser tool's content filter blocks `require.toString()` /
   any function source dump containing WA Web's runtime strings — can't
   even extract the JS to grep it for module names.

## Approach that should work

Two paths, ordered by deterministic-ness.

### Path 1: SSLKEYLOG + Wireshark + offline noise decoder

1. **Install** `mitmproxy` (only for keylog tee, not interception), plus
   Wireshark with WebSocket dissector enabled.
2. **Launch Chrome** with `SSLKEYLOGFILE=/tmp/wa-ssl.log` env var. On
   macOS:
   ```
   SSLKEYLOGFILE=/tmp/wa-ssl.log /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --user-data-dir=/tmp/wa-profile
   ```
3. **Capture** all traffic on the local interface with `tshark -w wa.pcap`
   or Wireshark UI. Filter on `host web.whatsapp.com` ports 443/5222.
4. **Open `https://web.whatsapp.com`** in that Chrome, scan QR on the
   same phone account yawac is paired to.
5. **In Wireshark**: Preferences → Protocols → TLS → "(Pre)-Master-Secret
   log filename" → `/tmp/wa-ssl.log`. Reload the capture. TLS frames
   decrypt to WebSocket frames.
6. **Trigger the failing retry** on WA Web: open the same group
   identified in the project memory file (`358504641733-1599296792@g.us`),
   scroll to a message yawac flags `mediaExpired`, click the broken
   media bubble or wait for WA Web to auto-issue a retry. Capture the
   outbound `<receipt type="server-error">` frame and the inbound
   `<notification>` response.
7. **Decode** the captured frames offline. Pipeline:
   - **Noise layer**: extract keys from `/tmp/wa-ssl.log` correlated to
     the WA Web session. Pass to a small Go program that builds
     `flate.NewReader` (WA's transport uses lz4-style framing inside the
     noise envelope — see `whatsmeow/socket/noisesocket.go`) and the
     CipherStates from the captured handshake transcript. Reuse
     `whatsmeow/socket.NoiseHandshake` types directly.
   - **Binary node layer**: feed decoded bytes to
     `waBinary.Unmarshal(...)` — that's whatsmeow's exported decoder
     for WA's custom token-compressed XMPP. Produces a `Node` tree
     with all attrs.
   - **Diff** the resulting `<rmr>` / `<encrypt>` / `<enc_p>` / `<enc_iv>`
     attribute set against whatsmeow's `SendMediaRetryReceipt` emission.
   - **Diff** the `<notification>` ciphertext + IV against our `evt.IV`
     and `evt.Ciphertext`. Identify the actual GCM key + AAD by brute
     force only after you know the expected plaintext (proto-encode a
     `MediaRetryNotification{StanzaID, DirectPath, Result=SUCCESS}` and
     check which HKDF inputs derive a key that AES-GCM-encrypts to the
     captured cipher).

### Path 2: Hook WA Web's own send pipeline

If Path 1's Chrome session refuses to issue retries (WA Web sometimes
caches aggressively and won't retry), inject into Chrome before WA Web
boots. Use a Chrome extension with `"run_at": "document_start"` that
monkey-patches `__d` to log all module definitions to `localStorage`,
then opens the failing chat. Search `localStorage` dump for module
factories whose source contains the literal string `"WhatsApp Media
Retry Notification"` — that's the `info` byte string used in HKDF and
will pin down the right module within minutes. Read that module's
source to see what it passes to its HKDF / AES-GCM primitives. The
patch lands in whatsmeow's `mediaretry.go` based on what you find.

The extension approach was attempted via the MCP browser tool's
runtime injection — too late in the page lifecycle. A real extension
running at `document_start` will catch modules registered during the
initial bundle parse.

## What "done" looks like

A patch (probably to `vendor/whatsmeow-fork/mediaretry.go`) that:

- Changes `getMediaRetryKey` or `DecryptMediaRetryNotification` to
  consume whatever extra input WA Web uses (likely the per-message
  secret, possibly combined with the chat JID or own JID, possibly
  via a different HKDF info string).
- Decrypts the existing Mode A samples we captured (msgIDs in
  `~/.claude/projects/.../memory/project_whatsmeow_group_media_retry.md`).
- Doesn't regress 1:1 chats or the existing working group rows.
- Includes a Go test in `mediaretry_test.go` that pins the derivation
  against captured `(mediaKey, messageSecret, IV, ciphertext,
  expectedPlaintext)` vectors.

Then: open a PR upstream at `tulir/whatsmeow` referencing both
issue #933 and our diagnostic note. While waiting for merge, apply as
a third entry in `docs/whatsmeow-patches.md`.

## Validation in yawac

Once the fork carries the fix:

1. `./scripts/build-xcframework.sh && xcodebuild -scheme yawac build`.
2. In a chat with known-expired group media, click **Refetch** on a
   bubble. Watch `/private/tmp/yawac.log`:
   - Old behavior: `[yawac/media-retry] handle msgID=… cipher=215B`
     followed by `mediaExpired` latch.
   - New behavior: standard `DecryptMediaRetryNotification` returns
     `result=SUCCESS` with `directPath`; yawac re-downloads, plaintext
     SHA verifies, bubble renders.
3. If you want a second test surface, the auto-burst that fires once
   per chat session at `ConversationViewModel.autoRefetchExpiredBatch`
   will retry every `mediaExpired` row in that chat. Most should clear.

## Out of scope

- Don't redesign the cool-down / Refetch / auto-burst architecture.
  It's the correct client-side ceiling regardless of what wire-format
  delta we find.
- Don't reintroduce the LID→PN canonicalization in
  `SendMediaRetryReceipt`. Reverted in commit `030ea2a` after
  confirming mautrix's behaviour and diagnosing that both forms got
  the same NOT_FOUND.
- Don't open a yawac-side issue against tulir/whatsmeow until you have
  concrete wire captures — issue #933 was closed without action and a
  duplicate symptom report wastes the maintainer's time.
