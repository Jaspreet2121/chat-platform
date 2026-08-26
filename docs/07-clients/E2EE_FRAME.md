# E2EE sealed-frame spec (108) — NORMATIVE

This is the authoritative wire spec for secret-chat sealed messages. The web client implements it;
the Android client MUST reimplement from THIS document without reading the web code. If code and
this file disagree, this file is wrong or the code is — reconcile before shipping either.

Trust root: the device-key registry (107). Each device has an Ed25519 signing keypair and an X25519
agreement keypair; the public halves live in `device_keys` (`GET /api/v1/keys/users`), the private
halves never leave the device.

## 1. Alg string

The `sealed.alg` value stored on the wire is EXACTLY:

    xsalsa20poly1305-sealedbox+ed25519

- `xsalsa20poly1305-sealedbox` = libsodium `crypto_box_seal` (an anonymous sealed box: an ephemeral
  X25519 keypair per box, XSalsa20-Poly1305 authenticated encryption, recipient X25519 public key
  only — no sender key inside the box).
- `+ed25519` = an Ed25519 detached signature over the canonical cleartext bytes (§2), providing
  sender authenticity that the anonymous box deliberately does not.

A receiver MUST reject a frame whose `alg` it does not implement.

## 2. Canonical cleartext bytes

The cleartext of a sealed text message is this object, with fields in THIS FIXED ORDER (never
alphabetical, never source-object order):

    v                (integer, always 1)
    sender_user_id   (string, uuid)
    sender_device_id (string, the sender's device_id)
    conversation_id  (string, uuid)
    client_msg_id    (string, uuid — also the 107 idempotency key)
    composed_at      (string, ISO 8601 UTC, millisecond precision, e.g. 2026-08-26T09:00:00.000Z)
    message_type     (string, "text" — the only v1 sealed content type)
    body             (string, the plaintext message)

Canonicalization rule (deterministic across engines):

1. Build a JSON object with exactly the eight keys above, in the order above.
2. Serialize with the platform's DEFAULT compact JSON (no inserted whitespace; standard JSON string
   escaping only). On JS this is `JSON.stringify(orderedObject)`.
3. UTF-8 encode the resulting string.

There are no floats, no nested objects, and no optional fields in v1, so no canonical-JSON library
is required — the fixed key order plus compact JSON plus UTF-8 is fully specified.

Fixture (the bytes are the UTF-8 encoding of this exact string):

    {"v":1,"sender_user_id":"11111111-1111-1111-1111-111111111111","sender_device_id":"web-aaaa","conversation_id":"33333333-3333-3333-3333-333333333333","client_msg_id":"44444444-4444-4444-4444-444444444444","composed_at":"2026-08-26T09:00:00.000Z","message_type":"text","body":"hello 🔒"}

## 3. Envelope layout (the `sealed` wire object)

The server (108) validates this shape, caps the whole object at 64 KB, and checks every
`recipients[].device_id` is a live device of one of the two conversation members — then stores it
opaquely (it never parses `envelope_b64` or verifies the signature; that is the clients' job).

    sealed = {
      "v": 1,
      "alg": "xsalsa20poly1305-sealedbox+ed25519",
      "sender_device_id": "<the sender's device_id>",
      "sig_b64": "<base64 Ed25519 detached signature over the §2 bytes>",
      "recipients": [
        { "device_id": "<a member device>", "envelope_b64": "<base64 crypto_box_seal(§2 bytes, that device's X25519 public)>" },
        ...
      ]
    }

Base64 is standard (RFC 4648, `+/`, padded) — libsodium `base64_variants.ORIGINAL`.

The recipient list is the union of BOTH members' active devices, INCLUDING the sender's own other
devices, so every device (the sender's included) can render the message.

Sign ONCE over the canonical bytes; seal the SAME canonical bytes once per recipient device.

## 4. Sending (per device)

1. Assemble the §2 frame; `client_msg_id` = a fresh UUID (also the idempotency key), `composed_at` =
   now (UTC, ms).
2. `sig = crypto_sign_detached(canonicalBytes, my_ed25519_private)`.
3. For each recipient device: `envelope = crypto_box_seal(canonicalBytes, their_x25519_public)`.
4. POST `message_type:"sealed"`, `client_msg_id`, `composed_at`, and the `sealed` object.

## 5. Receiving (per device)

1. Find MY `device_id` in `recipients`. Absent → render the "not available on this device" stub
   (this device was linked after the message was sealed — the server has no plaintext to give). Do
   NOT treat as an error.
2. `plaintext = crypto_box_seal_open(my_envelope, my_x25519_public, my_x25519_private)`. Failure →
   "couldn't decrypt" stub.
3. Fetch the sender device's `ed25519_public` from the registry (key by `sender_user_id` +
   `sender_device_id`). `crypto_sign_verify_detached(sig, plaintext, sender_ed25519_public)`. On
   failure, REFETCH the registry ONCE (the sender may have rotated) and retry; still failing →
   "couldn't decrypt" stub. Never render an unverified frame.
4. Parse the verified plaintext as the §2 frame; render `body` as a normal text bubble with a lock
   badge.

Ordering is by SERVER receipt (the server's message id / timeline), NOT by `composed_at` —
`composed_at` is display metadata only.

## 6. Safety number (display-only, v1)

A shared code both members compute identically to confirm no man-in-the-middle:

1. Each device has a `key_fingerprint` = lowercase hex of `sha256(ed25519_public)` (served by
   `GET /api/v1/keys/users`).
2. Take the two members' fingerprints, SORT the two hex strings ascending, join with `":"`.
3. `d1 = sha256(utf8(joined))`; `d2 = sha256(d1)`; concatenate to 64 bytes.
4. Read 60 decimal digits: digit i = `byte[i] % 10`, for i in 0..59.
5. Group as 12 groups of 5, space-separated. Render the same 60 digits as a QR code payload.

Because the inputs are sorted, both sides get the same number. v1 shows the primary device pair;
multi-device safety numbers are a later refinement.

## 7. Recorded v1 tradeoffs

- Private keys are libsodium raw bytes in IndexedDB (WebCrypto lacks Ed25519/X25519 on our target
  browsers), so they are extractable-at-rest — never hardware-sealed, never sent in private form.
- No plaintext is persisted: a reload re-decrypts from the stored ciphertext (in-memory LRU only).
- A newly linked device cannot read prior sealed history — the server relays ciphertext it was never
  a recipient of. "History transfer between own devices" is a deferred follow-up.
- Disabling encryption is not supported (server one-way); start a new normal chat to leave.

## 8. Media (encrypted attachments) — NORMATIVE

An E2EE attachment is encrypted CLIENT-SIDE over the plaintext file; the CIPHERTEXT is what is
uploaded to the media store (purpose `sealed_media`). The server stores and serves those bytes
byte-for-byte — no thumbnail, no content sniff, no transform — and its download ACL is identical to
a normal message attachment (conversation membership). The sealed message envelope (§3) stays
≤64 KB: it carries only keys/metadata; the ciphertext blob rides the media store.

### 8.1 Inner payload types

The sealed frame's cleartext (§2) `message_type` is `text` OR `media`. For `text`, `body` is the
plaintext (as v1). For `media`, `body` is `""` and a `media` object is added to the frame BEFORE
canonicalization, appended as the ninth field in this fixed order:

    media = {
      "media_id":            "<the media_assets id returned by the upload>",
      "mime":                "<the ORIGINAL plaintext file's mime, e.g. image/jpeg>",
      "size":                <the ORIGINAL plaintext byte length, integer>,
      "name":                "<original filename>",
      "sha256_of_ciphertext":"<hex sha256 of the uploaded ciphertext bytes — integrity check>",
      "enc": {
        "alg":        "secretstream-xchacha20poly1305",
        "header_b64": "<base64 crypto_secretstream_xchacha20poly1305 header>",
        "chunk_size": <plaintext bytes per chunk, integer, e.g. 65536>
      },
      "key_b64": "<base64 32-byte random file key, fresh per file>",
      "thumb": {                      // OPTIONAL — omit the whole object if none
        "inline_b64": "<base64 ciphertext of a small thumbnail, ≤8192 bytes, encrypted with the SAME key>",
        "w": <int>, "h": <int>
      }
    }

When `media` is present, the canonical field order is: v, sender_user_id, sender_device_id,
conversation_id, client_msg_id, composed_at, message_type, body, media. The signature covers these
bytes exactly (so the media_id, key, and ciphertext hash are all authenticated — a tampered
media_id is a bad signature).

### 8.2 File encryption

Use libsodium `crypto_secretstream_xchacha20poly1305` (present in libsodium-wrappers on web and in
lazysodium / Tink on Android):

1. Generate a fresh 32-byte `key` (the `key_b64`).
2. `init_push(key)` → the stream `header` (the `header_b64`).
3. Encrypt the plaintext file in `chunk_size` chunks; the final chunk uses the `FINAL` tag.
4. Concatenate the chunk outputs → the CIPHERTEXT; upload it (purpose `sealed_media`). Record
   `sha256(ciphertext)`.
5. Optionally encrypt a small thumbnail the same way with the SAME key into `thumb.inline_b64`
   (≤8 KB ciphertext — keep it tiny; it inflates the ≤64 KB envelope).

The `key_b64` is inside the sealed frame, so it is itself sealed per recipient device (§3): only a
member device can recover the file key, then decrypt the downloaded ciphertext.

### 8.3 Receiving media

Open the frame (§5). If `message_type == "media"`: download the `media_id` ciphertext (normal media
download), verify `sha256(ciphertext) == media.sha256_of_ciphertext`, then
`crypto_secretstream_xchacha20poly1305` `init_pull(header, key)` and decrypt chunk by chunk to
recover the plaintext file. Render inline (image/video) or as a file. A hash mismatch or decrypt
failure → the same "couldn't decrypt" treatment as a bad frame; never render unverified bytes.

Only primitives available in BOTH stacks are used: crypto_box_seal, crypto_sign_detached/verify,
crypto_secretstream_xchacha20poly1305, sha256, base64.

## 9. Opportunistic upgrade (default-on apps) — client contract

An app may be flagged `e2ee_default` (server policy, 109). `GET /api/v1/client-config` returns
`{ "e2ee_default": bool }` — read it once on app open (cacheable).

Two upgrade triggers, both idempotent (enabling an already-secret conversation is `200
{enabled:true}`):

- **Server-side at CREATE (automatic):** when a capable client creates a NEW 1:1 in an
  `e2ee_default` app and both members already have registered device keys, the server creates the
  conversation `secret: true` and emits the encryption-enabled system message — no client flag
  needed. If either side has no keys, it is created as a NORMAL chat (no error).

- **Client-driven for EXISTING conversations (trigger ii):** a capable client, on OPENING a
  non-secret 1:1 in an `e2ee_default` app, SHOULD fetch the peer's keys (`GET /keys/users`, which it
  already does for the safety screen) and, IF the peer has ≥1 device key, call
  `POST /conversations/{id}/encryption {enabled:true}`. The server's only job here is idempotency +
  the unchanged preconditions (1:1, both-have-keys, member). If the peer has no keys the call
  returns `secret.peer_keys_missing` and the client does NOTHING — the conversation stays plaintext
  and keeps working (old clients, or a peer who hasn't opened the app, are never broken).

The client MUST treat both as best-effort: a failed upgrade never blocks sending a normal message.
