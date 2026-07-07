"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MutableRefObject,
  type ReactNode
} from "react";
import type { CallEventPayload, CallGroupAck, CallInviteAck, CallType, UserChannel } from "@/lib/realtime";
import type { LocalVideoTrack, RemoteVideoTrack } from "livekit-client";
import {
  connectToRoom,
  connectToGroupRoom,
  unlockAudioContext,
  type CallConnection,
  type GroupConnection,
  type GroupParticipant
} from "@/lib/calls";
import { IncomingCallModal } from "./IncomingCallModal";
import { OutgoingCallScreen } from "./OutgoingCallScreen";
import { InCallScreen } from "./InCallScreen";
import { GroupInCallScreen } from "./GroupInCallScreen";
import { AddParticipantsSheet, type AddTarget } from "./AddParticipantsSheet";

// 1-on-1: idle → (I invite) outgoing → connecting → in-call ; idle → (they invite) incoming → …
// group:  idle → (I start) group-connecting → group-in-call ; idle → (they ring me) group-incoming → …
// The 1-on-1 flow is UNCHANGED — group adds parallel states.
type Status =
  | "idle"
  | "outgoing"
  | "incoming"
  | "connecting"
  | "in-call"
  | "group-incoming"
  | "group-connecting"
  | "group-in-call";

type ActiveCall = {
  callId: string;
  room: string;
  peerId: string;
  peerName: string;
  type: CallType;
};

type GroupCall = {
  callId: string;
  room: string;
  conversationId: string;
  type: CallType;
  /** Group name for the in-call header. */
  title: string;
  /** The ringing initiator (only set for an incoming ring). */
  callerName?: string;
  callerId?: string;
};

/** A group call currently in progress in a conversation — powers the "join call" banner (Slice C1). */
export type OngoingGroupCallEntry = { callId: string; room: string; type: CallType };

type CallContextValue = {
  /** Start a 1:1 call to `peerId` (no-op unless idle). `conversationId` (the DM) is carried on the invite
   *  so a missed call can drop an entry into that thread (Slice-5b). `type` chooses voice (default) or
   *  video (Phase 2 — publishes the camera on connect). */
  startCall: (peerId: string, peerName: string, conversationId?: string, type?: CallType) => void;
  /** Start a GROUP call in `conversationId` — rings every member (Phase 3). `title` = the group name. */
  startGroupCall: (conversationId: string, title: string, type?: CallType) => void;
  /** Late-join an EXISTING group call (from the thread banner). */
  joinGroupCall: (
    callId: string,
    room: string,
    conversationId: string,
    type: CallType,
    title: string
  ) => void;
  /** The group call in progress in `conversationId` (for the banner), or null — also null when WE are
   *  already in that very call. */
  ongoingGroupCall: (conversationId: string) => OngoingGroupCallEntry | null;
  /** Seed/clear the ongoing-call state from a fresh thread-open fetch (covers a call started before we
   *  opened the thread). Live events keep it fresh afterwards. */
  primeOngoingGroupCall: (conversationId: string, entry: OngoingGroupCallEntry | null) => void;
  /** Add someone to the ACTIVE group call — an existing member (userId) or an outside person (phone) —
   *  which rings them in. No-op unless we're currently in a group call. */
  addToGroupCall: (target: AddTarget) => void;
  /** True when a new call can be started (nothing in progress). */
  isIdle: boolean;
};

const CallContext = createContext<CallContextValue>({
  startCall: () => undefined,
  startGroupCall: () => undefined,
  joinGroupCall: () => undefined,
  ongoingGroupCall: () => null,
  primeOngoingGroupCall: () => undefined,
  addToGroupCall: () => undefined,
  isIdle: true
});

/** Access the call controls (e.g. the ChatHeader call button). */
export function useCall() {
  return useContext(CallContext);
}

// Slightly longer than the server's 35s ring timeout — a client-side backstop in case the missed
// broadcast is dropped (the server is the source of truth for the actual "missed" transition).
const RING_TIMEOUT_MS = 40_000;
const NOTE_MS = 4_000;

/** Imperative handle for callers that live ABOVE the provider (e.g. the page that owns the user channel). */
export type CallController = {
  startCall: (peerId: string, peerName: string, conversationId?: string, type?: CallType) => void;
  startGroupCall: (conversationId: string, title: string, type?: CallType) => void;
  addToGroupCall: (target: AddTarget) => void;
};

export type CallProviderProps = {
  /** The joined user:<id> channel (call:* ride on it). Null until it connects — calling is disabled then. */
  userChannel: UserChannel | null;
  /** The signed-in user's id — labels the self tile in a group call. */
  currentUserId?: string;
  /** Optional ref populated with the imperative call API (so a parent can trigger startCall via a ref). */
  controllerRef?: MutableRefObject<CallController | null>;
  children: ReactNode;
};

export function CallProvider({ userChannel, currentUserId, controllerRef, children }: CallProviderProps) {
  const [status, setStatus] = useState<Status>("idle");
  const [call, setCall] = useState<ActiveCall | null>(null);
  const [muted, setMuted] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  // Phase-2 video: the tracks InCallScreen attaches to its <video> elements, and the camera-on flag. Voice
  // calls never set these (they stay null/false), so the voice UI is byte-for-byte unchanged.
  const [localVideo, setLocalVideo] = useState<LocalVideoTrack | null>(null);
  const [remoteVideo, setRemoteVideo] = useState<RemoteVideoTrack | null>(null);
  const [cameraOn, setCameraOn] = useState(false);
  // True on a video call with >1 camera (front/back) — gates the "switch camera" button. Computed on connect.
  const [canSwitchCamera, setCanSwitchCamera] = useState(false);
  // Group calling (Phase 3) — parallel to the 1-on-1 state above.
  const [groupCall, setGroupCall] = useState<GroupCall | null>(null);
  const [groupParticipants, setGroupParticipants] = useState<GroupParticipant[]>([]);
  // The in-call "Add participants" sheet (Phase-3 C2) — open only while in a group call.
  const [addSheetOpen, setAddSheetOpen] = useState(false);
  // Conversations with a group call in progress (from live call:group_incoming / group_ended) → the banner.
  const [ongoingByConversation, setOngoingByConversation] = useState<Record<string, OngoingGroupCallEntry>>(
    {}
  );

  // Latest-value refs so the (once-per-channel) event handlers read current state without re-subscribing.
  const statusRef = useRef(status);
  const callRef = useRef(call);
  useEffect(() => {
    statusRef.current = status;
  }, [status]);
  useEffect(() => {
    callRef.current = call;
  }, [call]);

  const connectionRef = useRef<CallConnection | null>(null);
  // True from the moment connect() starts until the Room is stored (or fails) — guards against a duplicate
  // connect during the async connect window (connectionRef is still null then).
  const connectingRef = useRef(false);
  // Group calling: the LiveKit group connection + its idempotency guard + latest-value ref for handlers.
  const groupConnRef = useRef<GroupConnection | null>(null);
  const groupConnectingRef = useRef(false);
  const groupCallRef = useRef(groupCall);
  useEffect(() => {
    groupCallRef.current = groupCall;
  }, [groupCall]);
  // The ONE remote-audio sink for the whole app lifetime — rendered once below, never conditionally
  // unmounted, so the remote track stays attached across the connecting→in-call view swap.
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);
  const ringTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const noteTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // Suppresses the LiveKit "disconnected" callback while WE are tearing the call down (avoids a loop).
  const endingRef = useRef(false);

  const clearRingTimer = useCallback(() => {
    if (ringTimerRef.current) {
      clearTimeout(ringTimerRef.current);
      ringTimerRef.current = null;
    }
  }, []);

  const flashNote = useCallback((message: string) => {
    setNote(message);
    if (noteTimerRef.current) clearTimeout(noteTimerRef.current);
    noteTimerRef.current = setTimeout(() => setNote(null), NOTE_MS);
  }, []);

  // Tear everything down and return to idle. `from` tags WHO triggered the teardown (greppable as
  // "[call] reset" in the console — pairs with the livekit Disconnected reason in calls.ts to prove
  // whether a leave was app-initiated or livekit-client-initiated). `message` surfaces a transient note.
  const reset = useCallback(
    (from: string, message?: string) => {
      console.warn("[call] reset", { from, message });
      clearRingTimer();
      endingRef.current = true;
      const conn = connectionRef.current;
      connectionRef.current = null;
      if (conn) void conn.disconnect();
      setStatus("idle");
      setCall(null);
      setMuted(false);
      // Drop the video tracks (the room disconnect above stops them). The persistent <audio> sink is NOT
      // touched here — only the video state is cleared.
      setLocalVideo(null);
      setRemoteVideo(null);
      setCameraOn(false);
      setCanSwitchCamera(false);
      // C3b-2a wired onParticipants into the 1-on-1 connect → clear that set here so it can't leak into a
      // later call (the 1-on-1 view ignores it, but a stale set would mislead the C3b-2b group swap).
      setGroupParticipants([]);
      // Group-state hygiene (no-ops for an un-promoted 1-on-1): if a PROMOTED call's connection drops, its
      // onDisconnected still calls reset() (the closure was bound at connect) — clear the group state too so
      // nothing stale (groupCall / groupConnRef / sheet) survives into the next call.
      setGroupCall(null);
      groupConnRef.current = null;
      setAddSheetOpen(false);
      if (message) flashNote(message);
    },
    [clearRingTimer, flashNote]
  );

  // Join the LiveKit room (fetch token → connect → mic → attach remote audio). Called on the user gesture
  // (callee Accept) or on the caller receiving call:accepted — both are the moment media should start.
  const connect = useCallback(
    async (active: ActiveCall) => {
      // iOS-PWA: unlock/resume the WebAudio context in this (gesture-adjacent) sync prefix so remote audio
      // is audible. No-op off iOS-PWA. Harmless if the room is already connecting (idempotent below).
      unlockAudioContext();
      // Idempotency: never open a SECOND Room for the same call. A duplicate connect would join the room
      // twice with the same identity → LiveKit kicks the first with DUPLICATE_IDENTITY (a spurious drop).
      if (connectionRef.current || connectingRef.current) {
        console.warn("[call] connect ignored — already connecting/connected", active.callId);
        return;
      }
      connectingRef.current = true;
      clearRingTimer();
      endingRef.current = false;
      setStatus("connecting");
      const audioEl = remoteAudioRef.current;
      if (!audioEl) {
        connectingRef.current = false;
        reset("no-audio-sink", "Couldn't connect the call");
        return;
      }
      const isVideo = active.type === "video";
      setCameraOn(isVideo);
      try {
        const conn = await connectToRoom(active.room, audioEl, {
          video: isVideo,
          onLocalVideo: setLocalVideo,
          onRemoteVideo: setRemoteVideo,
          // C3b-2a: populate the group-participant set (data only). The 1-on-1 render below still uses
          // InCallScreen + single remoteVideo and IGNORES this — it's staged for the C3b-2b UI swap.
          onParticipants: setGroupParticipants,
          onDisconnected: (reason) => {
            // livekit-client left the room. If it wasn't OUR own disconnect() (endingRef), end the call and
            // surface WHY (media/ICE failure, duplicate identity, …) — the reason is logged in calls.ts too.
            if (!endingRef.current) reset(`livekit-disconnected:${reason ?? "unknown"}`);
          }
        });
        connectionRef.current = conn;
        connectingRef.current = false;
        setMuted(false);
        setStatus("in-call");
        // Video call → can we offer a front/back switch? (>1 videoinput). Best-effort, non-blocking.
        if (isVideo) {
          conn
            .getCameraDevices()
            .then((cams) => setCanSwitchCamera(cams.length > 1))
            .catch(() => setCanSwitchCamera(false));
        }
      } catch (error) {
        connectingRef.current = false;
        const denied =
          error instanceof DOMException &&
          (error.name === "NotAllowedError" || error.name === "NotFoundError");
        // Best effort: tell the peer we're gone, then reset with a reason.
        if (callRef.current) void userChannel?.pushCall("call:hangup", { call_id: callRef.current.callId });
        reset("connect-error", denied ? "Microphone access is needed for calls" : "Couldn't connect the call");
      }
    },
    [clearRingTimer, reset, userChannel]
  );

  // ---- outbound: start a call -------------------------------------------------------------------
  const startCall = useCallback(
    (peerId: string, peerName: string, conversationId?: string, type: CallType = "voice") => {
      if (!userChannel || statusRef.current !== "idle" || !peerId) return;
      unlockAudioContext(); // caller's gesture (the call button) — unlock iOS-PWA audio now. No-op elsewhere.
      setNote(null);
      const invite: Record<string, unknown> = { callee_id: peerId, type };
      // Carry the DM id so the server can post a "missed call" entry to this thread (Slice-5b). Omitted
      // (undefined) when unknown → the call still works; only the in-thread missed entry is skipped.
      if (conversationId) invite.conversation_id = conversationId;
      userChannel
        .pushCall("call:invite", invite)
        .then((ack) => {
          const { call_id, room } = ack as CallInviteAck;
          if (!call_id || !room) throw new Error("bad invite ack");
          // A late accept/reject may have arrived; only arm if we're still meant to be ringing.
          if (statusRef.current !== "idle") return;
          const active: ActiveCall = { callId: call_id, room, peerId, peerName, type };
          setCall(active);
          setStatus("outgoing");
          clearRingTimer();
          ringTimerRef.current = setTimeout(() => reset("ring-timeout", "No answer"), RING_TIMEOUT_MS);
        })
        .catch(() => flashNote("Couldn't start the call"));
    },
    [userChannel, clearRingTimer, reset, flashNote]
  );

  // ---- user actions on the active call ----------------------------------------------------------
  const acceptIncoming = useCallback(() => {
    const active = callRef.current;
    if (!active || !userChannel) return;
    unlockAudioContext(); // Accept IS the gesture — unlock iOS-PWA audio synchronously. No-op elsewhere.
    void userChannel.pushCall("call:accept", { call_id: active.callId });
    void connect(active); // Accept IS the gesture that unlocks mic/audio.
  }, [userChannel, connect]);

  const rejectIncoming = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:reject", { call_id: active.callId });
    reset("user-reject");
  }, [userChannel, reset]);

  const cancelOutgoing = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:cancel", { call_id: active.callId });
    reset("user-cancel");
  }, [userChannel, reset]);

  const hangup = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:hangup", { call_id: active.callId });
    reset("user-hangup");
  }, [userChannel, reset]);

  // Media controls target whichever call is active (1-on-1 connectionRef or group groupConnRef — only one
  // is ever set). GroupConnection and CallConnection share these method signatures.
  const toggleMute = useCallback(() => {
    const next = !muted;
    setMuted(next);
    void (connectionRef.current ?? groupConnRef.current)?.setMuted(next);
  }, [muted]);

  const toggleCamera = useCallback(() => {
    const next = !cameraOn;
    setCameraOn(next);
    // The onLocalVideo callback (passed to connect) updates the localVideo track state.
    void (connectionRef.current ?? groupConnRef.current)?.setCameraEnabled(next);
  }, [cameraOn]);

  // Cycle to the next camera (front↔back on mobile). The onLocalVideo callback refreshes the self-view.
  const switchCamera = useCallback(() => {
    void (connectionRef.current ?? groupConnRef.current)?.switchCamera();
  }, []);

  // ---- group calling (Phase 3) ------------------------------------------------------------------
  const resetGroup = useCallback(
    (from: string, message?: string) => {
      console.warn("[call] group reset", { from, message });
      clearRingTimer();
      endingRef.current = true;
      const conv = groupCallRef.current?.conversationId;
      // A PROMOTED call's live connection lives in connectionRef (NOT groupConnRef). Disconnect whichever is
      // set, and null BOTH refs — otherwise a promoted call's connection would never disconnect (the bug).
      const conn = groupConnRef.current ?? connectionRef.current;
      groupConnRef.current = null;
      connectionRef.current = null;
      if (conn) void conn.disconnect();
      setStatus("idle");
      setGroupCall(null);
      setGroupParticipants([]);
      setAddSheetOpen(false);
      setMuted(false);
      setLocalVideo(null);
      setCameraOn(false);
      setCanSwitchCamera(false);
      // Drop our own banner entry for the call we just left (a still-ongoing call re-appears on next
      // thread-open via the fetch; group_ended also clears it for everyone by callId).
      if (conv) {
        setOngoingByConversation((m) => {
          if (!(conv in m)) return m;
          const next = { ...m };
          delete next[conv];
          return next;
        });
      }
      if (message) flashNote(message);
    },
    [clearRingTimer, flashNote]
  );

  const connectGroup = useCallback(
    async (active: GroupCall) => {
      // iOS-PWA: unlock/resume WebAudio in this gesture-adjacent sync prefix (no-op off iOS-PWA).
      unlockAudioContext();
      // Same DUPLICATE_IDENTITY idempotency guard as the 1-on-1 connect.
      if (groupConnRef.current || groupConnectingRef.current) {
        console.warn("[call] group connect ignored — already connecting/connected", active.callId);
        return;
      }
      groupConnectingRef.current = true;
      // Publish the active group call so the in-call screen renders (the INITIATOR path never set it) and
      // groupCallRef updates → call:group_ended matching + leaveGroup work for the initiator too. No-op for
      // the member path (their call:group_incoming already stored the same object).
      setGroupCall(active);
      clearRingTimer();
      endingRef.current = false;
      setStatus("group-connecting");
      const isVideo = active.type === "video";
      setCameraOn(isVideo);
      try {
        const conn = await connectToGroupRoom(active.room, {
          video: isVideo,
          onLocalVideo: setLocalVideo,
          onParticipants: setGroupParticipants,
          onDisconnected: (reason) => {
            if (!endingRef.current) resetGroup(`livekit-disconnected:${reason ?? "unknown"}`);
          }
        });
        groupConnRef.current = conn;
        groupConnectingRef.current = false;
        setMuted(false);
        setStatus("group-in-call");
        if (isVideo) {
          conn
            .getCameraDevices()
            .then((cams) => setCanSwitchCamera(cams.length > 1))
            .catch(() => setCanSwitchCamera(false));
        }
      } catch (error) {
        groupConnectingRef.current = false;
        const denied =
          error instanceof DOMException &&
          (error.name === "NotAllowedError" || error.name === "NotFoundError");
        void userChannel?.pushCall("call:group_leave", { call_id: active.callId });
        resetGroup("connect-error", denied ? "Microphone access is needed for calls" : "Couldn't connect the call");
      }
    },
    [clearRingTimer, resetGroup, userChannel]
  );

  const startGroupCall = useCallback(
    (conversationId: string, title: string, type: CallType = "voice") => {
      if (!userChannel || statusRef.current !== "idle" || !conversationId) return;
      unlockAudioContext(); // caller's gesture (start group call) — unlock iOS-PWA audio. No-op elsewhere.
      setNote(null);
      userChannel
        .pushCall("call:group_invite", { conversation_id: conversationId, type })
        .then((ack) => {
          const { call_id, room } = ack as CallGroupAck;
          if (!call_id || !room) throw new Error("bad group invite ack");
          if (statusRef.current !== "idle") return;
          // The initiator joins immediately (they're already "joined" server-side); no outgoing ring.
          void connectGroup({ callId: call_id, room, conversationId, type, title });
        })
        .catch((err) => {
          console.warn("[call] group invite failed", err);
          flashNote("Couldn't start the group call");
        });
    },
    [userChannel, connectGroup, flashNote]
  );

  const acceptGroupIncoming = useCallback(() => {
    const active = groupCallRef.current;
    if (!active || !userChannel) return;
    unlockAudioContext(); // Accept IS the gesture — unlock iOS-PWA audio synchronously. No-op elsewhere.
    void userChannel.pushCall("call:group_join", { call_id: active.callId });
    void connectGroup(active); // Accept IS the gesture that unlocks mic/audio.
  }, [userChannel, connectGroup]);

  const declineGroupIncoming = useCallback(() => {
    const active = groupCallRef.current;
    if (active) void userChannel?.pushCall("call:group_decline", { call_id: active.callId });
    resetGroup("user-decline");
  }, [userChannel, resetGroup]);

  const leaveGroup = useCallback(() => {
    const active = groupCallRef.current;
    if (active) void userChannel?.pushCall("call:group_leave", { call_id: active.callId });
    resetGroup("user-leave");
  }, [userChannel, resetGroup]);

  // Late-join an EXISTING group call from the thread banner (we were never "incoming" on it). Mirrors
  // acceptGroupIncoming but takes the call coords from the banner instead of the ring payload.
  const joinGroupCall = useCallback(
    (callId: string, room: string, conversationId: string, type: CallType, title: string) => {
      if (!userChannel || statusRef.current !== "idle") return;
      unlockAudioContext(); // banner "Join" tap is the gesture — unlock iOS-PWA audio. No-op elsewhere.
      setNote(null);
      void userChannel.pushCall("call:group_join", { call_id: callId });
      void connectGroup({ callId, room, conversationId, type, title });
    },
    [userChannel, connectGroup]
  );

  // Add someone to the ACTIVE group call (C2). `userId` for an existing member, `phone` for an outside
  // person (the server resolves + rings). `label` only feeds the toast. No-op unless we're in a group call.
  const addToGroupCall = useCallback(
    (target: AddTarget) => {
      const active = groupCallRef.current;
      if (!userChannel || !active) return;
      const { userId, phone, label } = target;
      if (!userId && !phone) return;
      const payload: Record<string, unknown> = { call_id: active.callId };
      if (userId) payload.user_id = userId;
      else payload.phone = phone;
      userChannel
        .pushCall("call:group_add", payload)
        .then(() => flashNote(`Ringing ${label ?? "them"}…`))
        .catch((err) => {
          const code =
            err && typeof err === "object" && "code" in err
              ? (err as { code?: string }).code
              : undefined;
          if (code === "call.user_not_found") flashNote("No user with that number");
          else if (code === "call.add_forbidden") flashNote("You're not allowed to add people");
          else flashNote("Couldn't add them");
        });
    },
    [userChannel, flashNote]
  );

  // ---- promote a 1-on-1 → group (Phase 3 C3b) ---------------------------------------------------
  // UI-STATE reconcile ONLY: the live LiveKit connection stays in connectionRef (no reconnect). We flip the
  // 1-on-1 state (ActiveCall/in-call) to group state (GroupCall/group-in-call) so InCallScreen stops
  // rendering and GroupInCallScreen takes over on the SAME connection. Media controls already read
  // connectionRef first, so mute/camera/switch keep working uninterrupted.
  const promoteToGroup = useCallback(
    (info: {
      callId: string;
      room: string;
      conversationId: string;
      type: CallType;
      title: string;
      note?: string;
    }) => {
      // Only from a live 1-on-1 with an active connection (the connection lives in connectionRef).
      if (statusRef.current !== "in-call" && statusRef.current !== "connecting") return;
      if (!connectionRef.current) return;
      setGroupCall({
        callId: info.callId,
        room: info.room,
        conversationId: info.conversationId,
        type: info.type,
        title: info.title
      });
      setCall(null); // InCallScreen needs `call` → stops matching; GroupInCallScreen (needs groupCall) shows.
      setStatus("group-in-call");
      setAddSheetOpen(false);
      if (info.note) flashNote(info.note);
    },
    [flashNote]
  );

  // The actor taps "Add" on a 1-on-1 → promote. Push call:promote; on ok, swap OUR UI to the grid. The other
  // peer swaps via the call:promoted broadcast; the new person rings via call:group_incoming.
  const promoteCall = useCallback(
    (target: AddTarget) => {
      const active = callRef.current;
      if (!userChannel || !active) return;
      const { userId, phone } = target;
      if (!userId && !phone) return;
      const payload: Record<string, unknown> = { call_id: active.callId };
      if (userId) payload.user_id = userId;
      else payload.phone = phone;
      userChannel
        .pushCall("call:promote", payload)
        .then((ack) => {
          const a = ack as { call_id?: string; room?: string; conversation_id?: string; type?: CallType };
          if (!a.call_id || !a.room || !a.conversation_id) throw new Error("bad promote ack");
          promoteToGroup({
            callId: a.call_id,
            room: a.room,
            conversationId: a.conversation_id,
            type: a.type ?? active.type,
            title: "Group call"
          });
        })
        .catch((err) => {
          const code =
            err && typeof err === "object" && "code" in err
              ? (err as { code?: string }).code
              : undefined;
          if (code === "call.user_not_found") flashNote("No user with that number");
          else if (code === "call.forbidden") flashNote("You're not allowed to add people");
          else flashNote("Couldn't add them");
        });
    },
    [userChannel, promoteToGroup, flashNote]
  );

  // ---- inbound: subscribe to the server's call:* broadcasts (once per channel) ------------------
  useEffect(() => {
    if (!userChannel) return;
    const matches = (p: CallEventPayload) => callRef.current?.callId && p.call_id === callRef.current.callId;

    const unsubs = [
      userChannel.onCall("call:incoming", (p) => {
        // Busy → auto-decline so the caller isn't left ringing.
        if (statusRef.current !== "idle") {
          if (p.call_id) void userChannel.pushCall("call:reject", { call_id: p.call_id });
          return;
        }
        if (!p.call_id || !p.room) return;
        setCall({
          callId: p.call_id,
          room: p.room,
          peerId: p.caller_id ?? "",
          peerName: p.caller_name?.trim() || "Unknown caller",
          type: p.type ?? "voice"
        });
        setStatus("incoming");
        clearRingTimer();
        ringTimerRef.current = setTimeout(() => reset("ring-timeout", "Missed call"), RING_TIMEOUT_MS);
      }),
      // The callee accepted → I'm the caller, join the room now.
      userChannel.onCall("call:accepted", (p) => {
        if (statusRef.current === "outgoing" && matches(p) && callRef.current) connect(callRef.current);
      }),
      userChannel.onCall("call:rejected", (p) => matches(p) && reset("peer-rejected", "Call declined")),
      userChannel.onCall("call:cancelled", (p) => matches(p) && reset("peer-cancelled")),
      userChannel.onCall("call:ended", (p) => matches(p) && reset("peer-ended")),
      userChannel.onCall("call:missed", (p) => matches(p) && reset("peer-missed", "Missed call")),
      // The OTHER peer promoted our 1-on-1 → swap to the group grid on the SAME connection (no reconnect).
      userChannel.onCall("call:promoted", (p) => {
        if (!matches(p) || !p.room || !p.conversation_id) return;
        if (statusRef.current !== "in-call" && statusRef.current !== "connecting") return;
        promoteToGroup({
          callId: p.call_id as string,
          room: p.room,
          conversationId: p.conversation_id,
          type: p.type ?? callRef.current?.type ?? "voice",
          title: "Group call",
          note: "Someone joined the call"
        });
      }),

      // ---- group (Phase 3) ----
      userChannel.onCall("call:group_incoming", (p) => {
        // Record the in-progress call for the thread banner — even if we're busy/decline the ring, the
        // group still has a call we could join later.
        if (p.call_id && p.room && p.conversation_id) {
          const cid = p.conversation_id;
          const entry: OngoingGroupCallEntry = { callId: p.call_id, room: p.room, type: p.type ?? "voice" };
          setOngoingByConversation((m) => ({ ...m, [cid]: entry }));
        }
        // Busy (in ANY call) → auto-decline so the initiator's roster is accurate.
        if (statusRef.current !== "idle") {
          if (p.call_id) void userChannel.pushCall("call:group_decline", { call_id: p.call_id });
          return;
        }
        if (!p.call_id || !p.room || !p.conversation_id) return;
        setGroupCall({
          callId: p.call_id,
          room: p.room,
          conversationId: p.conversation_id,
          type: p.type ?? "voice",
          // The broadcast carries no group name; the tiles resolve each member's name themselves.
          title: "Group call",
          callerName: p.caller_name?.trim() || "Someone",
          callerId: p.caller_id
        });
        setStatus("group-incoming");
        clearRingTimer();
        ringTimerRef.current = setTimeout(() => resetGroup("ring-timeout", "Missed group call"), RING_TIMEOUT_MS);
      }),
      userChannel.onCall("call:group_ended", (p) => {
        // Clear the banner for whichever conversation this call belonged to (payload has only call_id).
        if (p.call_id) {
          setOngoingByConversation((m) => {
            const cid = Object.keys(m).find((k) => m[k].callId === p.call_id);
            if (!cid) return m;
            const next = { ...m };
            delete next[cid];
            return next;
          });
        }
        if (groupCallRef.current?.callId && p.call_id === groupCallRef.current.callId) {
          resetGroup("group-ended");
        }
      }),
      // participant_joined/declined/left: the grid is media-driven (LiveKit ParticipantConnected/…), so
      // these are no-ops today — subscribed for a future roster overlay.
      userChannel.onCall("call:participant_joined", () => undefined),
      userChannel.onCall("call:participant_declined", () => undefined),
      userChannel.onCall("call:participant_left", () => undefined)
    ];

    return () => unsubs.forEach((u) => u());
  }, [userChannel, clearRingTimer, reset, connect, resetGroup, connectGroup, promoteToGroup]);

  // Expose the imperative API to a parent above this provider (the chat page owns the user channel).
  useEffect(() => {
    if (!controllerRef) return;
    controllerRef.current = { startCall, startGroupCall, addToGroupCall };
    return () => {
      controllerRef.current = null;
    };
  }, [controllerRef, startCall, startGroupCall, addToGroupCall]);

  // Cleanup on unmount: leave any room + clear timers. This fires ONLY if the provider itself unmounts
  // (leaving /chat) — it is NOT tied to a call's connecting→in-call transition. If a mid-call leave ever
  // logs this, the provider is unmounting unexpectedly (that would be the bug); it hasn't in practice.
  useEffect(() => {
    return () => {
      if (connectionRef.current || groupConnRef.current) {
        console.warn("[call] provider unmounting — disconnecting active call");
      }
      endingRef.current = true;
      if (connectionRef.current) void connectionRef.current.disconnect();
      if (groupConnRef.current) void groupConnRef.current.disconnect();
      if (ringTimerRef.current) clearTimeout(ringTimerRef.current);
      if (noteTimerRef.current) clearTimeout(noteTimerRef.current);
    };
  }, []);

  const primeOngoingGroupCall = useCallback(
    (cid: string, entry: OngoingGroupCallEntry | null) => {
      setOngoingByConversation((m) => {
        if (!entry) {
          if (!(cid in m)) return m;
          const next = { ...m };
          delete next[cid];
          return next;
        }
        return { ...m, [cid]: entry };
      });
    },
    []
  );

  // The conversation whose group call WE are currently in (so its banner hides — we're already joined).
  const activeGroupConversationId =
    status === "group-connecting" || status === "group-in-call" ? groupCall?.conversationId : undefined;

  // LiveKit identities already in the call (remotes + me) — the Add sheet excludes these from its member list.
  const inCallIds = useMemo(
    () => [...groupParticipants.map((p) => p.identity), ...(currentUserId ? [currentUserId] : [])],
    [groupParticipants, currentUserId]
  );

  const value = useMemo<CallContextValue>(
    () => ({
      startCall,
      startGroupCall,
      joinGroupCall,
      ongoingGroupCall: (cid: string) =>
        cid && cid !== activeGroupConversationId ? ongoingByConversation[cid] ?? null : null,
      primeOngoingGroupCall,
      addToGroupCall,
      isIdle: status === "idle"
    }),
    [
      startCall,
      startGroupCall,
      joinGroupCall,
      ongoingByConversation,
      activeGroupConversationId,
      primeOngoingGroupCall,
      addToGroupCall,
      status
    ]
  );

  return (
    <CallContext.Provider value={value}>
      {children}

      {/* The single persistent remote-audio sink — mounted for the provider's whole lifetime (NOT inside
          any call-status view), so the attached remote track survives the connecting→in-call swap. */}
      <audio ref={remoteAudioRef} autoPlay hidden />

      {status === "incoming" && call && (
        <IncomingCallModal
          callerName={call.peerName}
          callerId={call.peerId}
          video={call.type === "video"}
          onAccept={acceptIncoming}
          onReject={rejectIncoming}
        />
      )}
      {status === "outgoing" && call && (
        <OutgoingCallScreen calleeName={call.peerName} calleeId={call.peerId} onCancel={cancelOutgoing} />
      )}
      {(status === "connecting" || status === "in-call") && call && (
        <InCallScreen
          peerName={call.peerName}
          peerId={call.peerId}
          connecting={status === "connecting"}
          muted={muted}
          onToggleMute={toggleMute}
          onHangup={hangup}
          video={call.type === "video"}
          localVideoTrack={localVideo}
          remoteVideoTrack={remoteVideo}
          cameraOn={cameraOn}
          onToggleCamera={toggleCamera}
          canSwitchCamera={canSwitchCamera}
          onSwitchCamera={switchCamera}
          onAddParticipants={() => setAddSheetOpen(true)}
        />
      )}

      {/* 1-on-1 "Add" → promote sheet. No conversationId (a DM's other party is already in the call), so the
          sheet opens on the "by number" tab; onAdd promotes the call. Only while actually in-call. */}
      {status === "in-call" && addSheetOpen && call && (
        <AddParticipantsSheet
          inCallIds={[currentUserId, call.peerId].filter(Boolean) as string[]}
          currentUserId={currentUserId}
          onAdd={promoteCall}
          onClose={() => setAddSheetOpen(false)}
        />
      )}

      {/* Group (Phase 3) — a member's incoming ring reuses the 1-on-1 modal (group label). */}
      {status === "group-incoming" && groupCall && (
        <IncomingCallModal
          callerName={groupCall.callerName ?? "Someone"}
          callerId={groupCall.callerId ?? groupCall.conversationId}
          video={groupCall.type === "video"}
          group
          onAccept={acceptGroupIncoming}
          onReject={declineGroupIncoming}
        />
      )}
      {(status === "group-connecting" || status === "group-in-call") && groupCall && (
        <GroupInCallScreen
          title={groupCall.title}
          connecting={status === "group-connecting"}
          video={groupCall.type === "video"}
          muted={muted}
          onToggleMute={toggleMute}
          onHangup={leaveGroup}
          cameraOn={cameraOn}
          onToggleCamera={toggleCamera}
          canSwitchCamera={canSwitchCamera}
          onSwitchCamera={switchCamera}
          onAddParticipants={() => setAddSheetOpen(true)}
          participants={groupParticipants}
          currentUserId={currentUserId}
          localVideoTrack={localVideo}
        />
      )}

      {status === "group-in-call" && addSheetOpen && groupCall && (
        <AddParticipantsSheet
          conversationId={groupCall.conversationId}
          inCallIds={inCallIds}
          currentUserId={currentUserId}
          onAdd={addToGroupCall}
          onClose={() => setAddSheetOpen(false)}
        />
      )}

      {/* Transient toast. z-[80] so add-participant feedback shows ABOVE the fullscreen call screen
          (z-[60]) and the Add sheet (z-[70]); at idle it's the usual call-outcome note. */}
      {note && (
        <div
          role="status"
          className="fixed bottom-6 left-1/2 z-[80] -translate-x-1/2 rounded-full bg-fg/90 px-4 py-2 text-sm font-medium text-bg shadow-lg animate-fade-in"
        >
          {note}
        </div>
      )}
    </CallContext.Provider>
  );
}
