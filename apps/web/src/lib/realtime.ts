import { Channel, Presence, Socket } from "phoenix";
import type { Message } from "./api";
import { getAccessToken } from "./session";

const defaultRealtimeUrl = "ws://localhost:4000/socket";

export type ConversationChannel = {
  channel: Channel;
  sendMessage: (payload: {
    message_type: "text" | "media";
    body?: string;
    media_id?: string;
    caption?: string;
    metadata?: Record<string, unknown>;
  }) => Promise<unknown>;
  editMessage: (messageId: string, body: string) => Promise<unknown>;
  deleteMessage: (messageId: string) => Promise<unknown>;
  startTyping: () => Promise<unknown>;
  stopTyping: () => Promise<unknown>;
  onMessageCreated: (callback: (message: Message) => void) => () => void;
  onMessageUpdated: (callback: (message: Message) => void) => () => void;
  onMessageDeleted: (callback: (message: Message) => void) => () => void;
  onTypingStarted: (callback: (payload: TypingPayload) => void) => () => void;
  onTypingStopped: (callback: (payload: TypingPayload) => void) => () => void;
  /**
   * Subscribe to presence changes for THIS conversation. The callback receives the set of user_ids
   * currently present in the conversation channel (i.e. who has this conversation open). Fires once
   * immediately with the current state, then on every join/leave. Returns an unsubscribe fn.
   */
  onPresence: (callback: (onlineUserIds: string[]) => void) => () => void;
  leave: () => void;
};

export type TypingPayload = {
  conversation_id?: string;
  user_id?: string;
  occurred_at?: string;
};

function realtimeUrl() {
  return process.env.NEXT_PUBLIC_REALTIME_URL ?? defaultRealtimeUrl;
}

export function createSocket() {
  const token = getAccessToken();

  return new Socket(realtimeUrl(), {
    params: token ? { authorization: `Bearer ${token}` } : {}
  });
}

function push(channel: Channel, event: string, payload: object) {
  return new Promise((resolve, reject) => {
    channel
      .push(event, payload)
      .receive("ok", resolve)
      .receive("error", reject)
      .receive("timeout", () => reject(new Error(`${event} timed out`)));
  });
}

export function joinConversationChannel(
  socket: Socket,
  conversationId: string
): Promise<ConversationChannel> {
  if (socket.isConnected() === false) {
    socket.connect();
  }

  const channel = socket.channel(`conversation:${conversationId}`, {});
  // Construct Presence BEFORE join so it registers its "presence_state"/"presence_diff" handlers and
  // catches the initial presence_state the server pushes right after join. These are the default
  // events the backend (Phoenix.Presence) broadcasts, so no extra config is needed.
  const presence = new Presence(channel);
  const onlineUserIds = () => presence.list((id) => id);

  return new Promise((resolve, reject) => {
    channel
      .join()
      .receive("ok", () => {
        resolve({
          channel,
          sendMessage: (payload) => push(channel, "message:create", payload),
          editMessage: (messageId, body) =>
            push(channel, "message:update", { message_id: messageId, body }),
          deleteMessage: (messageId) =>
            push(channel, "message:delete", { message_id: messageId }),
          startTyping: () => push(channel, "typing:start", {}),
          stopTyping: () => push(channel, "typing:stop", {}),
          onMessageCreated: (callback) => subscribe(channel, "message_created", callback),
          onMessageUpdated: (callback) => subscribe(channel, "message_updated", callback),
          onMessageDeleted: (callback) => subscribe(channel, "message_deleted", callback),
          onTypingStarted: (callback) => subscribe(channel, "typing_started", callback),
          onTypingStopped: (callback) => subscribe(channel, "typing_stopped", callback),
          onPresence: (callback) => {
            // Phoenix Presence has a single onSync slot; we only need one consumer (the chat page).
            presence.onSync(() => callback(onlineUserIds()));
            callback(onlineUserIds()); // fire once with the current state
            return () => presence.onSync(() => {});
          },
          leave: () => channel.leave()
        });
      })
      .receive("error", reject)
      .receive("timeout", () =>
        reject(new Error(`conversation:${conversationId} join timed out`))
      );
  });
}

function subscribe<T>(
  channel: Channel,
  event: string,
  callback: (payload: T) => void
) {
  const ref = channel.on(event, (payload) => callback(payload as T));

  return () => channel.off(event, ref);
}
