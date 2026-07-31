import { afterEach, describe, expect, it, vi } from "vitest";
import { reuploadMediaForForward } from "@/lib/forward";
import type { ConversationListItem, Message } from "@/lib/api";
import { failure, installFetch, json, type RecordedCall } from "./support/fetchMock";

/**
 * TIER 1 — the two invariants that fail SILENTLY and expensively.
 *
 * 1. FORWARD RE-UPLOAD: forwarding RECEIVED media must mint a NEW media_id and must never put
 *    `source.media_id` on the outgoing create. The server authorizes media downloads OWNER-ANCHORED
 *    (you may fetch an asset only if you share a conversation where its OWNER sent it), so a reused id
 *    delivers NOTHING to the forward recipient — no error, no broken pixel on the sender's side,
 *    nothing. Before this file the rule was held only by an early return plus typecheck.
 *
 * 2. THE 3-STEP UPLOAD SEQUENCE: describe → PUT the bytes with NO Authorization header → complete,
 *    and a FAILED PUT must never call complete. A bearer token on a presigned PUT both breaks strict
 *    S3/MinIO signature checks and leaks the token to the storage host; completing after a failed PUT
 *    marks an asset `ready` with no bytes behind it.
 */

const SOURCE_MEDIA_ID = "src-media-aaaa";
const FRESH_MEDIA_ID = "fresh-media-bbbb";

const source = {
  message_id: "msg-1",
  conversation_id: "conv-source",
  sender_user_id: "someone-else",
  message_type: "media",
  media_id: SOURCE_MEDIA_ID,
  caption: "look at this",
  metadata: {
    object_key: "media/source/photo.jpg",
    filename: "photo.jpg",
    content_type: "image/jpeg"
  }
} as unknown as Message;

const target = { conversation_id: "conv-target", title: "Target" } as ConversationListItem;

/** Routes the six calls the forward performs; `putStatus` lets a test fail the PUT. */
function routeForward(putStatus = 200) {
  return installFetch((url) => {
    if (url.includes(`/api/v1/media/${SOURCE_MEDIA_ID}/download`)) {
      return json({ media_id: SOURCE_MEDIA_ID, download_url: "https://minio.test/get/source" });
    }
    if (url === "https://minio.test/get/source") {
      return new Response("JPEGBYTES", { status: 200, headers: { "Content-Type": "image/jpeg" } });
    }
    if (url.endsWith("/api/v1/media/uploads")) {
      return json({
        media_id: FRESH_MEDIA_ID,
        object_key: "media/target/fresh.jpg",
        upload_url: "https://minio.test/put/fresh"
      });
    }
    if (url === "https://minio.test/put/fresh") {
      return putStatus === 200 ? new Response("", { status: 200 }) : failure(putStatus);
    }
    if (url.includes(`/api/v1/media/uploads/${FRESH_MEDIA_ID}/complete`)) {
      return json({ media_id: FRESH_MEDIA_ID, status: "ready" });
    }
    if (url.endsWith("/api/v1/conversations/conv-target/messages")) {
      return json({ message_id: "msg-new", conversation_id: "conv-target" });
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
}

const createBody = (calls: RecordedCall[]) =>
  calls.find((c) => c.url.endsWith("/messages"))?.body as Record<string, unknown> | undefined;

afterEach(() => vi.unstubAllGlobals());

describe("forwarding received media", () => {
  it("sends a NEW media_id and never the source's", async () => {
    const calls = routeForward();

    await reuploadMediaForForward(source, target, { forwarded_from: "someone-else" });

    const body = createBody(calls);
    expect(body?.media_id).toBe(FRESH_MEDIA_ID);
    expect(body?.media_id).not.toBe(SOURCE_MEDIA_ID);

    // The strongest form of the invariant: the source id appears NOWHERE in the outgoing create —
    // not as media_id, not smuggled through metadata.
    expect(JSON.stringify(body)).not.toContain(SOURCE_MEDIA_ID);
  });

  it("scopes the fresh upload to the TARGET conversation and re-sends the §7 metadata convention", async () => {
    const calls = routeForward();

    await reuploadMediaForForward(source, target, { forwarded_from: "someone-else" });

    const upload = calls.find((c) => c.url.endsWith("/api/v1/media/uploads"))?.body as Record<
      string,
      unknown
    >;
    expect(upload).toMatchObject({
      conversation_id: "conv-target",
      purpose: "message",
      filename: "photo.jpg",
      content_type: "image/jpeg"
    });

    // The backend reads object_key/filename/content_type/size_bytes off metadata; they must describe
    // the FRESH asset, and the forwarded_from marker must survive.
    expect(createBody(calls)?.metadata).toMatchObject({
      forwarded_from: "someone-else",
      object_key: "media/target/fresh.jpg",
      filename: "photo.jpg",
      content_type: "image/jpeg"
    });
  });

  it("refuses when the source metadata has no object_key (the bytes are unreachable)", async () => {
    routeForward();
    const noKey = { ...source, metadata: { filename: "photo.jpg" } } as unknown as Message;

    await expect(reuploadMediaForForward(noKey, target, {})).rejects.toThrow(
      "This media can't be forwarded."
    );
  });
});

describe("the 3-step upload sequence", () => {
  it("runs describe → PUT → complete → create, in that order", async () => {
    const calls = routeForward();

    await reuploadMediaForForward(source, target, {});

    expect(calls.map((c) => `${c.method} ${c.url.replace(/^https?:\/\/[^/]+/, "")}`)).toEqual([
      `GET /api/v1/media/${SOURCE_MEDIA_ID}/download?object_key=media%2Fsource%2Fphoto.jpg`,
      "GET /get/source",
      "POST /api/v1/media/uploads",
      "PUT /put/fresh",
      `POST /api/v1/media/uploads/${FRESH_MEDIA_ID}/complete`,
      "POST /api/v1/conversations/conv-target/messages"
    ]);
  });

  it("PUTs the bytes with NO Authorization header (presigned URLs must not carry our bearer)", async () => {
    const calls = routeForward();

    await reuploadMediaForForward(source, target, {});

    const put = calls.find((c) => c.method === "PUT");
    expect(put?.headers.has("authorization")).toBe(false);
    expect(put?.headers.get("content-type")).toBe("image/jpeg");
    // The body is the raw blob, never JSON.
    expect(put?.body).toBeInstanceOf(Blob);
  });

  it("a FAILED PUT never calls complete, and never creates the message", async () => {
    const calls = routeForward(500);

    await expect(reuploadMediaForForward(source, target, {})).rejects.toThrow(
      "Forward upload failed with 500."
    );

    expect(calls.some((c) => c.url.includes("/complete"))).toBe(false);
    expect(calls.some((c) => c.url.endsWith("/messages"))).toBe(false);
  });
});
