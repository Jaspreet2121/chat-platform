import { describe, expect, it } from "vitest";
import { sealedMessageType, sealedSendGuard } from "@/lib/e2ee/sendGuard";

// The send-path guard is a pure decision: a secret conversation MUST send sealed, a normal one MUST
// NOT — there is no code path that sends plaintext into a secret chat.
describe("send-path guard", () => {
  it("a secret conversation forces the sealed path", () => {
    expect(sealedSendGuard({ secret: true })).toEqual({ mode: "sealed" });
    expect(sealedMessageType({ secret: true })).toBe("sealed");
  });

  it("a normal conversation uses the plaintext path", () => {
    expect(sealedSendGuard({ secret: false })).toEqual({ mode: "plaintext" });
    expect(sealedSendGuard({})).toEqual({ mode: "plaintext" });
    expect(sealedMessageType({ secret: false })).toBe("text");
  });
});

import { attachmentSendGuard } from "@/lib/e2ee/sendGuard";

describe("attachment send-path guard (v2)", () => {
  it("a secret conversation forces sealed_media; a normal one uses the plaintext media path", () => {
    expect(attachmentSendGuard({ secret: true })).toEqual({ mode: "sealed_media" });
    expect(attachmentSendGuard({ secret: false })).toEqual({ mode: "plaintext_media" });
    expect(attachmentSendGuard({})).toEqual({ mode: "plaintext_media" });
  });
});
