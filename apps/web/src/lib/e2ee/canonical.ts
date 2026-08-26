// Canonical bytes of a sealed frame's cleartext (108 / E2EE_FRAME.md §2). The signature covers
// EXACTLY these bytes, and every device that re-derives them — web today, Android next — MUST get
// byte-for-byte the same result, so the rule is fixed and dependency-free:
//
//   1. Take the frame fields in THIS fixed key order (never alphabetical, never the object's
//      insertion order): v, sender_user_id, sender_device_id, conversation_id, client_msg_id,
//      composed_at, message_type, body.
//   2. JSON.stringify that ordered object with NO spaces (JSON.stringify default) — so the only
//      escaping is JSON's own. UTF-8 encode the result.
//
// No floats, no nested objects, no optional fields in v1 — every value is a string except `v`
// (integer 1). That keeps canonicalization trivial to reimplement without a canonical-JSON library.

export type FrameCleartext = {
  v: 1;
  sender_user_id: string;
  sender_device_id: string;
  conversation_id: string;
  client_msg_id: string;
  composed_at: string;
  message_type: "text";
  body: string;
};

const FIELD_ORDER: Array<keyof FrameCleartext> = [
  "v",
  "sender_user_id",
  "sender_device_id",
  "conversation_id",
  "client_msg_id",
  "composed_at",
  "message_type",
  "body"
];

/** The exact bytes the signature covers. Deterministic across engines (fixed field order + plain
 *  JSON.stringify + UTF-8). */
export function canonicalBytes(frame: FrameCleartext): Uint8Array {
  const ordered: Record<string, unknown> = {};
  for (const key of FIELD_ORDER) ordered[key] = frame[key];
  return new TextEncoder().encode(JSON.stringify(ordered));
}

/** The canonical STRING (tests + debugging); the bytes are its UTF-8 encoding. */
export function canonicalString(frame: FrameCleartext): string {
  const ordered: Record<string, unknown> = {};
  for (const key of FIELD_ORDER) ordered[key] = frame[key];
  return JSON.stringify(ordered);
}
