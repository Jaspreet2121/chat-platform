import { Channel, Presence, Socket } from "phoenix";
import type { Message, ReactionCount } from "./api";
import { getAccessToken } from "./session";

const defaultRealtimeUrl = "ws://localhost:4000/socket";

export type ConversationChannel = {
  channel: Channel;
  sendMessage: (payload: {
    message_type: "text" | "media" | "location" | "live_location";
    body?: string;
    media_id?: string;
    caption?: string;
    metadata?: Record<string, unknown>;
    reply_to_message_id?: string;
  }) => Promise<unknown>;
  editMessage: (messageId: string, body: string) => Promise<unknown>;
  deleteMessage: (messageId: string) => Promise<unknown>;
  startTyping: () => Promise<unknown>;
  stopTyping: () => Promise<unknown>;
  /** Mark a message read (durable: the server persists the receipt, then broadcasts receipt_updated). */
  markRead: (messageId: string) => Promise<unknown>;
  markDelivered: (messageId: string) => Promise<unknown>;
  /** Set/change the caller's reaction on a message (server persists, then broadcasts reaction_updated). */
  reactToMessage: (messageId: string, emoji: string) => Promise<unknown>;
  /** Remove the caller's reaction from a message. */
  removeReaction: (messageId: string) => Promise<unknown>;
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
  /** Live receipt updates broadcast when another participant marks a message read/delivered. */
  onReceipt: (callback: (payload: ReceiptPayload) => void) => () => void;
  /** Live reaction aggregate updates broadcast when another participant reacts/unreacts. */
  onReactionUpdated: (callback: (payload: ReactionUpdatedPayload) => void) => () => void;
  /** Stream a throttled live-location position for one of the caller's own live_location messages. */
  sendLiveLocationUpdate: (payload: {
    message_id: string;
    lat: number;
    lng: number;
    accuracy?: number;
    at?: string;
    live?: boolean;
  }) => Promise<unknown>;
  /** A peer's live-location position update (moves their live bubble's marker). */
  onLiveLocationUpdate: (callback: (payload: LiveLocationUpdatePayload) => void) => () => void;
  leave: () => void;
};

export type LiveLocationUpdatePayload = {
  message_id?: string;
  lat?: number | string;
  lng?: number | string;
  accuracy?: number | string | null;
  at?: string;
  live?: boolean;
};

export type ReactionUpdatedPayload = {
  message_id: string;
  reactions: ReactionCount[];
};

export type TypingPayload = {
  conversation_id?: string;
  user_id?: string;
  occurred_at?: string;
};

export type ReceiptPayload = {
  receipt_type?: "read" | "delivered";
  user_id?: string;
  conversation_id?: string;
  payload?: { message_id?: string };
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

// ---- Phase-1 calling (Slice 4) --------------------------------------------------------------------
// The call ring control plane rides the SAME user:<id> topic (Slice 3). Outgoing pushes and incoming
// broadcasts are plain channel events; LiveKit carries the media (see lib/calls.ts).
export type CallType = "voice" | "video";
/** Broadcasts the server fans to MY user topic. */
export type CallServerEvent =
  | "call:incoming"
  | "call:accepted"
  | "call:rejected"
  | "call:cancelled"
  | "call:ended"
  | "call:missed";
/** Control events I push (the server validates ownership against the persisted call row). */
export type CallClientEvent =
  | "call:invite"
  | "call:accept"
  | "call:reject"
  | "call:cancel"
  | "call:hangup";
export type CallEventPayload = {
  call_id?: string;
  room?: string;
  caller_id?: string;
  caller_name?: string;
  type?: CallType;
  conversation_id?: string;
};
/** The `ok` reply to `call:invite` — the created call's id + the LiveKit room to join. */
export type CallInviteAck = { call_id: string; room: string };

// The caller's OWN `user:<id>` topic — the backend fans message_created for conversations the user
// does NOT have open onto it (in-app notifications: toasts + live unread badges). Identity-pinned
// server-side; joining someone else's topic is rejected. Also carries the call:* ring plane (Slice 3).
export type UserChannel = {
  onMessageCreated: (callback: (message: Message) => void) => () => void;
  /** Subscribe to a server-fanned call:* broadcast (returns an unsubscribe fn). */
  onCall: (event: CallServerEvent, callback: (payload: CallEventPayload) => void) => () => void;
  /** Push a call:* control event; `call:invite` resolves with the `{ call_id, room }` ack. */
  pushCall: (event: CallClientEvent, payload: Record<string, unknown>) => Promise<unknown>;
  leave: () => void;
};

export function joinUserChannel(socket: Socket, userId: string): Promise<UserChannel> {
  if (socket.isConnected() === false) {
    socket.connect();
  }

  const channel = socket.channel(`user:${userId}`, {});

  // App-level foreground presence: while the tab is VISIBLE, heartbeat "app:foreground" to the user
  // channel (the gateway refreshes a short-TTL Redis marker); on hidden/close, send "app:background".
  // The notification service reads this to SKIP web-push while the app is open anywhere (in-app covers
  // it). Server-side decision — the SW is untouched. Best-effort; the marker TTL self-heals.
  const HEARTBEAT_MS = 20_000;
  let heartbeat: ReturnType<typeof setInterval> | null = null;

  function sendForeground() {
    channel.push("app:foreground", {});
  }
  function startHeartbeat() {
    sendForeground();
    if (!heartbeat) heartbeat = setInterval(sendForeground, HEARTBEAT_MS);
  }
  function stopHeartbeat() {
    if (heartbeat) {
      clearInterval(heartbeat);
      heartbeat = null;
    }
  }
  function onVisibility() {
    if (typeof document === "undefined") return;
    if (document.visibilityState === "visible") {
      startHeartbeat();
    } else {
      stopHeartbeat();
      channel.push("app:background", {});
    }
  }
  function onPageHide() {
    stopHeartbeat();
    channel.push("app:background", {});
  }

  return new Promise((resolve, reject) => {
    channel
      .join()
      .receive("ok", () => {
        if (typeof document !== "undefined") {
          // Mark foreground now if visible, then follow visibility changes.
          if (document.visibilityState === "visible") startHeartbeat();
          document.addEventListener("visibilitychange", onVisibility);
          window.addEventListener("pagehide", onPageHide);
        }
        resolve({
          onMessageCreated: (callback) => subscribe(channel, "message_created", callback),
          onCall: (event, callback) => subscribe(channel, event, callback),
          pushCall: (event, payload) => push(channel, event, payload),
          leave: () => {
            stopHeartbeat();
            if (typeof document !== "undefined") {
              document.removeEventListener("visibilitychange", onVisibility);
              window.removeEventListener("pagehide", onPageHide);
            }
            channel.push("app:background", {});
            channel.leave();
          }
        });
      })
      .receive("error", (error) => reject(new Error(`user channel join failed: ${JSON.stringify(error)}`)))
      .receive("timeout", () => reject(new Error(`user:${userId} join timed out`)));
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
          markRead: (messageId) => push(channel, "message_read", { message_id: messageId }),
          markDelivered: (messageId) =>
            push(channel, "message_delivered", { message_id: messageId }),
          reactToMessage: (messageId, emoji) =>
            push(channel, "reaction:set", { message_id: messageId, emoji }),
          removeReaction: (messageId) =>
            push(channel, "reaction:remove", { message_id: messageId }),
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
          onReceipt: (callback) => subscribe(channel, "receipt_updated", callback),
          onReactionUpdated: (callback) =>
            subscribe(channel, "reaction_updated", callback),
          sendLiveLocationUpdate: (payload) => push(channel, "live_location:update", payload),
          onLiveLocationUpdate: (callback) =>
            subscribe(channel, "live_location_updated", callback),
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
