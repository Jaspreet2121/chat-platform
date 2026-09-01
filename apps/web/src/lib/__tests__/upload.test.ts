import { describe, expect, it, vi } from "vitest";

import { uploadMediaBlob } from "@/lib/upload";
import { installFetch, json } from "./support/fetchMock";

// THE ONE UPLOAD SEQUENCE, now shared by all five former copies. These assertions used to protect
// forward.ts alone; they now protect the chat attachment send, both avatar paths and the group photo
// too — which was the entire point of the consolidation.

const UPLOAD = {
  media_id: "m-new",
  object_key: "media/u1/m-new/photo.png",
  upload_url: "https://storage.example/put/m-new?sig=abc",
  expires_at: "2026-01-01T00:00:00Z"
};

function routes(putStatus = 200) {
  return installFetch((url, init) => {
    if (url.includes("/api/v1/media/uploads") && url.endsWith("/complete")) {
      return json({ media_id: "m-new", status: "ready" });
    }
    if (url.includes("/api/v1/media/uploads")) return json(UPLOAD);
    if (url.startsWith("https://storage.example/put/")) {
      return new Response(putStatus === 200 ? "" : "nope", { status: putStatus });
    }
    void init;
    return json({}, 404);
  });
}

const blob = () => new Blob(["bytes"], { type: "image/png" });

describe("uploadMediaBlob — the 3-step sequence", () => {
  it("describes, PUTs, then completes — in that order", async () => {
    const calls = routes();

    const result = await uploadMediaBlob({
      blob: blob(),
      filename: "photo.png",
      contentType: "image/png",
      purpose: "message",
      conversationId: "c1"
    });

    expect(calls.map((c) => `${c.method} ${new URL(c.url, "http://x").pathname}`)).toEqual([
      "POST /api/v1/media/uploads",
      "PUT /put/m-new",
      "POST /api/v1/media/uploads/m-new/complete"
    ]);

    expect(result).toEqual({ mediaId: "m-new", objectKey: UPLOAD.object_key });
  });

  it("THE INVARIANT: a failed PUT never calls complete", async () => {
    const calls = routes(500);

    await expect(
      uploadMediaBlob({
        blob: blob(),
        filename: "photo.png",
        contentType: "image/png",
        purpose: "message",
        conversationId: "c1"
      })
    ).rejects.toThrow(/500/);

    // Completing after a failed PUT marks the asset `ready` with NO BYTES behind it — it then renders
    // as a broken image forever, and the server cannot detect it. The sequence must stop at the PUT.
    expect(calls.some((c) => c.url.endsWith("/complete"))).toBe(false);
    expect(calls.map((c) => c.method)).toEqual(["POST", "PUT"]);
  });

  it("sends NO Authorization header on the presigned PUT (and the raw blob as the body)", async () => {
    const calls = routes();
    const body = blob();

    await uploadMediaBlob({
      blob: body,
      filename: "photo.png",
      contentType: "image/png",
      purpose: "user_avatar"
    });

    const put = calls.find((c) => c.method === "PUT");
    // A bearer on a presigned URL breaks strict S3 signature validation AND leaks the session token
    // to the storage host. Content-Type is the ONLY header this request may carry.
    expect(put?.headers.get("authorization")).toBeNull();
    expect(put?.headers.get("content-type")).toBe("image/png");
    expect(put?.body).toBe(body);
  });

  it("each purpose reaches the wire, with conversation_id only when supplied", async () => {
    for (const purpose of ["message", "user_avatar", "group_avatar", "status"] as const) {
      const calls = routes();

      await uploadMediaBlob({
        blob: blob(),
        filename: "photo.png",
        contentType: "image/png",
        purpose,
        ...(purpose === "user_avatar" ? {} : { conversationId: "c1" })
      });

      const describe = calls[0].body as Record<string, unknown>;
      expect(describe.purpose).toBe(purpose);
      expect(describe.filename).toBe("photo.png");
      expect(describe.content_type).toBe("image/png");
      expect(describe.size_bytes).toBe(blob().size);

      // Avatars carry no conversation; the other purposes do — and the key is ABSENT, not null.
      if (purpose === "user_avatar") {
        expect("conversation_id" in describe).toBe(false);
      } else {
        expect(describe.conversation_id).toBe("c1");
      }

      vi.unstubAllGlobals();
    }
  });

  it("preserves each caller's own failed-PUT message (the differences the move did not unify)", async () => {
    routes(503);

    await expect(
      uploadMediaBlob({
        blob: blob(),
        filename: "f",
        contentType: "image/png",
        purpose: "message",
        conversationId: "c1",
        uploadErrorMessage: (status) => `Forward upload failed with ${status}.`
      })
    ).rejects.toThrow("Forward upload failed with 503.");

    vi.unstubAllGlobals();
    routes(503);

    await expect(
      uploadMediaBlob({
        blob: blob(),
        filename: "f",
        contentType: "image/png",
        purpose: "user_avatar",
        uploadErrorMessage: (status) => `Upload failed (${status})`
      })
    ).rejects.toThrow("Upload failed (503)");
  });

  it("reports stages in order for the one caller that shows progress; silent for the rest", async () => {
    routes();
    const stages: string[] = [];

    await uploadMediaBlob({
      blob: blob(),
      filename: "photo.png",
      contentType: "image/png",
      purpose: "message",
      conversationId: "c1",
      onStage: (stage) => stages.push(stage)
    });

    expect(stages).toEqual(["describing", "uploading", "completing"]);

    // A failed PUT never reaches "completing" — the same invariant, seen from the UI's side.
    vi.unstubAllGlobals();
    routes(500);
    const failedStages: string[] = [];

    await expect(
      uploadMediaBlob({
        blob: blob(),
        filename: "photo.png",
        contentType: "image/png",
        purpose: "message",
        conversationId: "c1",
        onStage: (stage) => failedStages.push(stage)
      })
    ).rejects.toThrow();

    expect(failedStages).toEqual(["describing", "uploading"]);
  });
});

describe("uploadMediaBlob — the message anchor guard", () => {
  // The spread that builds the request body drops conversation_id when it is falsy, so an anchorless
  // message upload was indistinguishable on the wire from one that never needed an anchor. That is a
  // caller bug; it now throws locally instead of reaching the server.
  it("sends both fields when a message attachment has its conversation", async () => {
    const calls = routes();

    await uploadMediaBlob({
      blob: blob(),
      filename: "photo.png",
      contentType: "image/png",
      purpose: "message",
      conversationId: "c1"
    });

    const body = calls[0].body as Record<string, unknown>;
    expect(body.purpose).toBe("message");
    expect(body.conversation_id).toBe("c1");
  });

  it("THROWS on a message attachment with no conversation — nothing is sent", async () => {
    for (const missing of [undefined, ""]) {
      const calls = routes();

      await expect(
        uploadMediaBlob({
          blob: blob(),
          filename: "photo.png",
          contentType: "image/png",
          purpose: "message",
          conversationId: missing
        })
      ).rejects.toThrow(/conversation_id is required/);

      // The point of failing locally: the describe request never happened.
      expect(calls).toHaveLength(0);

      vi.unstubAllGlobals();
    }
  });

  it("leaves the other purposes alone — an avatar still uploads with no conversation", async () => {
    // This is what stops the guard being widened to every purpose: avatars and status posts have no
    // conversation to give, and throwing for them would break three working call sites.
    for (const purpose of ["user_avatar", "group_avatar", "status", "sealed_media"] as const) {
      const calls = routes();

      const result = await uploadMediaBlob({
        blob: blob(),
        filename: "photo.png",
        contentType: "image/png",
        purpose
      });

      expect(result.mediaId).toBe("m-new");
      expect(calls.length).toBeGreaterThan(0);

      vi.unstubAllGlobals();
    }
  });
});
