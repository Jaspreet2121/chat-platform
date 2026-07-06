import { createCallToken } from "./api";
// Type-only imports are erased at build → nothing from livekit-client is evaluated during SSR. The
// runtime module is pulled in via dynamic import() below, inside the (client-only, gesture-triggered)
// connect call, so the WebRTC/mediaDevices code never runs on the server or at module load.
import type { RemoteTrack, Room as LiveKitRoom } from "livekit-client";

export type CallConnection = {
  /** Toggle the local mic (true = muted). */
  setMuted: (muted: boolean) => Promise<void>;
  /** Leave the room, stop the mic, and remove the attached audio element. Idempotent. */
  disconnect: () => Promise<void>;
};

export type ConnectOptions = {
  /** Fired when the room disconnects for ANY reason (peer left, network, or our own disconnect). */
  onDisconnected?: () => void;
  /** Fired when the remote participant's audio starts/stops (drives a "connected" indicator). */
  onRemoteAudio?: (present: boolean) => void;
};

const AUDIO_MARKER = "data-livekit-remote-audio";

// Attach a remote audio track to a fresh hidden <audio autoplay> on the body. LiveKit's track.attach()
// creates + starts the element; we tag it so disconnect can sweep every one it made.
function attachAudio(track: RemoteTrack) {
  const el = track.attach();
  el.setAttribute(AUDIO_MARKER, "");
  el.autoplay = true;
  // Not in the layout — audio only.
  el.style.display = "none";
  document.body.appendChild(el);
}

function sweepAudio() {
  document
    .querySelectorAll(`[${AUDIO_MARKER}]`)
    .forEach((el) => el.parentNode?.removeChild(el));
}

/**
 * Connect to the LiveKit room for `roomName` and start a voice call: fetch a room-scoped token
 * (POST /calls/token), join the SFU, publish the mic, and attach the remote participant's audio.
 *
 * MUST be called from a user gesture (Accept, or initiating the call) — that gesture is what unlocks
 * microphone capture and audio autoplay in the browser, iOS Safari in particular. Throws on
 * mic-permission-denied or connection failure; the caller resets the UI and surfaces a message.
 */
export async function connectToRoom(
  roomName: string,
  opts: ConnectOptions = {}
): Promise<CallConnection> {
  const { url, token } = await createCallToken(roomName);
  const { Room, RoomEvent } = await import("livekit-client");

  const room: LiveKitRoom = new Room({ adaptiveStream: false, dynacast: false });

  room.on(RoomEvent.TrackSubscribed, (track) => {
    if (track.kind === "audio") {
      attachAudio(track);
      opts.onRemoteAudio?.(true);
    }
  });
  room.on(RoomEvent.TrackUnsubscribed, (track) => {
    if (track.kind === "audio") {
      track.detach().forEach((el) => el.parentNode?.removeChild(el));
      opts.onRemoteAudio?.(false);
    }
  });
  room.on(RoomEvent.Disconnected, () => {
    sweepAudio();
    opts.onDisconnected?.();
  });

  try {
    await room.connect(url, token);
    // Publish the mic (this is what actually prompts for the getUserMedia permission).
    await room.localParticipant.setMicrophoneEnabled(true);
  } catch (error) {
    sweepAudio();
    await room.disconnect().catch(() => undefined);
    throw error;
  }

  return {
    setMuted: async (muted) => {
      await room.localParticipant.setMicrophoneEnabled(!muted);
    },
    disconnect: async () => {
      await room.disconnect().catch(() => undefined);
      sweepAudio();
    }
  };
}
