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
import type { CallEventPayload, CallInviteAck, UserChannel } from "@/lib/realtime";
import { connectToRoom, type CallConnection } from "@/lib/calls";
import { IncomingCallModal } from "./IncomingCallModal";
import { OutgoingCallScreen } from "./OutgoingCallScreen";
import { InCallScreen } from "./InCallScreen";

// idle → (I invite) outgoing → connecting → in-call    (peer accepted)
// idle → (they invite) incoming → connecting → in-call (I accepted)
// any → idle on reject / cancel / hangup / ended / missed / error
type Status = "idle" | "outgoing" | "incoming" | "connecting" | "in-call";

type ActiveCall = {
  callId: string;
  room: string;
  peerId: string;
  peerName: string;
};

type CallContextValue = {
  /** Start a 1:1 voice call to `peerId` (no-op unless idle). */
  startCall: (peerId: string, peerName: string) => void;
  /** True when a new call can be started (nothing in progress). */
  isIdle: boolean;
};

const CallContext = createContext<CallContextValue>({ startCall: () => undefined, isIdle: true });

/** Access the call controls (e.g. the ChatHeader call button). */
export function useCall() {
  return useContext(CallContext);
}

// Slightly longer than the server's 35s ring timeout — a client-side backstop in case the missed
// broadcast is dropped (the server is the source of truth for the actual "missed" transition).
const RING_TIMEOUT_MS = 40_000;
const NOTE_MS = 4_000;

/** Imperative handle for callers that live ABOVE the provider (e.g. the page that owns the user channel). */
export type CallController = { startCall: (peerId: string, peerName: string) => void };

export type CallProviderProps = {
  /** The joined user:<id> channel (call:* ride on it). Null until it connects — calling is disabled then. */
  userChannel: UserChannel | null;
  /** Optional ref populated with the imperative call API (so a parent can trigger startCall via a ref). */
  controllerRef?: MutableRefObject<CallController | null>;
  children: ReactNode;
};

export function CallProvider({ userChannel, controllerRef, children }: CallProviderProps) {
  const [status, setStatus] = useState<Status>("idle");
  const [call, setCall] = useState<ActiveCall | null>(null);
  const [muted, setMuted] = useState(false);
  const [note, setNote] = useState<string | null>(null);

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

  // Tear everything down and return to idle. `note` surfaces a transient reason (declined / missed / error).
  const reset = useCallback(
    (message?: string) => {
      clearRingTimer();
      endingRef.current = true;
      const conn = connectionRef.current;
      connectionRef.current = null;
      if (conn) void conn.disconnect();
      setStatus("idle");
      setCall(null);
      setMuted(false);
      if (message) flashNote(message);
    },
    [clearRingTimer, flashNote]
  );

  // Join the LiveKit room (fetch token → connect → mic → attach remote audio). Called on the user gesture
  // (callee Accept) or on the caller receiving call:accepted — both are the moment media should start.
  const connect = useCallback(
    async (active: ActiveCall) => {
      clearRingTimer();
      endingRef.current = false;
      setStatus("connecting");
      const audioEl = remoteAudioRef.current;
      if (!audioEl) {
        reset("Couldn't connect the call");
        return;
      }
      try {
        connectionRef.current = await connectToRoom(active.room, audioEl, {
          onDisconnected: () => {
            // Peer dropped / network loss (not our own teardown) → end the call.
            if (!endingRef.current) reset();
          }
        });
        setMuted(false);
        setStatus("in-call");
      } catch (error) {
        const denied =
          error instanceof DOMException &&
          (error.name === "NotAllowedError" || error.name === "NotFoundError");
        // Best effort: tell the peer we're gone, then reset with a reason.
        if (callRef.current) void userChannel?.pushCall("call:hangup", { call_id: callRef.current.callId });
        reset(denied ? "Microphone access is needed for calls" : "Couldn't connect the call");
      }
    },
    [clearRingTimer, reset, userChannel]
  );

  // ---- outbound: start a call -------------------------------------------------------------------
  const startCall = useCallback(
    (peerId: string, peerName: string) => {
      if (!userChannel || statusRef.current !== "idle" || !peerId) return;
      setNote(null);
      userChannel
        .pushCall("call:invite", { callee_id: peerId, type: "voice" })
        .then((ack) => {
          const { call_id, room } = ack as CallInviteAck;
          if (!call_id || !room) throw new Error("bad invite ack");
          // A late accept/reject may have arrived; only arm if we're still meant to be ringing.
          if (statusRef.current !== "idle") return;
          const active = { callId: call_id, room, peerId, peerName };
          setCall(active);
          setStatus("outgoing");
          clearRingTimer();
          ringTimerRef.current = setTimeout(() => reset("No answer"), RING_TIMEOUT_MS);
        })
        .catch(() => flashNote("Couldn't start the call"));
    },
    [userChannel, clearRingTimer, reset, flashNote]
  );

  // ---- user actions on the active call ----------------------------------------------------------
  const acceptIncoming = useCallback(() => {
    const active = callRef.current;
    if (!active || !userChannel) return;
    void userChannel.pushCall("call:accept", { call_id: active.callId });
    void connect(active); // Accept IS the gesture that unlocks mic/audio.
  }, [userChannel, connect]);

  const rejectIncoming = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:reject", { call_id: active.callId });
    reset();
  }, [userChannel, reset]);

  const cancelOutgoing = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:cancel", { call_id: active.callId });
    reset();
  }, [userChannel, reset]);

  const hangup = useCallback(() => {
    const active = callRef.current;
    if (active) void userChannel?.pushCall("call:hangup", { call_id: active.callId });
    reset();
  }, [userChannel, reset]);

  const toggleMute = useCallback(() => {
    const next = !muted;
    setMuted(next);
    void connectionRef.current?.setMuted(next);
  }, [muted]);

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
          peerName: p.caller_name?.trim() || "Unknown caller"
        });
        setStatus("incoming");
        clearRingTimer();
        ringTimerRef.current = setTimeout(() => reset("Missed call"), RING_TIMEOUT_MS);
      }),
      // The callee accepted → I'm the caller, join the room now.
      userChannel.onCall("call:accepted", (p) => {
        if (statusRef.current === "outgoing" && matches(p) && callRef.current) connect(callRef.current);
      }),
      userChannel.onCall("call:rejected", (p) => matches(p) && reset("Call declined")),
      userChannel.onCall("call:cancelled", (p) => matches(p) && reset()),
      userChannel.onCall("call:ended", (p) => matches(p) && reset()),
      userChannel.onCall("call:missed", (p) => matches(p) && reset("Missed call"))
    ];

    return () => unsubs.forEach((u) => u());
  }, [userChannel, clearRingTimer, reset, connect]);

  // Expose the imperative API to a parent above this provider (the chat page owns the user channel).
  useEffect(() => {
    if (!controllerRef) return;
    controllerRef.current = { startCall };
    return () => {
      controllerRef.current = null;
    };
  }, [controllerRef, startCall]);

  // Cleanup on unmount: leave any room + clear timers.
  useEffect(() => {
    return () => {
      endingRef.current = true;
      if (connectionRef.current) void connectionRef.current.disconnect();
      if (ringTimerRef.current) clearTimeout(ringTimerRef.current);
      if (noteTimerRef.current) clearTimeout(noteTimerRef.current);
    };
  }, []);

  const value = useMemo<CallContextValue>(
    () => ({ startCall, isIdle: status === "idle" }),
    [startCall, status]
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
        />
      )}

      {note && status === "idle" && (
        <div
          role="status"
          className="fixed bottom-6 left-1/2 z-[55] -translate-x-1/2 rounded-full bg-fg/90 px-4 py-2 text-sm font-medium text-bg shadow-lg animate-fade-in"
        >
          {note}
        </div>
      )}
    </CallContext.Provider>
  );
}
