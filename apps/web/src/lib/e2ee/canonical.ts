// Canonical bytes of a sealed frame's cleartext (108/109 / E2EE_FRAME.md §2 + §8.1). The signature
// covers EXACTLY these bytes, and every device that re-derives them — web today, Android next —
// MUST get byte-for-byte the same result, so the rule is fixed and dependency-free:
//
//   1. Take the frame fields in THIS fixed key order (never alphabetical, never insertion order):
//      v, sender_user_id, sender_device_id, conversation_id, client_msg_id, composed_at,
//      message_type, body — and, ONLY when message_type is "media", `media` as the ninth field.
//   2. JSON.stringify that ordered object with NO spaces (JSON.stringify default). UTF-8 encode.
//
// text: `body` is the plaintext, no `media`. media: `body` is "" and `media` carries the file
// descriptor (keys/hash/thumb — the ciphertext blob itself rides the media store, not the frame).

export type MediaDescriptor = {
  media_id: string;
  mime: string;
  size: number;
  name: string;
  sha256_of_ciphertext: string;
  enc: { alg: "secretstream-xchacha20poly1305"; header_b64: string; chunk_size: number };
  key_b64: string;
  thumb?: { inline_b64: string; w: number; h: number };
};

export type FrameCleartext = {
  v: 1;
  sender_user_id: string;
  sender_device_id: string;
  conversation_id: string;
  client_msg_id: string;
  composed_at: string;
} & ({ message_type: "text"; body: string } | { message_type: "media"; body: ""; media: MediaDescriptor });

const BASE_ORDER = [
  "v",
  "sender_user_id",
  "sender_device_id",
  "conversation_id",
  "client_msg_id",
  "composed_at",
  "message_type",
  "body"
] as const;

function ordered(frame: FrameCleartext): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of BASE_ORDER) out[key] = (frame as Record<string, unknown>)[key];
  // media is the NINTH field, ONLY for a media frame (§8.1).
  if (frame.message_type === "media") out.media = frame.media;
  return out;
}

/** The exact bytes the signature covers — deterministic across engines (fixed order + plain
 *  JSON.stringify + UTF-8). */
export function canonicalBytes(frame: FrameCleartext): Uint8Array {
  return new TextEncoder().encode(JSON.stringify(ordered(frame)));
}

/** The canonical STRING (tests + debugging); the bytes are its UTF-8 encoding. */
export function canonicalString(frame: FrameCleartext): string {
  return JSON.stringify(ordered(frame));
}
