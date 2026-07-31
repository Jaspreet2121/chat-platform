import {
  completeMediaUpload,
  createMediaUpload,
  createMessage,
  getMediaDownloadUrl,
  type ConversationListItem,
  type Message
} from "@/lib/api";

// EXTRACTED VERBATIM from chat/page.tsx (it carried no React state or JSX — pure wire logic) so the
// forward invariant is machine-checked instead of held only by an early return: forwarding RECEIVED
// media must mint a NEW media_id and must NEVER put source.media_id on the outgoing create. Under the
// server's owner-anchored download rule a reused id delivers NOTHING to the recipient, silently.
// Covered by src/lib/__tests__/forward.test.ts.
//
// FOLLOW-UP (scoped, NOT a tidy-up): the describe → PUT → complete sequence below is DUPLICATED in
// four other places, and this is the ONLY copy any test covers. "A failed PUT must never call
// complete" is load-bearing — completing after a failed PUT marks an asset `ready` with no bytes
// behind it — so each of the four can independently acquire the exact bug the test here now
// prevents. They are:
//   1. src/app/chat/page.tsx            (the attachment send path)
//   2. src/app/chat/page.tsx            (the second upload call site in the same file)
//   3. src/app/login/OnboardingStep.tsx (first avatar)
//   4. src/components/chat/MyProfileModal.tsx      (avatar change)
//   5. src/components/chat/ConversationDetailsPanel.tsx (group avatar)
// Consolidating them into one `uploadMediaBlob()` here would put all five behind these tests, but it
// is behaviour-carrying across four components and belongs in its own commit — not a test slice.

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

  const upload = await createMediaUpload({
    filename,
    content_type: contentType,
    size_bytes: blob.size,
    purpose: "message",
    conversation_id: target.conversation_id
  });

  const putResponse = await fetch(upload.upload_url, {
    method: "PUT",
    body: blob,
    headers: { "Content-Type": contentType }
  });
  if (!putResponse.ok) throw new Error(`Forward upload failed with ${putResponse.status}.`);

  await completeMediaUpload(upload.media_id, upload.object_key);

  await createMessage({
    conversationId: target.conversation_id,
    messageType: "media",
    mediaId: upload.media_id,
    caption: source.caption ?? undefined,
    metadata: {
      ...metadata,
      object_key: upload.object_key,
      filename,
      content_type: contentType,
      size_bytes: blob.size
    }
  });
}
