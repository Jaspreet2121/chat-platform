"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  ConversationDetail,
  ConversationListItem,
  CreateMessageInput,
  Message,
  ReactionCount,
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
  listConversations,
  listMessages,
  reactToMessage,
  removeReaction,
  starMessage,
  unstarMessage
} from "@/lib/api";
import { clearSessionTokens } from "@/lib/session";
import { disablePush } from "@/lib/push";
import {
  ConversationChannel,
  createSocket,
  joinConversationChannel,
  joinUserChannel
} from "@/lib/realtime";
import type { MessageToast } from "@/components/chat";
import type { Socket } from "phoenix";
import {
  ChatHeader,
  Composer,
  ConversationDetailsPanel,
  ConversationSidebar,
  MessageList,
  MyProfileModal,
  CallsComingSoon,
  NavRail,
  NotificationToasts,
  notificationSoundEnabled,
  playNotificationBlip,
  ProfileTab,
  StarredPanel,
  StatusBanner
} from "@/components/chat";
import { primeUserProfile, useUserProfile } from "@/components/chat/useUserProfile";
import { pickDirectPeer, primeConversationDetail } from "@/components/chat/useDirectPeer";
import { cn } from "@/lib/cn";
import imageCompression from "browser-image-compression";
import { ForwardPicker } from "./ForwardPicker";

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
  "audio/webm",
  "audio/ogg",
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
  // The message currently being replied to (quoted), and the one being forwarded (picker target).
  const [replyingTo, setReplyingTo] = useState<Message | null>(null);
  const [forwardingMessage, setForwardingMessage] = useState<Message | null>(null);
  const [newTitle, setNewTitle] = useState("");
  const [selectedParticipants, setSelectedParticipants] = useState<UserProfile[]>([]);
  // New-conversation mode: "direct" = 1:1 (no title, one participant), "group" = titled multi-party.
  // Direct is the default since 1:1 chats are the common case. Drives the create branch + the modal UI.
  // Rail → sidebar signals: bump to open the new-conversation modal / focus the phone search.
  const [newConvNonce, setNewConvNonce] = useState(0);
  const [searchFocusNonce, setSearchFocusNonce] = useState(0);
  // Mobile screen behind the tab bar: Messages (the list) / Calls placeholder / the "You" profile tab.
  const [mobileView, setMobileView] = useState<"chats" | "calls" | "profile">("chats");
  // In-app notification toasts (new messages in conversations the user is NOT viewing).
  const [toasts, setToasts] = useState<MessageToast[]>([]);
  // The open conversation, readable from the long-lived user-channel handler (no stale closure).
  const selectedConversationRef = useRef("");
  useEffect(() => {
    selectedConversationRef.current = selectedConversationId;
  }, [selectedConversationId]);

  // Float a conversation to the top with a fresh preview when a message is sent/received in the OPEN
  // chat (the user-channel handler covers the not-open ones). Unread stays as-is (the chat is open).
  function bumpConversationActivity(message: Message) {
    setConversations((current) =>
      current.map((c) =>
        c.conversation_id === message.conversation_id
          ? {
              ...c,
              last_message_preview: message.body?.trim() || null,
              last_message_kind: message.media_id ? mediaKind(message) : "text",
              updated_at: message.created_at
            }
          : c
      )
    );
  }
  const [status, setStatus] = useState("Loading session...");
  const [typingUser, setTypingUser] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreatingConversation, setIsCreatingConversation] = useState(false);
  const [isSending, setIsSending] = useState(false);
  const [mediaStatus, setMediaStatus] = useState("");
  const [isDetailsOpen, setIsDetailsOpen] = useState(false);
  const [isStarredOpen, setIsStarredOpen] = useState(false);
  const [isProfileOpen, setIsProfileOpen] = useState(false);
  // Target message to scroll to + highlight (from a search / starred result). The nonce makes
  // re-jumping to the SAME message (or re-clicking the same result) re-trigger the scroll.
  const [scrollTarget, setScrollTarget] = useState<{ id: string; n: number } | null>(null);
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
          .then((profile) => {
            setCurrentProfile(profile);
            primeUserProfile(profile); // so the user's own avatar is cached for any self-rendered Avatar
          })
          .catch(() => setCurrentProfile(null));

        const response = await listConversations();
        const loadedConversations = response.conversations ?? [];
        setConversations(loadedConversations);
        // Deep link (?conversation=<id> — push-notification taps land here): open that chat.
        // Otherwise: desktop auto-opens the first conversation; mobile lands on the Messages LIST.
        const linked = new URLSearchParams(window.location.search).get("conversation");
        if (linked && loadedConversations.some((c) => c.conversation_id === linked)) {
          setSelectedConversationId(linked);
          window.history.replaceState(null, "", "/chat");
        } else {
          setSelectedConversationId(
            isDesktopViewport() ? loadedConversations[0]?.conversation_id ?? "" : ""
          );
        }
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

        // Seed the shared detail cache so the sidebar row derives this chat's peer with no refetch.
        primeConversationDetail(detail);
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
            bumpConversationActivity(message);
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
          }),
          joinedChannel.onReactionUpdated((data) => {
            if (!data?.message_id) return;
            // Remote update: patch the per-emoji counts only. my_reaction reflects THIS viewer's own
            // reaction, which a broadcast from another user never changes.
            setMessages((current) =>
              current.map((item) =>
                item.message_id === data.message_id
                  ? { ...item, reactions: data.reactions ?? [] }
                  : item
              )
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
        (isDesktopViewport() ? loadedConversations[0]?.conversation_id : "") ||
        ""
    );
  }

  // GROUP creation (1:1 direct chats start straight from the phone search — handleStartDirectChat).
  // Participants arrive phone-resolved from the modal; the API takes their user IDs unchanged.
  async function handleCreateConversation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const title = newTitle.trim();
    const participantUserIds = selectedParticipants.map((profile) => profile.user_id);

    if (participantUserIds.length === 0) {
      setStatus("Add at least one participant.");
      return;
    }
    if (!title) {
      setStatus("Add a title for a group conversation.");
      return;
    }

    setIsCreatingConversation(true);

    try {
      const conversation = await createConversation({ title, participantUserIds, type: "group" });
      setNewTitle("");
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

  // Primary header search → "Message": create a 1:1 direct chat with the phone-resolved peer and open
  // it. Same create path as the modal's direct flow (no find-or-create dedup yet — a known follow-up).
  async function handleStartDirectChat(profile: UserProfile) {
    try {
      const conversation = await createConversation({
        title: profile.display_name?.trim() || "Direct chat",
        participantUserIds: [profile.user_id],
        type: "direct"
      });
      await refreshConversationList(conversation.conversation_id);
      setStatus("Direct chat created.");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Couldn't start the chat.");
    }
  }

  // Append a phone-resolved group participant (deduped by user id).
  function handleAddParticipant(profile: UserProfile) {
    setSelectedParticipants((current) =>
      current.some((existing) => existing.user_id === profile.user_id)
        ? current
        : [...current, profile]
    );
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
    const replyToId = replyingTo?.message_id;

    try {
      const message = selectedFile
        ? await uploadAndSendMediaMessage(selectedFile, body, replyToId)
        : await sendCreate({
            conversationId: selectedConversationId,
            messageType: "text",
            body,
            replyToMessageId: replyToId
          });

      setMessages((current) => mergeMessage(current, message));
      bumpConversationActivity(message);
      setDraft("");
      setSelectedFile(null);
      setReplyingTo(null);
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

  // Send a recorded voice message: feed the blob (as a File) through the existing media upload+send flow
  // (no compression — audio uploads as-is) so it renders via the inline <audio> player like any media.
  // Rethrows on failure so the Composer keeps the recording preview for a retry.
  async function handleSendVoice(file: File) {
    if (!selectedConversationId) return;
    setIsSending(true);
    const replyToId = replyingTo?.message_id;
    try {
      const message = await uploadAndSendMediaMessage(file, "", replyToId);
      setMessages((current) => mergeMessage(current, message));
      bumpConversationActivity(message);
      setReplyingTo(null);
      setMediaStatus("");
      setStatus("Voice message sent.");
      void channel?.stopTyping().catch(() => undefined);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Voice message send failed.");
      throw error;
    } finally {
      setIsSending(false);
    }
  }

  // Forward the chosen message to a target conversation: re-send its content with a forwarded marker.
  // Same conversation → over the socket (live + merge); another conversation → REST (shows on open).
  async function handleForward(target: ConversationListItem) {
    const source = forwardingMessage;
    if (!source) return;
    setForwardingMessage(null);

    const input: CreateMessageInput = {
      conversationId: target.conversation_id,
      messageType: source.media_id ? "media" : "text",
      body: source.body ?? undefined,
      mediaId: source.media_id ?? undefined,
      caption: source.caption ?? undefined,
      metadata: { ...(source.metadata ?? {}), forwarded_from: source.sender_user_id }
    };

    try {
      if (target.conversation_id === selectedConversationId) {
        const message = await sendCreate(input);
        setMessages((current) => mergeMessage(current, message));
      bumpConversationActivity(message);
      } else {
        await createMessage(input);
      }
      setStatus(`Forwarded to ${target.title || target.conversation_id}.`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Forward failed.");
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

  // Set/change my reaction (one per user). Optimistic: highlight + adjust counts instantly, then patch
  // with the authoritative aggregate from the channel reply (or REST fallback). Revert on failure.
  async function handleReact(messageId: string, emoji: string) {
    const previous = messages.find((item) => item.message_id === messageId);
    setMessages((current) =>
      current.map((item) =>
        item.message_id === messageId ? applyMyReaction(item, emoji) : item
      )
    );
    try {
      const result = (
        channel
          ? await channel.reactToMessage(messageId, emoji)
          : await reactToMessage(selectedConversationId, messageId, emoji)
      ) as { message_id?: string; reactions?: ReactionCount[] };
      if (result?.reactions) {
        setMessages((current) =>
          current.map((item) =>
            item.message_id === messageId
              ? { ...item, reactions: result.reactions ?? [], my_reaction: emoji }
              : item
          )
        );
      }
    } catch (error) {
      if (previous) {
        setMessages((current) =>
          current.map((item) => (item.message_id === messageId ? previous : item))
        );
      }
      setStatus(error instanceof Error ? error.message : "Reaction failed.");
    }
  }

  async function handleRemoveReaction(messageId: string) {
    const previous = messages.find((item) => item.message_id === messageId);
    setMessages((current) =>
      current.map((item) =>
        item.message_id === messageId ? applyMyReaction(item, null) : item
      )
    );
    try {
      const result = (
        channel
          ? await channel.removeReaction(messageId)
          : await removeReaction(selectedConversationId, messageId)
      ) as { message_id?: string; reactions?: ReactionCount[] };
      if (result?.reactions) {
        setMessages((current) =>
          current.map((item) =>
            item.message_id === messageId
              ? { ...item, reactions: result.reactions ?? [], my_reaction: null }
              : item
          )
        );
      }
    } catch (error) {
      if (previous) {
        setMessages((current) =>
          current.map((item) => (item.message_id === messageId ? previous : item))
        );
      }
      setStatus(error instanceof Error ? error.message : "Reaction failed.");
    }
  }

  // Star/unstar are private (REST-only, no broadcast). Optimistically flip is_starred, revert on error.
  async function handleStar(messageId: string) {
    setMessages((current) => patchStar(current, messageId, true));
    try {
      await starMessage(selectedConversationId, messageId);
    } catch (error) {
      setMessages((current) => patchStar(current, messageId, false));
      setStatus(error instanceof Error ? error.message : "Could not star message.");
    }
  }

  async function handleUnstar(messageId: string) {
    setMessages((current) => patchStar(current, messageId, false));
    try {
      await unstarMessage(selectedConversationId, messageId);
    } catch (error) {
      setMessages((current) => patchStar(current, messageId, true));
      setStatus(error instanceof Error ? error.message : "Could not unstar message.");
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
        metadata: input.metadata,
        reply_to_message_id: input.replyToMessageId
      });

      return reply as Message;
    }

    return createMessage(input);
  }

  async function uploadAndSendMediaMessage(file: File, caption: string, replyToMessageId?: string) {
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
      metadata: mediaMetadata,
      replyToMessageId
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

  // After saving My Profile: merge the returned profile (incl. fresh avatar_url) into local state and
  // prime the shared cache so the new avatar/name show immediately wherever the user is rendered.
  function handleProfileSaved(updated: UserProfile) {
    setCurrentProfile((current) => ({ ...(current ?? {}), ...updated }));
    primeUserProfile(updated);
    setStatus("Profile updated.");
  }

  // Open the conversation a search/starred result belongs to, then ask MessageList to scroll to +
  // highlight that message once it's loaded (the bumped nonce re-triggers even for the same target).
  function handleJumpToMessage(conversationId: string, messageId: string) {
    setSelectedConversationId(conversationId);
    setScrollTarget((prev) => ({ id: messageId, n: (prev?.n ?? 0) + 1 }));
  }

  function handleLogout() {
    // Best-effort: unsubscribe this browser + delete the stored subscription while the session token
    // is still valid — a logged-out device must stop receiving message pushes.
    void disablePush();
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

  // A direct (1:1) chat has no meaningful title — show the OTHER participant. Derive the peer from the
  // loaded conversation detail (participants minus me) and resolve their public profile for a real name
  // + avatar. Falls back to the stored title, then "Member", until the profile resolves.
  const selectedIsDirect = selectedConversation?.type === "direct";
  const directPeerId = useMemo(() => {
    if (!selectedIsDirect) return null;
    // SHARED derivation (same helper as the sidebar rows — the two can't drift): participants minus
    // me; self-chat resolves to me; unknown session → null (never guess).
    return pickDirectPeer(selectedConversation?.participants, session?.user_id) ?? null;
  }, [selectedIsDirect, selectedConversation?.participants, session?.user_id]);
  const directPeerProfile = useUserProfile(directPeerId);
  // Direct-chat title = the OTHER person. NEVER fall back to selectedConversation.title: for a direct
  // chat the stored title is the creator-set peer name, so on the RECIPIENT's side it's their OWN name.
  // Use the peer's live display_name, else a stable handle from their id — never self.
  const headerTitle = selectedIsDirect
    ? directPeerProfile?.display_name?.trim() ||
      (directPeerId ? `${directPeerId.slice(0, 8)}…` : "Member")
    : selectedTitle;
  const headerAvatarId = selectedIsDirect
    ? directPeerId ?? selectedConversationId
    : selectedConversationId;
  const headerAvatarUrl = selectedIsDirect
    ? directPeerProfile?.avatar_url ?? null
    : selectedConversation?.group_avatar_url ?? null;
  // The signed-in identity now lives in the sidebar; the "Opened …" line is implicit in the header.
  // Surface only transient, actionable status (sends, errors) as a subtle banner.
  const showBanner = Boolean(
    status && !status.startsWith("Signed in as") && !status.startsWith("Opened ")
  );
  const bannerTone: "neutral" | "error" = /fail|could not|invalid|error|unable|first/i.test(status)
    ? "error"
    : "neutral";

  // PWA app-icon badge (Badging API) — AUTHORITATIVE reconciler. Whenever the unread total changes
  // while the app is open/focused, set the badge to the real total (or clear it at zero — which also
  // covers "opened the last unread chat"). This fixes any drift left by the SW's push-time estimate.
  // Feature-detected → no-op where unsupported (older iOS, non-installed browsers).
  useEffect(() => {
    if (!("setAppBadge" in navigator)) return;
    const total = conversations.reduce((sum, c) => sum + (c.unread_count ?? 0), 0);
    if (total > 0) {
      void navigator.setAppBadge(total).catch(() => undefined);
    } else {
      void navigator.clearAppBadge?.().catch(() => undefined);
    }
  }, [conversations]);

  // IN-APP notifications: join MY OWN user topic once per session. The backend mirrors
  // message_created for every conversation I participate in onto it — so messages in chats I'm NOT
  // viewing produce a toast + a live unread bump (never for my own sends; never for the open chat,
  // whose conversation channel already renders the message inline).
  useEffect(() => {
    if (!session?.user_id) return;
    let isActive = true;
    let unsubscribe: (() => void) | null = null;
    let leave: (() => void) | null = null;

    (async () => {
      try {
        if (!socketRef.current) socketRef.current = createSocket();
        const userChannel = await joinUserChannel(socketRef.current, session.user_id);
        if (!isActive) {
          userChannel.leave();
          return;
        }
        leave = userChannel.leave;
        unsubscribe = userChannel.onMessageCreated((message) => {
          if (!message?.conversation_id) return;
          if (message.sender_user_id === session.user_id) return;
          if (message.conversation_id === selectedConversationRef.current) return;

          // Live unread bump + fresh preview on the list row (server remains the source of truth on
          // the next list fetch). Unknown conversation (brand-new chat) → refetch the list.
          setConversations((current) => {
            if (!current.some((c) => c.conversation_id === message.conversation_id)) {
              void refreshConversationList();
              return current;
            }
            return current.map((c) =>
              c.conversation_id === message.conversation_id
                ? {
                    ...c,
                    unread_count: (c.unread_count ?? 0) + 1,
                    last_message_preview: message.body?.trim() || null,
                    last_message_kind: message.media_id ? mediaKind(message) : "text",
                    updated_at: message.created_at
                  }
                : c
            );
          });

          // Show ONLY the latest in-app toast — a new message replaces the current one (no pileup).
          setToasts([{ id: `${message.message_id}:${Date.now()}`, message }]);
          if (notificationSoundEnabled()) playNotificationBlip();
        });
      } catch {
        // Notifications are best-effort — chat works without the user topic.
      }
    })();

    return () => {
      isActive = false;
      unsubscribe?.();
      leave?.();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- join once per signed-in user
  }, [session?.user_id]);

  // Keyboard handling — LET SAFARI DO IT. The composer/search inputs live in NORMAL flow (nothing
  // fixed/transformed above them), and iOS Safari natively pans the focused input above the keyboard.
  // Two previous "clever" fixes failed on device because window.innerHeight ALSO shrinks with the
  // keyboard on modern iOS, so the `innerHeight - vv.height` keyboard detector never fired — and its
  // "closed" branch ran window.scrollTo(0,0) on every viewport event, actively CANCELLING Safari's
  // native reveal (that was the hidden-composer bug). So: no pinning, no transforms, no scroll resets
  // while an input is focused. Just:
  //   * focus assist — nudge the focused text input into view once the keyboard has settled;
  //   * blur cleanup — after the LAST input blurs (keyboard closing), clear any residual document pan
  //     so the header can't end up clipped (the reset can never fire mid-typing: an input is focused).
  // True while any text input is focused (mobile keyboard likely open) — used to hide the floating
  // bottom tab bar + compose FAB, which iOS would otherwise pin above the keyboard mid-screen.
  const [inputFocused, setInputFocused] = useState(false);

  useEffect(() => {
    let assistTimer: ReturnType<typeof setTimeout> | undefined;
    let cleanupTimer: ReturnType<typeof setTimeout> | undefined;

    function isTextInput(target: EventTarget | null): target is HTMLElement {
      return (
        target instanceof HTMLElement &&
        (target.tagName === "INPUT" || target.tagName === "TEXTAREA")
      );
    }

    function onFocusIn(event: FocusEvent) {
      if (!isTextInput(event.target)) return;
      setInputFocused(true);
      const input = event.target;
      clearTimeout(assistTimer);
      // After the keyboard animation (~250ms), gently ensure the input is visible. block:"nearest"
      // is a no-op when Safari's own reveal already did the job.
      assistTimer = setTimeout(() => {
        input.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }, 300);
    }

    function onFocusOut() {
      clearTimeout(cleanupTimer);
      cleanupTimer = setTimeout(() => {
        // Only when focus really left all inputs (not moved between them) and the pan lingered.
        if (isTextInput(document.activeElement)) return;
        setInputFocused(false);
        if (window.scrollY !== 0 || document.documentElement.scrollTop !== 0) {
          window.scrollTo(0, 0);
          document.documentElement.scrollTop = 0;
        }
      }, 350);
    }

    document.addEventListener("focusin", onFocusIn);
    document.addEventListener("focusout", onFocusOut);
    return () => {
      clearTimeout(assistTimer);
      clearTimeout(cleanupTimer);
      document.removeEventListener("focusin", onFocusIn);
      document.removeEventListener("focusout", onFocusOut);
    };
  }, []);

  // Open a conversation from anywhere (row tap, toast tap): select it, surface the chats view, and
  // optimistically zero its unread badge (the server resets it authoritatively via read receipts).
  function openConversation(conversationId: string) {
    setMobileView("chats");
    setSelectedConversationId(conversationId);
    setConversations((current) =>
      current.map((c) =>
        c.conversation_id === conversationId ? { ...c, unread_count: 0 } : c
      )
    );
  }

  const hasUnread = conversations.some((c) => (c.unread_count ?? 0) > 0);
  const unreadTotal = conversations.reduce((sum, c) => sum + (c.unread_count ?? 0), 0);

  return (
    // The app floats as one rounded card on a soft periwinkle page from xl up (the mock's depth);
    // below xl it fills the viewport edge-to-edge.
    <main className="flex h-dvh overflow-hidden bg-bg xl:items-center xl:justify-center xl:p-5">
      <div className="flex h-full w-full overflow-hidden max-md:pt-[env(safe-area-inset-top)] xl:max-w-[1440px] xl:rounded-2xl xl:border xl:border-border xl:shadow-elevated">
      {/* Desktop: thin indigo rail. Mobile: bottom tab bar (hidden while a chat is open full-screen). */}
      <NavRail
        session={session}
        currentProfile={currentProfile}
        hasUnread={hasUnread}
        unreadCount={unreadTotal}
        mobileHidden={Boolean(selectedConversationId) || inputFocused}
        activeView={mobileView}
        onSelectView={setMobileView}
        onNewGroup={() => {
          setMobileView("chats");
          setNewConvNonce((n) => n + 1);
        }}
        onInvite={() => {
          setMobileView("chats");
          setSearchFocusNonce((n) => n + 1);
        }}
        onOpenStarred={() => setIsStarredOpen(true)}
        onOpenProfile={() => setIsProfileOpen(true)}
        onLogout={handleLogout}
      />

      {/* Mobile alternate views (Calls placeholder / Profile) — replace the list below md. */}
      {!selectedConversationId && mobileView !== "chats" ? (
        <div className="w-full shrink-0 md:hidden">
          {mobileView === "profile" ? (
            <ProfileTab
              session={session}
              currentProfile={currentProfile}
              onEditProfile={() => setIsProfileOpen(true)}
              onOpenStarred={() => setIsStarredOpen(true)}
              onInvite={() => {
                setMobileView("chats");
                setSearchFocusNonce((n) => n + 1);
              }}
              onLogout={handleLogout}
            />
          ) : (
            <CallsComingSoon />
          )}
        </div>
      ) : null}

      {/* Sidebar — full width on mobile when no conversation is open (with tab-bar clearance), fixed
          pane at md+. */}
      <div
        className={cn(
          "w-full shrink-0 md:block md:w-[340px]",
          "max-md:pb-[calc(84px+env(safe-area-inset-bottom))]",
          selectedConversationId || mobileView !== "chats" ? "hidden md:block" : "block"
        )}
      >
        <ConversationSidebar
          openNewConvNonce={newConvNonce}
          searchFocusNonce={searchFocusNonce}
          fabHidden={inputFocused}
          session={session}
          currentProfile={currentProfile}
          onLogout={handleLogout}
          onOpenStarred={() => setIsStarredOpen(true)}
          onOpenProfile={() => setIsProfileOpen(true)}
          newTitle={newTitle}
          onNewTitleChange={setNewTitle}
          onCreateConversation={handleCreateConversation}
          isCreatingConversation={isCreatingConversation}
          onAddParticipant={handleAddParticipant}
          selectedParticipants={selectedParticipants}
          onRemoveParticipant={handleRemoveParticipant}
          onStartDirectChat={handleStartDirectChat}
          conversations={conversations}
          selectedConversationId={selectedConversationId}
          onSelectConversation={openConversation}
          onJumpToMessage={handleJumpToMessage}
          isLoading={isLoading}
        />
      </div>

      {/* Chat pane — on mobile it slides in full-screen over the list. */}
      <section
        className={cn(
          "relative min-w-0 flex-1 flex-col bg-surface",
          selectedConversationId ? "flex max-md:animate-slide-in-right" : "hidden md:flex"
        )}
      >
        {showBanner && <StatusBanner message={status} tone={bannerTone} />}

        <ChatHeader
          conversationId={selectedConversationId}
          title={headerTitle}
          avatarId={headerAvatarId}
          avatarUrl={headerAvatarUrl}
          subtitle={headerSubtitle ?? undefined}
          typingUser={typingUser}
          online={othersOnline}
          onBack={() => setSelectedConversationId("")}
          onOpenDetails={() => setIsDetailsOpen(true)}
        />

        <MessageList
          messages={messages}
          isDirect={selectedIsDirect}
          currentUserId={session?.user_id}
          isLoading={isLoading}
          hasConversation={Boolean(selectedConversationId)}
          scrollTarget={scrollTarget}
          onEdit={handleEditMessage}
          onDelete={handleDeleteMessage}
          onReply={(m) => setReplyingTo(m)}
          onForward={(m) => setForwardingMessage(m)}
          onReact={handleReact}
          onRemoveReaction={handleRemoveReaction}
          onStar={handleStar}
          onUnstar={handleUnstar}
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
          replyPreview={
            replyingTo
              ? {
                  name:
                    replyingTo.sender_user_id === session?.user_id
                      ? "You"
                      : `#${replyingTo.sender_user_id.slice(0, 8)}`,
                  snippet: replyingTo.media_id ? "Media" : replyingTo.body || "Message"
                }
              : null
          }
          onCancelReply={() => setReplyingTo(null)}
          onSendVoice={handleSendVoice}
        />

        <ConversationDetailsPanel
          conversation={selectedConversation}
          conversationId={selectedConversationId}
          title={headerTitle}
          isOpen={isDetailsOpen && Boolean(selectedConversationId)}
          onClose={() => setIsDetailsOpen(false)}
          onlineUserIds={onlineUserIds}
          currentUserId={session?.user_id}
          messages={messages}
          onJumpToMessage={handleJumpToMessage}
          onCleared={() => {
            // Refetch THIS user's (now-narrowed) timeline; other participants and admin are unaffected.
            setMessages([]);
            if (selectedConversationId) {
              void listMessages(selectedConversationId).then(
                (timeline) => setMessages(timeline.messages ?? []),
                () => undefined
              );
            }
          }}
          onGroupUpdated={() => {
            // Group name/photo changed → refresh the conversation detail (header/hero) + the list rows.
            if (selectedConversationId) {
              void getConversation(selectedConversationId).then(
                (detail) => {
                  setSelectedConversation(detail);
                  primeConversationDetail(detail);
                },
                () => undefined
              );
            }
            void refreshConversationList(selectedConversationId);
          }}
        />

        {forwardingMessage ? (
          <ForwardPicker
            conversations={conversations}
            onPick={handleForward}
            onClose={() => setForwardingMessage(null)}
          />
        ) : null}
      </section>

      {/* In-app notification toasts (new messages in other conversations). */}
      <NotificationToasts
        toasts={toasts}
        onOpen={openConversation}
        onDismiss={(id) => setToasts((current) => current.filter((t) => t.id !== id))}
      />

      <StarredPanel
        isOpen={isStarredOpen}
        onClose={() => setIsStarredOpen(false)}
        conversations={conversations}
        currentUserId={session?.user_id}
        onJump={handleJumpToMessage}
      />

      {isProfileOpen && session ? (
        <MyProfileModal
          onClose={() => setIsProfileOpen(false)}
          profile={currentProfile}
          userId={session.user_id}
          onSaved={handleProfileSaved}
        />
      ) : null}
      </div>
    </main>
  );
}

// Row-preview kind for a live media message (mirrors the server's last_message_kind mapping).
function mediaKind(message: Message): string {
  const contentType = String(
    (message.metadata as Record<string, unknown> | null | undefined)?.content_type ?? ""
  );
  if (contentType.startsWith("image/")) return "image";
  if (contentType.startsWith("video/")) return "video";
  if (contentType.startsWith("audio/")) return "audio";
  return "file";
}

// md breakpoint — the same 768px the layout splits panes on. Guarded for SSR.
function isDesktopViewport(): boolean {
  return typeof window !== "undefined" && window.matchMedia("(min-width: 768px)").matches;
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

// Flip the is_starred flag for one message (optimistic star/unstar).
function patchStar(messages: Message[], messageId: string, isStarred: boolean) {
  return messages.map((item) =>
    item.message_id === messageId ? { ...item, is_starred: isStarred } : item
  );
}

// Optimistic local recompute of a message's reaction aggregate for the acting user (one per user):
// decrement my previous emoji, increment the new one (or none, for removal), drop zero counts, and
// re-sort by count desc then emoji. Mirrors the server aggregate so there's no flicker on confirm.
function applyMyReaction(message: Message, emoji: string | null): Message {
  const previous = message.my_reaction ?? null;
  if (previous === emoji) return message;

  const counts = new Map<string, number>();
  for (const reaction of message.reactions ?? []) counts.set(reaction.emoji, reaction.count);
  if (previous) counts.set(previous, (counts.get(previous) ?? 1) - 1);
  if (emoji) counts.set(emoji, (counts.get(emoji) ?? 0) + 1);

  const reactions: ReactionCount[] = [...counts.entries()]
    .filter(([, count]) => count > 0)
    .map(([emojiKey, count]) => ({ emoji: emojiKey, count }))
    .sort((a, b) => b.count - a.count || (a.emoji < b.emoji ? -1 : 1));

  return { ...message, reactions, my_reaction: emoji };
}
