// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  acknowledgeEventOutboxRow,
  createConversation,
  createMessage,
  getAdminEventOutboxRow,
  getAdminEventOutboxRows,
  getAdminEventOutboxSummary,
  request,
  updateMe,
  verifyOtp
} from "@/lib/api";
import { setSessionTokens } from "@/lib/session";
import { apiError, installFetch, json, noContent, type RecordedCall } from "./support/fetchMock";

/**
 * TIER 1 (#3) + TIER 2 — the wire shapes the backend now ENFORCES. jsdom because the request boundary
 * reads the access token from localStorage; every test still stubs `fetch`, so there is no network.
 */

const body = (calls: RecordedCall[], n = 0) => calls[n].body as Record<string, unknown>;

beforeEach(() => window.localStorage.clear());
afterEach(() => vi.unstubAllGlobals());

describe("OTP verify carries the DEVICE IDENTITY", () => {
  it("sends device_id, platform and device_name on VERIFY (not just on request)", async () => {
    const calls = installFetch(() => json({ user_id: "u1", access_token: "a", refresh_token: "r" }));

    await verifyOtp({
      destination: "+919876543210",
      otpRequestId: "req-1",
      otpCode: "123456",
      deviceId: "web-uuid-1234",
      deviceName: "Chrome on macOS",
      rememberMe: true
    });

    // THE REGRESSION THIS PINS: these three rode only /otp/request — which mints NO session — so every
    // device_sessions row landed as null/"web". Linked devices is unusable without them here.
    expect(body(calls)).toMatchObject({
      device_id: "web-uuid-1234",
      device_name: "Chrome on macOS",
      platform: "web",
      otp_request_id: "req-1",
      otp_code: "123456",
      remember_me: true
    });
  });

  it("defaults platform to 'web' and still sends a composed device_name when unspecified", async () => {
    const calls = installFetch(() => json({ user_id: "u1" }));

    await verifyOtp({
      destination: "+919876543210",
      otpRequestId: "req-1",
      otpCode: "123456",
      deviceId: "web-uuid-1234"
    });

    expect(body(calls).platform).toBe("web");
    expect(body(calls).device_name).toBeTruthy();
  });
});

describe("createMessage wire shape", () => {
  it("maps camelCase input to the server's snake_case body, incl. the metadata convention", async () => {
    const calls = installFetch(() => json({ message_id: "m1" }));

    await createMessage({
      conversationId: "conv-1",
      messageType: "media",
      mediaId: "media-1",
      caption: "a caption",
      replyToMessageId: "msg-0",
      metadata: {
        object_key: "media/x.jpg",
        filename: "x.jpg",
        content_type: "image/jpeg",
        size_bytes: 1234
      }
    });

    expect(calls[0].url).toMatch(/\/api\/v1\/conversations\/conv-1\/messages$/);
    expect(calls[0].method).toBe("POST");
    expect(body(calls)).toMatchObject({
      message_type: "media",
      media_id: "media-1",
      caption: "a caption",
      reply_to_message_id: "msg-0",
      metadata: {
        object_key: "media/x.jpg",
        filename: "x.jpg",
        content_type: "image/jpeg",
        size_bytes: 1234
      }
    });
  });

  it("URL-encodes the conversation id rather than interpolating it raw", async () => {
    const calls = installFetch(() => json({ message_id: "m1" }));

    await createMessage({ conversationId: "conv/../evil", messageType: "text", body: "hi" });

    expect(calls[0].url).toContain("conv%2F..%2Fevil");
  });
});

describe("createConversation wire shape", () => {
  it("defaults type to 'group' and sends participant_user_ids", async () => {
    const calls = installFetch(() => json({ conversation_id: "c1" }));

    await createConversation({ title: "Team", participantUserIds: ["u1", "u2"] });

    expect(body(calls)).toMatchObject({
      type: "group",
      title: "Team",
      participant_user_ids: ["u1", "u2"]
    });
  });

  it("passes an explicit type through (direct chats must not be created as groups)", async () => {
    const calls = installFetch(() => json({ conversation_id: "c1" }));

    await createConversation({ title: "", participantUserIds: ["u2"], type: "direct" });

    expect(body(calls).type).toBe("direct");
  });
});

describe("profile PATCH is SPARSE", () => {
  it("sends ONLY the provided keys — an absent field must never be transmitted as null", async () => {
    const calls = installFetch(() => json({ user_id: "u1" }));

    await updateMe({ display_name: "Ada" });

    expect(calls[0].method).toBe("PATCH");
    expect(body(calls)).toEqual({ display_name: "Ada" });
    // A stray `bio: null` here would WIPE the stored bio server-side.
    expect(Object.keys(body(calls))).not.toContain("bio");
    expect(Object.keys(body(calls))).not.toContain("avatar_media_id");
  });

  it("passes an explicit empty string through (that IS the documented clear-avatar signal)", async () => {
    const calls = installFetch(() => json({ user_id: "u1" }));

    // "" means REMOVE the photo. Note avatar_object_key is deliberately NOT part of this input any
    // more — the server resolves object_key from the media_assets row and strips any client-sent key.
    await updateMe({ avatar_media_id: "" });

    expect(body(calls)).toEqual({ avatar_media_id: "" });
  });
});

describe("the request() boundary", () => {
  it("attaches the bearer token when one is stored, and JSON headers on a body", async () => {
    setSessionTokens({ accessToken: "tok-123" });
    const calls = installFetch(() => json({ ok: true }));

    await request("/api/v1/thing", { method: "POST", body: JSON.stringify({ a: 1 }) });

    expect(calls[0].headers.get("authorization")).toBe("Bearer tok-123");
    expect(calls[0].headers.get("content-type")).toBe("application/json");
    expect(calls[0].headers.get("accept")).toBe("application/json");
  });

  it("sends NO Authorization header when signed out", async () => {
    const calls = installFetch(() => json({ ok: true }));

    await request("/api/v1/thing");

    expect(calls[0].headers.has("authorization")).toBe(false);
  });

  it("returns undefined for 204 rather than exploding on an empty body", async () => {
    installFetch(() => noContent());

    await expect(request("/api/v1/thing", { method: "DELETE" })).resolves.toBeUndefined();
  });

  it("throws the server's error.message from the envelope", async () => {
    installFetch(() => apiError("Too many pinned conversations", 400, "conversations.pin_limit"));

    await expect(request("/api/v1/thing")).rejects.toThrow("Too many pinned conversations");
  });

  it("falls back to a status-bearing message when the error body isn't an envelope", async () => {
    installFetch(() => new Response("gateway blew up", { status: 502 }));

    await expect(request("/api/v1/thing")).rejects.toThrow("502");
  });
});

describe("event-outbox ops client — the wire the admin page rides", () => {
  it("hits the four routes with the right methods and params", async () => {
    const calls = installFetch(() => json({}));

    await getAdminEventOutboxSummary();
    await getAdminEventOutboxRows({ status: "aborted", limit: 50 });
    await getAdminEventOutboxRow("row 1");
    await acknowledgeEventOutboxRow("row 1");

    expect(calls[0].url).toContain("/api/v1/admin/events/outbox");
    expect(calls[1].url).toContain("/api/v1/admin/events/outbox/rows?status=aborted&limit=50");
    // Encoded id — an id with a space must not split the path.
    expect(calls[2].url).toContain("/api/v1/admin/events/outbox/row%201");
    expect(calls[3].url).toContain("/api/v1/admin/events/outbox/row%201/acknowledge");
    expect(calls[3].method).toBe("POST");
    // The three reads are GETs — the surface observes; only acknowledge mutates.
    expect(calls[0].method ?? "GET").toBe("GET");
    expect(calls[1].method ?? "GET").toBe("GET");
    expect(calls[2].method ?? "GET").toBe("GET");
  });
});
