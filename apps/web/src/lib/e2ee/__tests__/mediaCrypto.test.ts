import { beforeAll, describe, expect, it } from "vitest";
import { canonicalString, type FrameCleartext, type MediaDescriptor } from "@/lib/e2ee/canonical";
import {
  THUMB_MAX_CIPHERTEXT,
  decryptFile,
  encryptFile,
  openFile,
  openThumb,
  sealFile
} from "@/lib/e2ee/mediaCrypto";
import { sodiumReady, type Sodium } from "@/lib/e2ee/sodium";

let sodium: Sodium;

beforeAll(async () => {
  sodium = await sodiumReady();
});

function bytes(n: number, seed = 7): Uint8Array {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i += 1) out[i] = (i * seed + 13) % 256;
  return out;
}

describe("secretstream round-trip", () => {
  it("round-trips across chunk boundaries (empty, sub-chunk, exact multiple, multi-chunk)", async () => {
    for (const [len, chunk] of [
      [0, 16],
      [10, 16],
      [32, 16], // exact 2 chunks
      [33, 16], // 3 chunks, last partial
      [200, 64]
    ] as const) {
      const key = sodium.crypto_secretstream_xchacha20poly1305_keygen();
      const plain = bytes(len);
      const { ciphertext, header } = await encryptFile(plain, key, chunk);
      const back = await decryptFile(ciphertext, key, header, chunk);
      expect(Array.from(back)).toEqual(Array.from(plain));
    }
  });

  it("a TRUNCATED ciphertext (missing FINAL chunk) is rejected, not silently short-read", async () => {
    const key = sodium.crypto_secretstream_xchacha20poly1305_keygen();
    const { ciphertext, header } = await encryptFile(bytes(64), key, 16); // 4 chunks
    const ABYTES = sodium.crypto_secretstream_xchacha20poly1305_ABYTES;
    const truncated = ciphertext.subarray(0, (16 + ABYTES) * 2); // drop the last two incl. FINAL
    await expect(decryptFile(truncated, key, header, 16)).rejects.toThrow();
  });
});

describe("sealFile / openFile", () => {
  it("seals a file → descriptor + ciphertext; openFile verifies hash then decrypts", async () => {
    const plain = bytes(500);
    const { ciphertext, descriptor: partial } = await sealFile({
      bytes: plain,
      mime: "image/jpeg",
      name: "photo.jpg"
    });

    const descriptor: MediaDescriptor = { ...partial, media_id: "m1" };
    expect(descriptor.enc.alg).toBe("secretstream-xchacha20poly1305");
    expect(descriptor.size).toBe(500);

    const result = await openFile(ciphertext, descriptor);
    expect(result.ok).toBe(true);
    if (result.ok) expect(Array.from(result.bytes)).toEqual(Array.from(plain));
  });

  it("a hash mismatch (tampered ciphertext) → stub, never decrypted", async () => {
    const { ciphertext, descriptor: partial } = await sealFile({
      bytes: bytes(120),
      mime: "image/png",
      name: "x.png"
    });
    const descriptor: MediaDescriptor = { ...partial, media_id: "m1" };

    const tampered = ciphertext.slice();
    tampered[0] ^= 0xff;
    expect(await openFile(tampered, descriptor)).toEqual({ ok: false, reason: "hash_mismatch" });
  });

  it("a thumbnail round-trips with the SAME key and is dropped when over the ≤8KB cap", async () => {
    const small = await sealFile(
      { bytes: bytes(64), mime: "image/jpeg", name: "a.jpg" },
      { bytes: bytes(200), w: 40, h: 30 }
    );
    const descSmall: MediaDescriptor = { ...small.descriptor, media_id: "m" };
    expect(descSmall.thumb).toBeDefined();
    const thumbBytes = await openThumb(descSmall);
    expect(thumbBytes).not.toBeNull();
    expect(Array.from(thumbBytes as Uint8Array)).toEqual(Array.from(bytes(200)));

    // A thumb whose ciphertext would exceed the cap is omitted (no thumb field).
    const big = await sealFile(
      { bytes: bytes(64), mime: "image/jpeg", name: "b.jpg" },
      { bytes: bytes(THUMB_MAX_CIPHERTEXT * 2), w: 10, h: 10 }
    );
    expect(big.descriptor.thumb).toBeUndefined();
  });
});

describe("media frame canonicalization (fixture-locked to §8.1)", () => {
  it("media is the ninth field, in the fixed order, with body empty", () => {
    const media: MediaDescriptor = {
      media_id: "aaaa",
      mime: "image/jpeg",
      size: 500,
      name: "p.jpg",
      sha256_of_ciphertext: "deadbeef",
      enc: { alg: "secretstream-xchacha20poly1305", header_b64: "H", chunk_size: 65536 },
      key_b64: "K"
    };
    const frame: FrameCleartext = {
      v: 1,
      sender_user_id: "u",
      sender_device_id: "d",
      conversation_id: "c",
      client_msg_id: "cid",
      composed_at: "2026-08-26T09:00:00.000Z",
      message_type: "media",
      body: "",
      media
    };

    expect(canonicalString(frame)).toBe(
      '{"v":1,"sender_user_id":"u","sender_device_id":"d","conversation_id":"c",' +
        '"client_msg_id":"cid","composed_at":"2026-08-26T09:00:00.000Z","message_type":"media",' +
        '"body":"","media":{"media_id":"aaaa","mime":"image/jpeg","size":500,"name":"p.jpg",' +
        '"sha256_of_ciphertext":"deadbeef","enc":{"alg":"secretstream-xchacha20poly1305",' +
        '"header_b64":"H","chunk_size":65536},"key_b64":"K"}}'
    );
  });
});
