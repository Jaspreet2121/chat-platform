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
  getMediaDownloadUrl,
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

const allowedMediaTypes = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
  "audio/mpeg",
  "audio/mp4",
  "video/mp4"
]);

export default function ChatPage() {
  const router = useRouter();
  const socketRef = useRef<Socket | null>(null);
  const typingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  // One-shot guard: a redirect to /login fires at most once per mount, so no re-trigger can hammer
  // history.replaceState into the browser's "more than 100 times per 10 seconds" SecurityError.
  const hasRedirectedRef = useRef(false);

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
    };
  }, [selectedConversationId, session?.user_id]);

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

    setMediaStatus("Preparing upload...");
    const upload = await createMediaUpload({
      filename: file.name,
      content_type: file.type || "application/octet-stream",
      size_bytes: file.size
    });

    setMediaStatus("Uploading...");
    const uploadResponse = await fetch(upload.upload_url, {
      method: "PUT",
      body: file,
      headers: {
        "Content-Type": file.type || "application/octet-stream"
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
      content_type: file.type || "application/octet-stream",
      size_bytes: file.size
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

  return (
    <main className="min-h-screen bg-paper">
      <div className="mx-auto grid min-h-screen max-w-6xl grid-cols-1 border-x border-line bg-white md:grid-cols-[340px_1fr]">
        <aside className="border-b border-line bg-slate-50 md:border-b-0 md:border-r">
          <div className="border-b border-line p-4">
            <div className="flex items-start justify-between gap-3">
              <div>
                <p className="text-sm font-medium text-mint">Chat Platform</p>
                <h1 className="mt-1 text-xl font-semibold text-ink">Conversations</h1>
              </div>
              <button
                className="rounded-md border border-line bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:border-slate-400"
                onClick={handleLogout}
                type="button"
              >
                Logout
              </button>
            </div>
            {session ? (
              <div className="mt-2 flex items-center gap-2">
                <Avatar profile={currentProfile} size="sm" />
                <div className="min-w-0">
                  <p className="truncate text-xs font-medium text-ink">
                    {currentProfile?.display_name || "Signed in"}
                  </p>
                  <p className="truncate text-xs text-slate-500">{session.user_id}</p>
                </div>
              </div>
            ) : null}
          </div>

          <form className="border-b border-line p-3" onSubmit={handleCreateConversation}>
            <div className="space-y-3">
              <input
                className="w-full rounded-md border border-line px-3 py-2 text-sm outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
                placeholder="New conversation title"
                value={newTitle}
                onChange={(event) => setNewTitle(event.target.value)}
              />

              <div className="rounded-md border border-line bg-white p-2">
                <div className="flex gap-2">
                  <input
                    className="min-w-0 flex-1 rounded-md border border-line px-3 py-2 text-sm outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
                    placeholder="Participant user ID"
                    value={lookupUserId}
                    onChange={(event) => setLookupUserId(event.target.value)}
                  />
                  <button
                    className="rounded-md border border-line px-3 py-2 text-sm font-medium text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:text-slate-400"
                    disabled={isLookingUpProfile}
                    onClick={handleLookupProfile}
                    type="button"
                  >
                    {isLookingUpProfile ? "Looking..." : "Lookup"}
                  </button>
                </div>

                {lookupStatus ? (
                  <p className="mt-2 text-xs text-slate-600">{lookupStatus}</p>
                ) : null}

                {lookupProfile ? (
                  <div className="mt-2 flex items-center justify-between gap-2 rounded-md bg-slate-50 p-2">
                    <ProfileSummary profile={lookupProfile} />
                    <button
                      className="rounded-md bg-brand px-3 py-1.5 text-xs font-medium text-white"
                      onClick={handleAddParticipant}
                      type="button"
                    >
                      Add
                    </button>
                  </div>
                ) : null}
              </div>

              {selectedParticipants.length > 0 ? (
                <div className="space-y-2">
                  {selectedParticipants.map((participant) => (
                    <div
                      className="flex items-center justify-between gap-2 rounded-md border border-line bg-white p-2"
                      key={participant.user_id}
                    >
                      <ProfileSummary profile={participant} />
                      <button
                        className="rounded-md border border-line px-2 py-1 text-xs text-slate-600 hover:border-slate-400"
                        onClick={() => handleRemoveParticipant(participant.user_id)}
                        type="button"
                      >
                        Remove
                      </button>
                    </div>
                  ))}
                </div>
              ) : null}

              <button
                className="w-full rounded-md bg-ink px-3 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:bg-slate-400"
                disabled={isCreatingConversation || selectedParticipants.length === 0}
                type="submit"
              >
                {isCreatingConversation ? "Creating..." : "New conversation"}
              </button>
            </div>
          </form>

          <div className="p-3">
            {isLoading ? (
              <EmptyPanel label="Loading conversations..." />
            ) : conversations.length === 0 ? (
              <EmptyPanel label="No conversations yet. Create one to begin." />
            ) : (
              <div className="space-y-2">
                {conversations.map((conversation) => (
                  <button
                    className={`w-full rounded-md border px-3 py-3 text-left transition ${
                      selectedConversationId === conversation.conversation_id
                        ? "border-brand bg-blue-50"
                        : "border-line bg-white hover:border-slate-400"
                    }`}
                    key={conversation.conversation_id}
                    onClick={() => setSelectedConversationId(conversation.conversation_id)}
                    type="button"
                  >
                    <span className="block truncate text-sm font-medium text-ink">
                      {conversation.title || conversation.conversation_id}
                    </span>
                    <span className="mt-1 block truncate text-xs text-slate-500">
                      {conversation.last_message_preview || conversation.type}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>
        </aside>

        <section className="flex min-h-screen flex-col">
          <header className="border-b border-line px-5 py-4">
            <h2 className="truncate text-lg font-semibold text-ink">{selectedTitle}</h2>
            <p className="mt-1 text-sm text-slate-600">{status}</p>
            {typingUser ? (
              <p className="mt-1 text-xs font-medium text-mint">{typingUser} typing...</p>
            ) : null}
          </header>

          <div className="flex-1 space-y-3 overflow-y-auto px-5 py-5">
            {!selectedConversationId ? (
              <EmptyPanel label="Select or create a conversation." />
            ) : messages.length === 0 ? (
              <EmptyPanel label="No messages yet. Send the first one." />
            ) : (
              messages.map((message) => (
                <MessageBubble
                  isOwn={message.sender_user_id === session?.user_id}
                  key={message.message_id}
                  message={message}
                  onDelete={handleDeleteMessage}
                  onEdit={handleEditMessage}
                />
              ))
            )}
          </div>

          <form className="border-t border-line p-4" onSubmit={handleSend}>
            {selectedFile ? (
              <div className="mb-3 flex items-center justify-between gap-3 rounded-md border border-line bg-slate-50 px-3 py-2 text-sm">
                <span className="min-w-0 truncate text-slate-700">
                  {selectedFile.name} · {formatFileSize(selectedFile.size)}
                </span>
                <button
                  className="shrink-0 rounded-md border border-line px-2 py-1 text-xs text-slate-600 hover:border-slate-400"
                  disabled={isSending}
                  onClick={handleClearSelectedFile}
                  type="button"
                >
                  Remove
                </button>
              </div>
            ) : null}

            {mediaStatus ? (
              <p className="mb-3 text-xs font-medium text-mint">{mediaStatus}</p>
            ) : null}

            <div className="flex gap-3">
              <input
                className="hidden"
                disabled={!selectedConversationId || isSending}
                onChange={(event) => handleFileChange(event.target.files?.[0] ?? null)}
                ref={fileInputRef}
                type="file"
                accept={Array.from(allowedMediaTypes).join(",")}
              />
              <button
                className="rounded-md border border-line px-3 py-2 font-medium text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:text-slate-400"
                disabled={!selectedConversationId || isSending}
                onClick={() => fileInputRef.current?.click()}
                type="button"
              >
                Attach
              </button>
              <input
                className="min-w-0 flex-1 rounded-md border border-line px-3 py-2 outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
                disabled={!selectedConversationId}
                placeholder={
                  selectedFile
                    ? "Add a caption"
                    : selectedConversationId
                      ? "Type a message"
                      : "Select a conversation first"
                }
                value={draft}
                onChange={(event) => handleDraftChange(event.target.value)}
              />
              <button
                className="rounded-md bg-brand px-5 py-2 font-medium text-white disabled:cursor-not-allowed disabled:bg-slate-400"
                disabled={
                  !selectedConversationId ||
                  (!draft.trim() && !selectedFile) ||
                  isSending
                }
                type="submit"
              >
                {isSending ? "Sending..." : selectedFile ? "Send media" : "Send"}
              </button>
            </div>
          </form>
        </section>
      </div>
    </main>
  );
}

function EmptyPanel({ label }: { label: string }) {
  return (
    <div className="flex min-h-40 items-center justify-center rounded-md border border-dashed border-line p-4 text-center text-sm text-slate-600">
      {label}
    </div>
  );
}

function ProfileSummary({ profile }: { profile: UserProfile }) {
  return (
    <div className="flex min-w-0 items-center gap-2">
      <Avatar profile={profile} />
      <div className="min-w-0">
        <p className="truncate text-sm font-medium text-ink">
          {profile.display_name || "Unnamed profile"}
        </p>
        <p className="truncate text-xs text-slate-500">{profile.user_id}</p>
      </div>
    </div>
  );
}

function Avatar({
  profile,
  size = "md"
}: {
  profile: UserProfile | null;
  size?: "sm" | "md";
}) {
  const label = profile?.display_name || profile?.user_id || "?";
  const initials = label.slice(0, 2).toUpperCase();
  const sizeClass = size === "sm" ? "h-8 w-8 text-xs" : "h-9 w-9 text-sm";

  return (
    <div
      aria-label={label}
      className={`${sizeClass} flex shrink-0 items-center justify-center rounded-full bg-mint font-semibold text-white`}
      title={label}
    >
      {initials}
    </div>
  );
}

function MessageBubble({
  message,
  isOwn,
  onEdit,
  onDelete
}: {
  message: Message;
  isOwn: boolean;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
}) {
  const isMedia = Boolean(message.media_id);
  const isDeleted = message.status === "deleted";
  const isEdited = Boolean(message.edited_at);
  const canEdit = isOwn && !isDeleted && !isMedia;
  const canDelete = isOwn && !isDeleted;

  const [isEditing, setIsEditing] = useState(false);
  const [editDraft, setEditDraft] = useState(message.body ?? "");
  const [isBusy, setIsBusy] = useState(false);

  function startEdit() {
    setEditDraft(message.body ?? "");
    setIsEditing(true);
  }

  async function saveEdit() {
    const next = editDraft.trim();

    if (!next) {
      return;
    }

    setIsBusy(true);

    try {
      await onEdit(message.message_id, next);
      setIsEditing(false);
    } catch {
      // Failure status is surfaced by the parent; keep the edit box open.
    } finally {
      setIsBusy(false);
    }
  }

  async function removeMessage() {
    setIsBusy(true);

    try {
      await onDelete(message.message_id);
    } catch {
      // Failure status is surfaced by the parent.
    } finally {
      setIsBusy(false);
    }
  }

  return (
    <article
      className={`max-w-xl rounded-md border px-4 py-3 ${
        isOwn ? "ml-auto border-blue-200 bg-blue-50" : "border-line bg-slate-50"
      }`}
    >
      <p className="truncate text-xs text-slate-500">{message.sender_user_id}</p>

      {isDeleted ? (
        <p className="mt-1 text-sm italic text-slate-400">Message deleted</p>
      ) : isEditing ? (
        <div className="mt-1 space-y-2">
          <input
            className="w-full rounded-md border border-line px-3 py-2 text-sm outline-none focus:border-brand focus:ring-2 focus:ring-brand/20"
            disabled={isBusy}
            onChange={(event) => setEditDraft(event.target.value)}
            value={editDraft}
          />
          <div className="flex gap-2">
            <button
              className="rounded-md bg-brand px-3 py-1.5 text-xs font-medium text-white disabled:cursor-not-allowed disabled:bg-slate-400"
              disabled={isBusy || !editDraft.trim()}
              onClick={saveEdit}
              type="button"
            >
              {isBusy ? "Saving..." : "Save"}
            </button>
            <button
              className="rounded-md border border-line px-3 py-1.5 text-xs font-medium text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:text-slate-400"
              disabled={isBusy}
              onClick={() => setIsEditing(false)}
              type="button"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : isMedia ? (
        <MediaMessageContent message={message} />
      ) : (
        <p className="mt-1 text-ink">{message.body || message.message_type}</p>
      )}

      <div className="mt-2 flex items-center justify-between gap-3">
        <p className="text-xs text-slate-500">
          {message.status}
          {isEdited && !isDeleted ? " · edited" : ""}
        </p>
        {!isEditing && (canEdit || canDelete) ? (
          <div className="flex gap-2">
            {canEdit ? (
              <button
                className="text-xs font-medium text-slate-600 hover:text-ink disabled:cursor-not-allowed disabled:text-slate-400"
                disabled={isBusy}
                onClick={startEdit}
                type="button"
              >
                Edit
              </button>
            ) : null}
            {canDelete ? (
              <button
                className="text-xs font-medium text-red-600 hover:text-red-700 disabled:cursor-not-allowed disabled:text-slate-400"
                disabled={isBusy}
                onClick={removeMessage}
                type="button"
              >
                {isBusy ? "Working..." : "Delete"}
              </button>
            ) : null}
          </div>
        ) : null}
      </div>
    </article>
  );
}

function MediaMessageContent({ message }: { message: Message }) {
  const objectKey = metadataString(message.metadata, "object_key");
  const contentType = metadataString(message.metadata, "content_type");
  const mediaId = message.media_id;
  const isImage = Boolean(contentType && contentType.startsWith("image/"));
  const canResolve = Boolean(mediaId && objectKey);

  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewFailed, setPreviewFailed] = useState(false);

  // Resolve the download URL once when an image preview is possible, reusing the
  // same resolver the "Open media" link uses. The resolved URL is shared with the
  // link below so opening an image does not trigger a second request.
  useEffect(() => {
    if (!isImage || !mediaId || !objectKey) {
      return;
    }

    let isActive = true;

    getMediaDownloadUrl(mediaId, objectKey)
      .then((response) => {
        if (isActive) {
          setPreviewUrl(response.download_url);
        }
      })
      .catch(() => {
        if (isActive) {
          setPreviewFailed(true);
        }
      });

    return () => {
      isActive = false;
    };
  }, [isImage, mediaId, objectKey]);

  const showPreview = isImage && previewUrl && !previewFailed;

  return (
    <div className="mt-2 space-y-2">
      <div className="rounded-md border border-line bg-white p-3">
        <p className="text-sm font-medium text-ink">Media attachment</p>
        {message.body || message.caption ? (
          <p className="mt-1 text-sm text-slate-700">{message.body || message.caption}</p>
        ) : null}
        {showPreview ? (
          // Presigned media URLs are dynamic/remote; next/image would need
          // remotePatterns config, so a plain <img> is intentional here.
          // eslint-disable-next-line @next/next/no-img-element
          <img
            alt={message.caption || message.body || "Image attachment"}
            className="mt-2 max-h-64 w-full rounded-md object-cover"
            loading="lazy"
            onError={() => setPreviewFailed(true)}
            src={previewUrl as string}
          />
        ) : null}
        <p className="mt-2 break-all text-xs text-slate-500">{message.media_id}</p>
      </div>
      {canResolve ? (
        <OpenMediaLink
          mediaId={mediaId as string}
          objectKey={objectKey as string}
          prefetchedUrl={isImage ? previewUrl : null}
        />
      ) : null}
    </div>
  );
}

function OpenMediaLink({
  mediaId,
  objectKey,
  prefetchedUrl
}: {
  mediaId: string;
  objectKey: string;
  prefetchedUrl?: string | null;
}) {
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleOpenMedia() {
    if (prefetchedUrl) {
      setDownloadUrl(prefetchedUrl);
      window.open(prefetchedUrl, "_blank", "noopener,noreferrer");
      return;
    }

    setIsLoading(true);
    setError("");

    try {
      const response = await getMediaDownloadUrl(mediaId, objectKey);
      setDownloadUrl(response.download_url);
      window.open(response.download_url, "_blank", "noopener,noreferrer");
    } catch (openError) {
      setError(openError instanceof Error ? openError.message : "Could not open media.");
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <button
        className="rounded-md border border-line bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:border-slate-400 disabled:cursor-not-allowed disabled:text-slate-400"
        disabled={isLoading}
        onClick={handleOpenMedia}
        type="button"
      >
        {isLoading ? "Opening..." : "Open media"}
      </button>
      {downloadUrl ? (
        <a
          className="text-xs font-medium text-brand underline"
          href={downloadUrl}
          rel="noreferrer"
          target="_blank"
        >
          Link ready
        </a>
      ) : null}
      {error ? <span className="text-xs text-red-600">{error}</span> : null}
    </div>
  );
}

function metadataString(metadata: Message["metadata"], key: string) {
  if (!metadata || typeof metadata[key] !== "string") {
    return null;
  }

  return metadata[key];
}

function formatFileSize(size: number) {
  if (size < 1024) {
    return `${size} B`;
  }

  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }

  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
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
