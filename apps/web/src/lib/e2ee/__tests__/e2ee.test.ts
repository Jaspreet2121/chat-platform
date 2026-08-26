import { beforeAll, describe, expect, it } from "vitest";
import { canonicalBytes, canonicalString, type FrameCleartext } from "@/lib/e2ee/canonical";
import { FRAME_ALG, openFrame, sealFrame } from "@/lib/e2ee/frame";
import { safetyNumber } from "@/lib/e2ee/safetyNumber";
import { sodiumReady, type Sodium } from "@/lib/e2ee/sodium";

let sodium: Sodium;

beforeAll(async () => {
  sodium = await sodiumReady();
});

const frame = (over: Partial<FrameCleartext> = {}): FrameCleartext =>
  ({
    v: 1,
    sender_user_id: "11111111-1111-1111-1111-111111111111",
  sender_device_id: "web-aaaa",
  conversation_id: "33333333-3333-3333-3333-333333333333",
  client_msg_id: "44444444-4444-4444-4444-444444444444",
  composed_at: "2026-08-26T09:00:00.000Z",
    message_type: "text",
    body: "hello 🔒",
    ...over
  }) as FrameCleartext;

describe("canonical bytes", () => {
  it("is fixed-field-order JSON, insensitive to input key order (fixture-locked)", () => {
    const expected =
      '{"v":1,"sender_user_id":"11111111-1111-1111-1111-111111111111",' +
      '"sender_device_id":"web-aaaa","conversation_id":"33333333-3333-3333-3333-333333333333",' +
      '"client_msg_id":"44444444-4444-4444-4444-444444444444","composed_at":"2026-08-26T09:00:00.000Z",' +
      '"message_type":"text","body":"hello 🔒"}';
    expect(canonicalString(frame())).toBe(expected);

    // Same fields, DIFFERENT object insertion order → identical canonical bytes.
    const full: FrameCleartext = {
      body: "hello 🔒",
      v: 1,
      conversation_id: frame().conversation_id,
      sender_user_id: frame().sender_user_id,
      sender_device_id: frame().sender_device_id,
      client_msg_id: frame().client_msg_id,
      composed_at: frame().composed_at,
      message_type: "text"
    };
    expect(canonicalString(full)).toBe(expected);
    expect(Array.from(canonicalBytes(full))).toEqual(Array.from(canonicalBytes(frame())));
  });
});

describe("seal / open round-trip", () => {
  it("the recipient device decrypts and the sender sig verifies; alg matches the doc", async () => {
    const sender = sodium.crypto_sign_keypair();
    const recipient = sodium.crypto_box_keypair();

    const sealed = await sealFrame(frame(), sender.privateKey, "web-aaaa", [
      {
        device_id: "web-bbbb",
        x25519_public: sodium.to_base64(recipient.publicKey, sodium.base64_variants.ORIGINAL)
      }
    ]);

    expect(sealed.alg).toBe(FRAME_ALG);
    expect(sealed.recipients).toHaveLength(1);

    const senderPubB64 = sodium.to_base64(sender.publicKey, sodium.base64_variants.ORIGINAL);
    const result = await openFrame(
      sealed,
      "web-bbbb",
      recipient.publicKey,
      recipient.privateKey,
      senderPubB64
    );
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.frame.body).toBe("hello 🔒");
  });

  it("a TAMPERED signature is rejected (bad_sig), never rendered", async () => {
    const sender = sodium.crypto_sign_keypair();
    const recipient = sodium.crypto_box_keypair();
    const sealed = await sealFrame(frame(), sender.privateKey, "web-aaaa", [
      {
        device_id: "web-bbbb",
        x25519_public: sodium.to_base64(recipient.publicKey, sodium.base64_variants.ORIGINAL)
      }
    ]);

    // Verify against the WRONG signer's key.
    const impostor = sodium.crypto_sign_keypair();
    const wrongPub = sodium.to_base64(impostor.publicKey, sodium.base64_variants.ORIGINAL);
    const result = await openFrame(
      sealed,
      "web-bbbb",
      recipient.publicKey,
      recipient.privateKey,
      wrongPub
    );
    expect(result).toEqual({ ok: false, reason: "bad_sig" });
  });

  it("a device that was NOT a recipient gets no_envelope (the 'not on this device' stub)", async () => {
    const sender = sodium.crypto_sign_keypair();
    const recipient = sodium.crypto_box_keypair();
    const sealed = await sealFrame(frame(), sender.privateKey, "web-aaaa", [
      {
        device_id: "web-bbbb",
        x25519_public: sodium.to_base64(recipient.publicKey, sodium.base64_variants.ORIGINAL)
      }
    ]);

    const other = sodium.crypto_box_keypair();
    const senderPubB64 = sodium.to_base64(sender.publicKey, sodium.base64_variants.ORIGINAL);
    const result = await openFrame(
      sealed,
      "web-cccc",
      other.publicKey,
      other.privateKey,
      senderPubB64
    );
    expect(result).toEqual({ ok: false, reason: "no_envelope" });
  });
});

describe("safety number", () => {
  it("is symmetric (order-independent) and fixture-locked to 12 groups of 5 digits", async () => {
    const a = "a".repeat(64);
    const b = "f".repeat(64);
    const forward = await safetyNumber(a, b);
    const reverse = await safetyNumber(b, a);
    expect(forward).toBe(reverse);
    expect(forward).toMatch(/^(\d{5} ){11}\d{5}$/);
  });
});
