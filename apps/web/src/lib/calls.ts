import { createCallToken } from "./api";
// Type-only imports are erased at build → nothing from livekit-client is evaluated during SSR. The
// runtime module is pulled in via dynamic import() below, inside the (client-only, gesture-triggered)
// connect call, so the WebRTC/mediaDevices code never runs on the server or at module load.
import type { RemoteTrack, Room as LiveKitRoom } from "livekit-client";

export type CallConnection = {
  /** Toggle the local mic (true = muted). */
  setMuted: (muted: boolean) => Promise<void>;
  /** Leave the room and stop the mic. Leaves the (provider-owned) audio element in place. Idempotent. */
  disconnect: () => Promise<void>;
};

export type ConnectOptions = {
  /** Fired when the room disconnects for ANY reason (peer left, network, or our own disconnect). */
  onDisconnected?: () => void;
  /** Fired when the remote participant's audio starts/stops (drives a "connected" indicator). */
  onRemoteAudio?: (present: boolean) => void;
};

/**
 * Connect to the LiveKit room for `roomName` and start a voice call: fetch a room-scoped token
 * (POST /calls/token), join the SFU, publish the mic, and route the remote participant's audio into
 * `audioElement`.
 *
 * `audioElement` MUST be a stable, persistent sink that lives for the WHOLE call (the provider renders
 * one <audio> once, above the connecting/in-call view swap). The remote track is ATTACHED to it on
 * subscribe and only DETACHED on unsubscribe — the element is never created or removed here, so the
 * connecting→in-call transition (and LiveKit's post-connect renegotiation, which briefly re-subscribes
 * the remote track) can't tear the sink down. That churn is exactly what was dropping audio before.
 *
 * MUST be called from a user gesture (Accept, or initiating the call) — that gesture is what unlocks
 * microphone capture and audio autoplay in the browser, iOS Safari in particular. Throws on
 * mic-permission-denied or connection failure; the caller resets the UI and surfaces a message.
 */
export async function connectToRoom(
  roomName: string,
  audioElement: HTMLMediaElement,
  opts: ConnectOptions = {}
): Promise<CallConnection> {
  const { url, token } = await createCallToken(roomName);
  const { Room, RoomEvent } = await import("livekit-client");

  const room: LiveKitRoom = new Room({ adaptiveStream: false, dynacast: false });

  const attach = (track: RemoteTrack) => {
    if (track.kind !== "audio") return;
    // Attach to THE persistent element (sets its srcObject + plays). Re-attaching the same/replacement
    // track to the same element is safe and idempotent — no new node, nothing removed.
    track.attach(audioElement);
    opts.onRemoteAudio?.(true);
  };

  room.on(RoomEvent.TrackSubscribed, attach);
  room.on(RoomEvent.TrackUnsubscribed, (track) => {
    if (track.kind !== "audio") return;
    // Detach FROM the element only (clears srcObject); never remove the element — the provider owns it
    // and a re-subscribe will re-attach to the very same sink.
    track.detach(audioElement);
    opts.onRemoteAudio?.(false);
  });
  room.on(RoomEvent.Disconnected, () => {
    opts.onDisconnected?.();
  });

  try {
    await room.connect(url, token);
    // Any remote audio already subscribed at connect time → attach it now (TrackSubscribed only fires
    // for tracks that arrive AFTER the listener is set).
    room.remoteParticipants.forEach((participant) => {
      participant.audioTrackPublications.forEach((pub) => {
        if (pub.track) attach(pub.track as RemoteTrack);
      });
    });
    // Publish the mic (this is what actually prompts for the getUserMedia permission).
    await room.localParticipant.setMicrophoneEnabled(true);
  } catch (error) {
    await room.disconnect().catch(() => undefined);
    throw error;
  }

  return {
    setMuted: async (muted) => {
      await room.localParticipant.setMicrophoneEnabled(!muted);
    },
    disconnect: async () => {
      await room.disconnect().catch(() => undefined);
    }
  };
}
