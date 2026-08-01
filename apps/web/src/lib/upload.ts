import {
  completeMediaUpload,
  createMediaUpload,
  type MediaUploadPurpose
} from "@/lib/api";

// THE ONE UPLOAD SEQUENCE. Extracted VERBATIM from the five copies that each carried it (chat/page.tsx
// attachment send, forward.ts, OnboardingStep, MyProfileModal, ConversationDetailsPanel) — exactly one
// of which was machine-checked, so the other four could each independently acquire the bug the tested
// one prevents.
//
// THE LOAD-BEARING INVARIANT, now in one place: a FAILED PUT MUST NEVER CALL COMPLETE. Completing after
// a failed PUT marks the asset `ready` with no bytes behind it, and it renders as a broken image
// forever — the server has no way to notice. The `throw` below is that guarantee; the test in
// __tests__/upload.test.ts is what keeps it (mutation-proven: deleting the throw turns it red).
//
// AND NO AUTHORIZATION HEADER ON THE PUT. The URL is already a presigned capability: a stray bearer
// both breaks strict S3 signature validation and leaks the session token to the storage host. The
// headers below are deliberately Content-Type ONLY — do not "helpfully" add auth here.
export type UploadMediaBlobInput = {
  /** The bytes to PUT. `size_bytes` is always this blob's size — every original did the same. */
  blob: Blob;
  /** Sent as-is to describe. Callers pass the ORIGINAL file's name even when the blob is compressed. */
  filename: string;
  /** Sent to describe AND as the PUT's Content-Type — one value, as every original had it. */
  contentType: string;
  purpose: MediaUploadPurpose;
  /** Omitted for avatars; supplied for message + group_avatar uploads, exactly as before. */
  conversationId?: string;
  /**
   * PRESERVED DIFFERENCE #1 — the failed-PUT message text differed across the five copies (three
   * distinct formats, all user-visible through each caller's catch → setError). Callers keep their
   * own wording rather than the move silently rewording anyone's UI.
   */
  uploadErrorMessage?: (status: number) => string;
  /**
   * PRESERVED DIFFERENCE #2 — only the chat attachment path reported per-stage progress
   * ("Preparing upload…" / "Uploading…" / "Completing upload…"). Optional so the other four behave
   * exactly as they did (no calls at all).
   */
  onStage?: (stage: "describing" | "uploading" | "completing") => void;
};

export type UploadedMedia = {
  mediaId: string;
  objectKey: string;
};

export async function uploadMediaBlob({
  blob,
  filename,
  contentType,
  purpose,
  conversationId,
  uploadErrorMessage = (status) => `Upload failed with ${status}`,
  onStage
}: UploadMediaBlobInput): Promise<UploadedMedia> {
  onStage?.("describing");
  const upload = await createMediaUpload({
    filename,
    content_type: contentType,
    size_bytes: blob.size,
    purpose,
    ...(conversationId ? { conversation_id: conversationId } : {})
  });

  onStage?.("uploading");
  const put = await fetch(upload.upload_url, {
    method: "PUT",
    body: blob,
    headers: { "Content-Type": contentType }
  });

  // THE INVARIANT. Everything after this line is unreachable on a failed PUT.
  if (!put.ok) throw new Error(uploadErrorMessage(put.status));

  onStage?.("completing");
  await completeMediaUpload(upload.media_id, upload.object_key);

  return { mediaId: upload.media_id, objectKey: upload.object_key };
}
