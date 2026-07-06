import { createCallToken } from "./api";
// Type-only imports are erased at build → nothing from livekit-client is evaluated during SSR. The
// runtime module is pulled in via dynamic import() below, inside the (client-only, gesture-triggered)
// connect call, so the WebRTC/mediaDevices code never runs on the server or at module load.
import type {
  LocalVideoTrack,
  RemoteTrack,
  RemoteVideoTrack,
  Room as LiveKitRoom
} from "livekit-client";

export type CallConnection = {
  /** Toggle the local mic (true = muted). */
  setMuted: (muted: boolean) => Promise<void>;
  /** Toggle the local camera (Phase-2 video). Publishes/unpublishes the camera track + fires onLocalVideo. */
  setCameraEnabled: (enabled: boolean) => Promise<void>;
  /** The available cameras (videoinput devices) — used to decide whether a front/back switch is possible. */
  getCameraDevices: () => Promise<MediaDeviceInfo[]>;
  /** Switch the active camera. No deviceId → cycle to the NEXT videoinput (front↔back on mobile). Best-
   *  effort: a failed switch keeps the current camera and never drops the call. */
  switchCamera: (deviceId?: string) => Promise<void>;
  /** Leave the room and stop the mic. Leaves the (provider-owned) audio element in place. Idempotent. */
  disconnect: () => Promise<void>;
};

export type ConnectOptions = {
  /**
   * Fired when the LiveKit room disconnects — passes the reason so the provider (and the console) can tell
   * an app-initiated leave from a livekit-client-initiated one (media/ICE failure, duplicate identity, …).
   */
  onDisconnected?: (reason?: string) => void;
  /** Fired when the remote participant's audio starts/stops (drives a "connected" indicator). */
  onRemoteAudio?: (present: boolean) => void;
  /** Publish the camera on connect (Phase-2 video). Default false = voice → the audio path is untouched. */
  video?: boolean;
  /** Fired with the remote participant's video track (or null when it ends). InCallScreen attaches it. */
  onRemoteVideo?: (track: RemoteVideoTrack | null) => void;
  /** Fired with our own camera track (or null when off). InCallScreen attaches it to the self-view PiP. */
  onLocalVideo?: (track: LocalVideoTrack | null) => void;
};

// One tag so all call-media diagnostics are greppable in the browser console during a two-device test.
const TAG = "[call]";

/**
 * Connect to the LiveKit room for `roomName` and start a voice call: fetch a room-scoped token
 * (POST /calls/token), join the SFU, publish the mic, and route the remote participant's audio into
 * `audioElement`.
 *
 * `audioElement` MUST be a stable, persistent sink that lives for the WHOLE call (the provider renders
 * one <audio> once, above the connecting/in-call view swap). The remote track is ATTACHED to it on
 * subscribe and only DETACHED on unsubscribe — the element is never created or removed here.
 *
 * The Room lives inside the returned CallConnection (held in a ref by the provider) and is NEVER
 * recreated or torn down by a React render — only `disconnect()` (real hangup/ended) closes it.
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
  const { Room, RoomEvent, DisconnectReason, Track, VideoPresets } = await import("livekit-client");

  const reasonName = (reason?: number) =>
    reason === undefined ? "unknown" : `${DisconnectReason[reason] ?? "?"}(${reason})`;

  // adaptiveStream + dynacast + simulcast → the peer auto-receives the best layer their network can handle
  // (adaptive/"auto" quality, no hard cap). These are Room-level but only affect VIDEO subscription — a
  // voice call publishes no camera track, so its behavior is unchanged (audio path untouched).
  const room: LiveKitRoom = new Room({
    adaptiveStream: true,
    dynacast: true,
    videoCaptureDefaults: { resolution: VideoPresets.h720.resolution },
    publishDefaults: {
      videoSimulcastLayers: [VideoPresets.h180, VideoPresets.h360, VideoPresets.h720]
    }
  });

  // Camera-switch state, tracked BY US for the connection's life. The bug fix: cycling reads OUR
  // currentCameraId / currentFacing rather than re-reading room.getActiveDevice() each time (which stops
  // matching the enumerated device list after the first switch on mobile → the switch got stuck).
  let currentCameraId: string | undefined;
  let currentFacing: "user" | "environment" = "user";

  const cameraTrack = () =>
    room.localParticipant.getTrackPublication(Track.Source.Camera)?.videoTrack as
      | LocalVideoTrack
      | undefined;

  const refireLocalVideo = () => opts.onLocalVideo?.(cameraTrack() ?? null);

  const attach = (track: RemoteTrack) => {
    if (track.kind !== "audio") return;
    // Attach to THE persistent element (sets its srcObject + plays). Idempotent — no new node.
    track.attach(audioElement);
    opts.onRemoteAudio?.(true);
  };

  room.on(RoomEvent.TrackSubscribed, (track) => {
    console.info(TAG, "remote track subscribed", { kind: track.kind });
    if (track.kind === "audio") {
      attach(track);
    } else if (track.kind === "video") {
      // Do NOT attach video here — InCallScreen owns the <video> element; just hand the track over.
      opts.onRemoteVideo?.(track as RemoteVideoTrack);
    }
  });
  room.on(RoomEvent.TrackUnsubscribed, (track) => {
    if (track.kind === "audio") {
      console.info(TAG, "remote audio track unsubscribed");
      track.detach(audioElement);
      opts.onRemoteAudio?.(false);
    } else if (track.kind === "video") {
      console.info(TAG, "remote video track unsubscribed");
      opts.onRemoteVideo?.(null);
    }
  });
  // Connection-lifecycle diagnostics: these tell us whether livekit-client is trying to recover
  // (Reconnecting/Reconnected) or has given up (Disconnected — the terminal event we act on).
  room.on(RoomEvent.Reconnecting, () => console.warn(TAG, "livekit reconnecting…"));
  room.on(RoomEvent.Reconnected, () => console.info(TAG, "livekit reconnected"));
  room.on(RoomEvent.Disconnected, (reason) => {
    // If reason === CLIENT_INITIATED this was OUR disconnect() call; anything else = livekit-client left
    // on its own (media/ICE failure, duplicate identity, server shutdown, …).
    console.warn(TAG, "livekit Disconnected", { reason: reasonName(reason) });
    opts.onDisconnected?.(reasonName(reason));
  });

  try {
    console.info(TAG, "connecting to room", roomName);
    await room.connect(url, token);
    // Any remote track already subscribed at connect time → surface it now (TrackSubscribed only fires
    // for tracks that arrive AFTER the listener is set).
    room.remoteParticipants.forEach((participant) => {
      participant.audioTrackPublications.forEach((pub) => {
        if (pub.track) attach(pub.track as RemoteTrack);
      });
      participant.videoTrackPublications.forEach((pub) => {
        if (pub.track) opts.onRemoteVideo?.(pub.track as RemoteVideoTrack);
      });
    });
    // Publish the mic (this is what actually prompts for the getUserMedia permission).
    await room.localParticipant.setMicrophoneEnabled(true);
    // Video call → also publish the camera and hand our own track to the self-view. Its OWN try/catch:
    // a camera denied/busy must NOT drop the call — degrade to audio-only (mic already published above).
    if (opts.video) {
      try {
        await room.localParticipant.setCameraEnabled(true);
        const camTrack = cameraTrack();
        // Seed the tracked id from the real published track (most reliable), else the room's active device.
        currentCameraId =
          camTrack?.mediaStreamTrack?.getSettings?.().deviceId ??
          room.getActiveDevice?.("videoinput");
        opts.onLocalVideo?.(camTrack ?? null);
      } catch (err) {
        console.warn(TAG, "camera enable failed — continuing audio-only", err);
        opts.onLocalVideo?.(null);
      }
    }
    console.info(TAG, "connected + mic published", roomName, { video: !!opts.video });
  } catch (error) {
    console.error(TAG, "connect failed", error);
    await room.disconnect().catch(() => undefined);
    throw error;
  }

  // The videoinput devices — prefer LiveKit's helper (handles permissions/labels), fall back to the
  // raw enumeration filtered to cameras.
  const listCameras = async (): Promise<MediaDeviceInfo[]> => {
    const viaRoom = await Room.getLocalDevices?.("videoinput");
    if (viaRoom) return viaRoom;
    const all = await navigator.mediaDevices.enumerateDevices();
    return all.filter((d) => d.kind === "videoinput");
  };

  return {
    setMuted: async (muted) => {
      await room.localParticipant.setMicrophoneEnabled(!muted);
    },
    getCameraDevices: listCameras,
    switchCamera: async (deviceId) => {
      // Flip the camera by facingMode (front↔back) — restarts the SAME track with the new constraint.
      // Repeatable because we track currentFacing ourselves. This is the reliable path on phones.
      const flipFacing = async () => {
        const camTrack = cameraTrack();
        if (!camTrack) return;
        const nextFacing = currentFacing === "user" ? "environment" : "user";
        await camTrack.restartTrack({ facingMode: nextFacing });
        currentFacing = nextFacing;
        currentCameraId = camTrack.mediaStreamTrack?.getSettings?.().deviceId ?? currentCameraId;
        opts.onLocalVideo?.(camTrack);
      };

      try {
        const cams = await listCameras();
        if (cams.length <= 1) return; // nothing to switch to

        // Explicit device request → switch straight to it.
        if (deviceId) {
          await room.switchActiveDevice("videoinput", deviceId);
          currentCameraId = deviceId;
          refireLocalVideo();
          return;
        }

        // Exactly 2 cameras = a front/back phone → facingMode is the primary, most reliable path.
        if (cams.length === 2) {
          await flipFacing();
          return;
        }

        // >2 named cameras (desktop) → cycle by deviceId from OUR tracked id (NOT getActiveDevice, which
        // stops matching the list after the first switch). Fall back to facingMode if the cycle throws.
        try {
          let idx = cams.findIndex((c) => c.deviceId === currentCameraId);
          if (idx === -1) idx = 0;
          const target = cams[(idx + 1) % cams.length].deviceId;
          await room.switchActiveDevice("videoinput", target);
          currentCameraId = target; // <-- the key fix: track the new camera ourselves
          refireLocalVideo();
        } catch (cycleErr) {
          console.warn(TAG, "deviceId cycle failed — falling back to facingMode", cycleErr);
          await flipFacing();
        }
      } catch (err) {
        console.warn(TAG, "camera switch failed — keeping current camera", err);
      }
    },
    setCameraEnabled: async (enabled) => {
      // Defensive mid-call toggle: a camera denied/busy must never crash the call — log, drop the
      // self-view, and swallow. The call (audio) stays up; re-tapping camera retries.
      try {
        await room.localParticipant.setCameraEnabled(enabled);
        const camTrack = cameraTrack();
        // Re-seed the tracked id so a switch after an off→on toggle still cycles from the right camera.
        if (enabled) {
          currentCameraId = camTrack?.mediaStreamTrack?.getSettings?.().deviceId ?? currentCameraId;
        }
        opts.onLocalVideo?.(enabled ? (camTrack ?? null) : null);
      } catch (err) {
        console.warn(TAG, "camera toggle failed — call continues audio-only", err);
        opts.onLocalVideo?.(null);
      }
    },
    disconnect: async () => {
      // The ONLY app-initiated leave. If a CLIENT_REQUEST_LEAVE shows in the server logs, this line ran
      // (or livekit-client left on its own — the Disconnected reason above disambiguates).
      console.warn(TAG, "app called room.disconnect()");
      await room.disconnect().catch(() => undefined);
    }
  };
}
