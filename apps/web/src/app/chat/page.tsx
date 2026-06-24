"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  ConversationDetail,
  ConversationListItem,
  CreateMessageInput,
  Message,
  Session,
  UserProfile,
  completeMediaUpload,
  createConversation,
  createMediaUpload,
  createMessage,
  deleteMessage,
  editMessage,
  getConversation,
  getCurrentSession,
  getMe,
  getPublicProfile,
  listConversations,
  listMessages
} from "@/lib/api";
import { clearSessionTokens } from "@/lib/session";
import {
  ConversationChannel,
  createSocket,
  joinConversationChannel
} from "@/lib/realtime";
import type { Socket } from "phoenix";
import {
  ChatHeader,
  Composer,
  ConversationDetailsPanel,
  ConversationSidebar,
  MessageList,
  StatusBanner
} from "@/components/chat";
import { cn } from "@/lib/cn";
import imageCompression from "browser-image-compression";

// Kept in sync with the backend allow-list (MediaService.Media @allowed_content_types). The file
// picker's accept attribute is intentionally broader (image/*,video/*,…) so valid files aren't greyed
// out; anything picked outside this set is rejected client-side with a friendly message before upload.
const allowedMediaTypes = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
  "audio/mpeg",
  "audio/mp4",
  "video/mp4",
  "video/quicktime",
  "video/webm",
  "video/x-matroska"
]);

// Mirrors the server cap (MEDIA_MAX_SIZE_BYTES default, 100 MB). Pre-checked client-side for a
// friendly message before any upload attempt; the server enforces authoritatively (413 too_large).
const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;
const MAX_UPLOAD_MB = Math.floor(MAX_UPLOAD_BYTES / (1024 * 1024));
// Only raster images are compressed client-side before upload; everything else uploads as-is.
const compressibleImageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

export default function ChatPage() {
  const router = useRouter();
  const socketRef = useRef<Socket | null>(null);
  const typingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  // One-shot guard: a redirect to /login fires at most once per mount, so no re-trigger can hammer
  // history.replaceState into the browser's "more than 100 times per 10 seconds" SecurityError.
  const hasRedirectedRef = useRef(false);
  // message_ids already marked read this conversation (dedupes the mark-on-view socket pushes).
  const markedReadRef = useRef<Set<string>>(new Set());

  const [session, setSession] = useState<Session | null>(null);
  const [currentProfile, setCurrentProfile] = useState<UserProfile | null>(null);
  const [conversations, setConversations] = useState<ConversationListItem[]>([]);
  const [selectedConversationId, setSelectedConversationId] = useState("");
  const [selectedConversation, setSelectedConversation] =
    useState<ConversationDetail | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [channel, setChannel] = useState<ConversationChannel | null>(null);
  const [draft, setDraft] = useState("");
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [lookupUserId, setLookupUserId] = useState("");
  const [lookupProfile, setLookupProfile] = useState<UserProfile | null>(null);
  const [lookupStatus, setLookupStatus] = useState("");
  const [selectedParticipants, setSelectedParticipants] = useState<UserProfile[]>([]);
  const [status, setStatus] = useState("Loading session...");
  const [typingUser, setTypingUser] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isLookingUpProfile, setIsLookingUpProfile] = useState(false);
  const [isCreatingConversation, setIsCreatingConversation] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [mediaStatus, setMediaStatus] = useState("");
  const [isDetailsOpen, setIsDetailsOpen] = useState(false);
  // user_ids present in the CURRENT conversation channel (Phoenix.Presence). Per-conversation: it
  // reflects who has THIS conversation open, not global online state. Reset on conversation switch.
  const [onlineUserIds, setOnlineUserIds] = useState<string[]>([]);

  const selectedTitle = useMemo(() => {
    return selectedConversation?.title || selectedConversationId || "Select a conversation";
  }, [selectedConversation?.title, selectedConversationId]);

  useEffect(() => {
    async function loadInitialData() {
      try {
        const currentSession = await getCurrentSession();
        setSession(currentSession);
        setStatus(`Signed in as ${currentSession.user_id}`);

        getMe()
          .then((profile) => setCurrentProfile(profile))
          .catch(() => setCurrentProfile(null));

        const response = await listConversations();
        const loadedConversations = response.conversations ?? [];
        setConversations(loadedConversations);
        setSelectedConversationId(loadedConversations[0]?.conversation_id ?? "");
      } catch (error) {
        setStatus(error instanceof Error ? error.message : "Open /login first.");
        // Clear the (likely stale/expired) token BEFORE redirecting so the /login presence-guard
        // won't bounce us straight back here — that ping-pong was the replaceState loop. The clear is
        // unconditional: request() throws a plain Error without the HTTP status, so we can't cheaply
        // tell a 401 from a transient network/500 blip. A blip just lands the user on /login
        // (recoverable); a real auth failure is handled correctly. (Gating on 401 would need api.ts.)
        clearSessionTokens();
        if (!hasRedirectedRef.current) {
          hasRedirectedRef.current = true;
          router.replace("/login");
        }
      } finally {
        setIsLoading(false);
      }
    }

    void loadInitialData();
  }, [router]);

  useEffect(() => {
    if (!selectedConversationId) {
      return;
    }

    let isCurrent = true;

    async function loadConversation() {
      setStatus("Loading conversation...");

      try {
        const [detail, timeline] = await Promise.all([
          getConversation(selectedConversationId),
          listMessages(selectedConversationId)
        ]);

        if (!isCurrent) {
          return;
        }

        setSelectedConversation(detail);
        setMessages(timeline.messages ?? []);
        setStatus(`Opened ${detail.title || detail.conversation_id}`);
      } catch (error) {
        if (isCurrent) {
          setSelectedConversation(null);
          setMessages([]);
          setStatus(
            error instanceof Error ? error.message : "Could not load conversation."
          );
        }
      }
    }

    void loadConversation();

    return () => {
      isCurrent = false;
    };
  }, [selectedConversationId]);

  useEffect(() => {
    if (!selectedConversationId) {
      return;
    }

    let isActive = true;
    let cleanupEvents: Array<() => void> = [];
    let joinedChannel: ConversationChannel | null = null;

    async function connectChannel() {
      try {
        if (!socketRef.current) {
          socketRef.current = createSocket();
        }

        joinedChannel = await joinConversationChannel(
          socketRef.current,
          selectedConversationId
        );

        if (!isActive) {
          joinedChannel.leave();
          return;
        }

        cleanupEvents = [
          joinedChannel.onMessageCreated((message) => {
            setMessages((current) => mergeMessage(current, message));
          }),
          joinedChannel.onMessageUpdated((message) => {
            setMessages((current) => patchMessage(current, message));
          }),
          joinedChannel.onMessageDeleted((message) => {
            setMessages((current) => patchMessage(current, message));
          }),
          joinedChannel.onTypingStarted((payload) => {
            if (payload.user_id && payload.user_id !== session?.user_id) {
              setTypingUser(payload.user_id);
            }
          }),
          joinedChannel.onTypingStopped((payload) => {
            if (!payload.user_id || payload.user_id !== session?.user_id) {
              setTypingUser(null);
            }
          }),
          joinedChannel.onPresence((ids) => {
            if (isActive) setOnlineUserIds(ids);
          }),
          joinedChannel.onReceipt((data) => {
            const messageId = data?.payload?.message_id;
            if (!messageId) return;
            setMessages((current) =>
              current.map((item) => {
                if (item.message_id !== messageId) return item;
                // A read implies delivered, so bump both; delivered bumps only delivered. We track a
                // count (≥1 = at least one other has read/received) — exact for 1:1.
                const delivered = Math.max(item.delivered_by_count ?? 0, 1);
                return data.receipt_type === "read"
                  ? {
                      ...item,
                      read_by_count: Math.max(item.read_by_count ?? 0, 1),
                      delivered_by_count: delivered
                    }
                  : { ...item, delivered_by_count: delivered };
              })
            );
          })
        ];

        setChannel(joinedChannel);
      } catch {
        if (isActive) {
          setChannel(null);
        }
      }
    }

    void connectChannel();

    return () => {
      isActive = false;
      cleanupEvents.forEach((cleanup) => cleanup());
      joinedChannel?.leave();
      setChannel(null);
      setTypingUser(null);
      setOnlineUserIds([]);
    };
  }, [selectedConversationId, session?.user_id]);

  // Reset the per-conversation "already marked read" set when switching conversations.
  useEffect(() => {
    markedReadRef.current = new Set();
  }, [selectedConversationId]);

  // Mark OTHERS' messages as read once, while the conversation is open (channel connected). Ref-guarded
  // so it's idempotent — steady state pushes nothing; only newly-arrived messages trigger a mark. The
  // server persists each receipt and broadcasts receipt_updated, flipping the sender's tick to blue.
  useEffect(() => {
    if (!channel || !session?.user_id) return;
    for (const message of messages) {
      if (
        message.sender_user_id !== session.user_id &&
        !markedReadRef.current.has(message.message_id)
      ) {
        markedReadRef.current.add(message.message_id);
        void channel.markRead(message.message_id).catch(() => {
          markedReadRef.current.delete(message.message_id); // allow a retry on failure
        });
      }
    }
  }, [channel, messages, session?.user_id]);

  useEffect(() => {
    return () => {
      if (typingTimerRef.current) {
        clearTimeout(typingTimerRef.current);
      }

      socketRef.current?.disconnect();
    };
  }, []);

  async function refreshConversationList(selectConversationId?: string) {
    const response = await listConversations();
    const loadedConversations = response.conversations ?? [];
    setConversations(loadedConversations);
    setSelectedConversationId(
      selectConversationId ||
        selectedConversationId ||
        loadedConversations[0]?.conversation_id ||
        ""
    );
  }

  async function handleCreateConversation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const title = newTitle.trim();
    const participantUserIds = selectedParticipants.map((profile) => profile.user_id);

    if (!title || participantUserIds.length === 0) {
      setStatus("Enter a title and add at least one participant.");
      return;
    }

    setIsCreatingConversation(true);

    try {
      const conversation = await createConversation({
        title,
        participantUserIds
      });
      setNewTitle("");
      setLookupUserId("");
      setLookupProfile(null);
      setLookupStatus("");
      setSelectedParticipants([]);
      await refreshConversationList(conversation.conversation_id);
      setStatus("Conversation created.");
    } catch (error) {
      setStatus(
        error instanceof Error ? error.message : "Conversation creation failed."
      );
    } finally {
      setIsCreatingConversation(false);
    }
  }

  async function handleLookupProfile() {
    const userId = lookupUserId.trim();

    if (!userId) {
      setLookupStatus("Enter a user ID to look up.");
      setLookupProfile(null);
      return;
    }

    setIsLookingUpProfile(true);
    setLookupStatus("Looking up profile...");
    setLookupProfile(null);

    try {
      const profile = await getPublicProfile(userId);
      setLookupProfile(profile);
      setLookupStatus(
        profile.display_name
          ? "Profile found."
          : "Profile exists but has no display name yet."
      );
    } catch (error) {
      setLookupStatus(error instanceof Error ? error.message : "Profile lookup failed.");
    } finally {
      setIsLookingUpProfile(false);
    }
  }

  function handleAddParticipant() {
    if (!lookupProfile) {
      return;
    }

    setSelectedParticipants((current) => {
      if (current.some((profile) => profile.user_id === lookupProfile.user_id)) {
        return current;
      }

      return [...current, lookupProfile];
    });
    setLookupStatus("Participant added.");
    setLookupUserId("");
    setLookupProfile(null);
  }

  function handleRemoveParticipant(userId: string) {
    setSelectedParticipants((current) =>
      current.filter((profile) => profile.user_id !== userId)
    );
  }

  async function handleSend(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = draft.trim();

    if (!selectedConversationId || (!body && !selectedFile)) {
      return;
    }

    setIsSending(true);

    try {
      const message = selectedFile
        ? await uploadAndSendMediaMessage(selectedFile, body)
        : await sendCreate({
            conversationId: selectedConversationId,
            messageType: "text",
            body
          });

      setMessages((current) => mergeMessage(current, message));
      setDraft("");
      setSelectedFile(null);
      setMediaStatus("");
      if (fileInputRef.current) {
        fileInputRef.current.value = "";
      }
      setStatus(selectedFile ? "Media message sent." : "Message sent.");
      void channel?.stopTyping().catch(() => undefined);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Message send failed.");
    } finally {
      setIsSending(false);
    }
  }

  async function handleEditMessage(messageId: string, body: string) {
    try {
      const updated = (
        channel
          ? await channel.editMessage(messageId, body)
          : await editMessage(selectedConversationId, messageId, body)
      ) as Message;
      setMessages((current) =>
        current.map((item) =>
          item.message_id === messageId
            ? {
                ...item,
                body: updated.body ?? body,
                status: updated.status ?? item.status,
                edited_at: updated.edited_at ?? item.edited_at
              }
            : item
        )
      );
      setStatus("Message updated.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Message edit failed.");
      throw error;
    }
  }

  async function handleDeleteMessage(messageId: string) {
    try {
      const result = (
        channel
          ? await channel.deleteMessage(messageId)
          : await deleteMessage(selectedConversationId, messageId)
      ) as { status?: string; deleted_at?: string | null };
      setMessages((current) =>
        current.map((item) =>
          item.message_id === messageId
            ? {
                ...item,
                status: result.status ?? "deleted",
                deleted_at: result.deleted_at ?? item.deleted_at
              }
            : item
        )
      );
      setStatus("Message deleted.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Message delete failed.");
      throw error;
    }
  }

  // Route message creation over the realtime channel when connected so other
  // clients receive `message_created` live (broadcast_from excludes the sender,
  // which inserts from this reply). Falls back to HTTP create when no socket.
  async function sendCreate(input: CreateMessageInput): Promise<Message> {
    if (channel) {
      const reply = await channel.sendMessage({
        message_type: input.messageType,
        body: input.body,
        media_id: input.mediaId,
        caption: input.caption,
        metadata: input.metadata
      });

      return reply as Message;
    }

    return createMessage(input);
  }

  async function uploadAndSendMediaMessage(file: File, caption: string) {
    if (!allowedMediaTypes.has(file.type)) {
      throw new Error(`${file.type || "This file type"} is not supported yet.`);
    }

    // Compress raster images before upload (downscale ~1920px, ~1MB target) to cut upload size and
    // bandwidth. Non-images upload as-is. Any compression failure falls back to the original file.
    let uploadFile = file;
    if (compressibleImageTypes.has(file.type)) {
      setMediaStatus("Compressing image...");
      try {
        uploadFile = await imageCompression(file, {
          maxSizeMB: 1,
          maxWidthOrHeight: 1920,
          initialQuality: 0.8,
          useWebWorker: true
        });
      } catch {
        uploadFile = file;
      }
    }

    const contentType = uploadFile.type || file.type || "application/octet-stream";

    setMediaStatus("Preparing upload...");
    const upload = await createMediaUpload({
      filename: file.name,
      content_type: contentType,
      size_bytes: uploadFile.size
    });

    setMediaStatus("Uploading...");
    const uploadResponse = await fetch(upload.upload_url, {
      method: "PUT",
      body: uploadFile,
      headers: {
        "Content-Type": contentType
      }
    });

    if (!uploadResponse.ok) {
      throw new Error(`Upload failed with ${uploadResponse.status}`);
    }

    setMediaStatus("Completing upload...");
    await completeMediaUpload(upload.media_id, upload.object_key);

    setMediaStatus("Sending media message...");
    const mediaMetadata = {
      object_key: upload.object_key,
      filename: file.name,
      content_type: contentType,
      size_bytes: uploadFile.size
    };

    const message = await sendCreate({
      conversationId: selectedConversationId,
      messageType: "media",
      mediaId: upload.media_id,
      caption,
      metadata: mediaMetadata
    });

    return {
      ...message,
      metadata: {
        ...mediaMetadata,
        ...(message.metadata ?? {})
      }
    };
  }

  function handleDraftChange(value: string) {
    setDraft(value);

    if (!channel) {
      return;
    }

    void channel.startTyping().catch(() => undefined);

    if (typingTimerRef.current) {
      clearTimeout(typingTimerRef.current);
    }

    typingTimerRef.current = setTimeout(() => {
      void channel.stopTyping().catch(() => undefined);
    }, 900);
  }

  function handleFileChange(file: File | null) {
    if (file && !allowedMediaTypes.has(file.type)) {
      setSelectedFile(null);
      setMediaStatus(`${file.type || "This file type"} is not supported yet.`);
      if (fileInputRef.current) {
        fileInputRef.current.value = "";
      }
      return;
    }

    // Friendly pre-check so an oversized file is rejected before any upload work. Images are
    // compressed before upload, so this only blocks truly enormous originals (e.g. a huge video).
    if (file && file.size > MAX_UPLOAD_BYTES) {
      setSelectedFile(null);
      setMediaStatus(`File too large — max ${MAX_UPLOAD_MB} MB.`);
      if (fileInputRef.current) {
        fileInputRef.current.value = "";
      }
      return;
    }

    setSelectedFile(file);
    setMediaStatus(file ? `Selected ${file.name}` : "");
  }

  function handleClearSelectedFile() {
    setSelectedFile(null);
    setMediaStatus("");
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
  }

  function handleLogout() {
    clearSessionTokens();
    socketRef.current?.disconnect();
    router.replace("/login");
  }

  // --- Presentational derivations (no logic change) -------------------------------------------
  // Someone OTHER than me is present in the current conversation (drives the header online indicator).
  const othersOnline = onlineUserIds.some((id) => id !== session?.user_id);
  const participantCount = selectedConversation?.participants?.length ?? 0;
  const headerSubtitle =
    participantCount > 0
      ? `${participantCount} participant${participantCount === 1 ? "" : "s"}`
      : selectedConversation?.type;
  // The signed-in identity now lives in the sidebar; the "Opened …" line is implicit in the header.
  // Surface only transient, actionable status (sends, errors) as a subtle banner.
  const showBanner = Boolean(
    status && !status.startsWith("Signed in as") && !status.startsWith("Opened ")
  );
  const bannerTone: "neutral" | "error" = /fail|could not|invalid|error|unable|first/i.test(status)
    ? "error"
    : "neutral";

  return (
    <main className="flex h-screen overflow-hidden bg-bg">
      {/* Sidebar — full width on mobile when no conversation is open, fixed pane at md+ */}
      <div
        className={cn(
          "w-full shrink-0 md:block md:w-[340px]",
          selectedConversationId ? "hidden md:block" : "block"
        )}
      >
        <ConversationSidebar
          session={session}
          currentProfile={currentProfile}
          onLogout={handleLogout}
          newTitle={newTitle}
          onNewTitleChange={setNewTitle}
          onCreateConversation={handleCreateConversation}
          isCreatingConversation={isCreatingConversation}
          lookupUserId={lookupUserId}
          onLookupUserIdChange={setLookupUserId}
          onLookup={handleLookupProfile}
          isLookingUpProfile={isLookingUpProfile}
          lookupStatus={lookupStatus}
          lookupProfile={lookupProfile}
          onAddParticipant={handleAddParticipant}
          selectedParticipants={selectedParticipants}
          onRemoveParticipant={handleRemoveParticipant}
          conversations={conversations}
          selectedConversationId={selectedConversationId}
          onSelectConversation={setSelectedConversationId}
          isLoading={isLoading}
        />
      </div>

      {/* Chat pane */}
      <section
        className={cn(
          "relative min-w-0 flex-1 flex-col",
          selectedConversationId ? "flex" : "hidden md:flex"
        )}
      >
        {showBanner && <StatusBanner message={status} tone={bannerTone} />}

        <ChatHeader
          conversationId={selectedConversationId}
          title={selectedTitle}
          subtitle={headerSubtitle ?? undefined}
          typingUser={typingUser}
          online={othersOnline}
          onBack={() => setSelectedConversationId("")}
          onOpenDetails={() => setIsDetailsOpen(true)}
        />

        <MessageList
          messages={messages}
          currentUserId={session?.user_id}
          isLoading={isLoading}
          hasConversation={Boolean(selectedConversationId)}
          onEdit={handleEditMessage}
          onDelete={handleDeleteMessage}
        />

        <Composer
          draft={draft}
          onDraftChange={handleDraftChange}
          onSubmit={handleSend}
          hasConversation={Boolean(selectedConversationId)}
          isSending={isSending}
          selectedFile={selectedFile}
          onPickFile={() => fileInputRef.current?.click()}
          onFileChange={handleFileChange}
          onClearFile={handleClearSelectedFile}
          mediaStatus={mediaStatus}
          fileInputRef={fileInputRef}
          acceptTypes="image/*,video/*,audio/*,application/pdf"
        />

        <ConversationDetailsPanel
          conversation={selectedConversation}
          conversationId={selectedConversationId}
          title={selectedTitle}
          isOpen={isDetailsOpen && Boolean(selectedConversationId)}
          onClose={() => setIsDetailsOpen(false)}
          onlineUserIds={onlineUserIds}
        />
      </section>
    </main>
  );
}

function mergeMessage(messages: Message[], message: Message) {
  const exists = messages.some((item) => item.message_id === message.message_id);

  if (exists) {
    return messages.map((item) =>
      item.message_id === message.message_id ? message : item
    );
  }

  return [...messages, message];
}

// Idempotent patch for realtime message_updated / message_deleted events. The
// event payload is a partial message (e.g. body/status/edited_at or
// status/deleted_at), so absent fields are preserved by spreading over the
// existing item. Patching by message_id keeps the acting client dupe-free.
function patchMessage(messages: Message[], patch: Message) {
  return messages.map((item) =>
    item.message_id === patch.message_id ? { ...item, ...patch } : item
  );
}
