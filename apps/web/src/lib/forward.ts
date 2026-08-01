import {
  createMessage,
  getMediaDownloadUrl,
  type ConversationListItem,
  type Message
} from "@/lib/api";
import { uploadMediaBlob } from "@/lib/upload";

// EXTRACTED VERBATIM from chat/page.tsx (it carried no React state or JSX — pure wire logic) so the
// forward invariant is machine-checked instead of held only by an early return: forwarding RECEIVED
// media must mint a NEW media_id and must NEVER put source.media_id on the outgoing create. Under the
// server's owner-anchored download rule a reused id delivers NOTHING to the recipient, silently.
// Covered by src/lib/__tests__/forward.test.ts.
//
// The describe → PUT → complete sequence this function used to carry inline now lives in ONE place,
// src/lib/upload.ts (uploadMediaBlob), shared by all five former copies — this one, the chat
// attachment send, both avatar paths and the group photo. "A failed PUT must never call complete" is
// asserted once, against the helper, and mutation-proven (deleting the guard turns that exact test
// red). The follow-up recorded here is DONE.

// Re-upload a forwarded media asset into `target` as a NEW asset (fresh media_id, owned by the forwarder),
// then send the forwarded message referencing ONLY that fresh id — source.media_id never reaches the
// outgoing create. See handleForward for why reusing it fails for received media. Mirrors Android.
export async function reuploadMediaForForward(
  source: Message,
  target: ConversationListItem,
  metadata: Record<string, unknown>
) {
  // Resolve the source bytes the same way the message bubble does: presign a download URL from the media_id
  // + its object_key (carried in metadata). We reach here only for a cross-conversation media forward, so
  // media_id is set; a missing object_key means we can't fetch the bytes to re-upload.
  const meta = source.metadata ?? {};
  const objectKey = typeof meta.object_key === "string" ? meta.object_key : undefined;
  if (!source.media_id || !objectKey) throw new Error("This media can't be forwarded.");

  const { download_url } = await getMediaDownloadUrl(source.media_id, objectKey);

  const fileResponse = await fetch(download_url);
  if (!fileResponse.ok) {
    throw new Error(`Couldn't load the media to forward (${fileResponse.status}).`);
  }
  const blob = await fileResponse.blob();

  const filename = typeof meta.filename === "string" ? meta.filename : "forwarded";
  const contentType =
    (typeof meta.content_type === "string" && meta.content_type) ||
    blob.type ||
    "application/octet-stream";

  const { mediaId, objectKey: uploadedObjectKey } = await uploadMediaBlob({
    blob,
    filename,
    contentType,
    purpose: "message",
    conversationId: target.conversation_id,
    uploadErrorMessage: (status) => `Forward upload failed with ${status}.`
  });

  await createMessage({
    conversationId: target.conversation_id,
    messageType: "media",
    mediaId,
    caption: source.caption ?? undefined,
    metadata: {
      ...metadata,
      object_key: uploadedObjectKey,
      filename,
      content_type: contentType,
      size_bytes: blob.size
    }
  });
}
