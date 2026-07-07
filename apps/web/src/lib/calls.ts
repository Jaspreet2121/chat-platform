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

// ============================================================================================
// iOS standalone-PWA audio (WebAudio, stale-recreate). A home-screen PWA on iOS silently DROPS remote
// WebRTC audio played through an <audio> element — while iOS Safari, Android, and desktop all play it. Worse:
// iOS SUSPENDS/INTERRUPTS the AudioContext when the PWA backgrounds, and a reused (interrupted) context stays
// silent even after resume() — hence "works on first launch, silent after reopen". Fix, gated to iOS-PWA:
//   (a) route remote audio through a WebAudio context (reliable in the PWA),
//   (b) RECREATE that context whenever it's stale (closed / not-"running"), inside the accept/connect gesture,
//   (c) CLOSE it on background so the next call rebuilds a fresh one.
// Everyone else keeps the proven <audio> path, byte-for-byte — isIOSPWA() is false so no context is ever made.
// ============================================================================================

/** True only in an iOS home-screen (standalone) PWA — the one environment with the silent-audio bug. */
export const isIOSPWA = (): boolean =>
  typeof navigator !== "undefined" &&
  /iP(hone|ad|od)/.test(navigator.userAgent) &&
  ((navigator as Navigator & { standalone?: boolean }).standalone === true ||
    (typeof window !== "undefined" &&
      window.matchMedia?.("(display-mode: standalone)").matches === true));

type AudioCtor = typeof AudioContext;
const audioCtor = (): AudioCtor | null =>
  typeof window === "undefined"
    ? null
    : (window.AudioContext ??
        (window as Window & { webkitAudioContext?: AudioCtor }).webkitAudioContext ??
        null);

let audioCtx: AudioContext | null = null;

// A LIVE context — recreate if missing or closed (iOS marks it closed/non-running after backgrounding or an
// interruption). Callers build their MediaStreamSource from THIS each time, so it's always on the live ctx.
const getLiveAudioContext = (): AudioContext | null => {
  const Ctor = audioCtor();
  if (!Ctor) return null;
  if (!audioCtx || audioCtx.state === "closed") audioCtx = new Ctor();
  return audioCtx;
};

/**
 * Unlock/resume the WebAudio context — MUST be called synchronously inside a user gesture (call button /
 * Accept). Resumes the live ctx; if resume doesn't take (a stale ctx carried over from a previous app
 * session), CLOSES + rebuilds a fresh one and resumes that; then plays a 1-sample silent buffer to fully
 * unlock iOS audio. No-op off iOS-PWA (returns before touching any AudioContext).
 */
export const unlockAudioContext = async (): Promise<void> => {
  if (!isIOSPWA()) return;
  const Ctor = audioCtor();
  if (!Ctor) return;
  try {
    let ctx = getLiveAudioContext();
    if (!ctx) return;
    if (ctx.state !== "running") await ctx.resume();
    // Resume didn't take (interrupted/stale) → rebuild fresh and resume that one.
    if (ctx.state !== "running") {
      try {
        await ctx.close();
      } catch {
        /* ignore */
      }
      audioCtx = new Ctor();
      ctx = audioCtx;
      await ctx.resume();
    }
    const src = ctx.createBufferSource();
    src.buffer = ctx.createBuffer(1, 1, 22050);
    src.connect(ctx.destination);
    src.start(0);
  } catch (e) {
    console.warn(TAG, "audio unlock failed", e);
  }
};

// On background (pagehide / tab hidden) CLOSE + drop the ctx, so the next call's gesture rebuilds a fresh one
// — a context carried across a background/interruption stays silent. Registered ONCE, and only on iOS-PWA
// (elsewhere no context is ever created, so this would be a no-op anyway — we skip registering entirely).
if (typeof window !== "undefined" && isIOSPWA()) {
  const markAudioStale = () => {
    if (audioCtx && audioCtx.state !== "closed") audioCtx.close().catch(() => undefined);
    audioCtx = null;
  };
  window.addEventListener("pagehide", markAudioStale);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) markAudioStale();
  });
}

const IOS_AUDIO_MARKER = "data-livekit-ios-audio";

/**
 * Route a remote audio track through WebAudio (iOS-PWA only). Belt-and-suspenders: a MUTED <audio> keeps the
 * MediaStreamTrack "live" (an unreferenced remote track can go silent on iOS), while a WebAudio
 * source→destination on the LIVE context actually plays it. The source is built from getLiveAudioContext() so
 * a ctx recreated after an app reopen is the one used. Returns a cleanup fn (disconnect node + remove el).
 */
const routeIOSAudio = (track: RemoteTrack): (() => void) => {
  const el = track.attach();
  el.muted = true;
  el.setAttribute(IOS_AUDIO_MARKER, "");
  el.style.display = "none";
  document.body.appendChild(el);

  let source: MediaStreamAudioSourceNode | null = null;
  const ctx = getLiveAudioContext();
  const mst = track.mediaStreamTrack;
  if (ctx && mst) {
    try {
      if (ctx.state !== "running") void ctx.resume().catch(() => undefined);
      source = ctx.createMediaStreamSource(new MediaStream([mst]));
      source.connect(ctx.destination);
    } catch {
      source = null;
    }
  }

  return () => {
    try {
      source?.disconnect();
    } catch {
      /* ignore */
    }
    track.detach().forEach((e) => e.parentNode?.removeChild(e));
  };
};

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

  // Per-connection iOS-PWA WebAudio cleanups, keyed by track. Empty (unused) off iOS-PWA.
  const audioCleanups = new Map<RemoteTrack, () => void>();
  const sweepIOSAudio = () => {
    audioCleanups.forEach((fn) => {
      try {
        fn();
      } catch {
        /* ignore */
      }
    });
    audioCleanups.clear();
  };

  const attach = (track: RemoteTrack) => {
    if (track.kind !== "audio") return;
    if (isIOSPWA()) {
      // iOS home-screen PWA: <audio> playback is silent → route this remote's audio through WebAudio.
      audioCleanups.set(track, routeIOSAudio(track));
    } else {
      // Android / iOS Safari / desktop: attach to THE persistent element (sets srcObject + plays). Idempotent
      // — no new node. UNCHANGED.
      track.attach(audioElement);
    }
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
      const cleanup = audioCleanups.get(track);
      if (cleanup) {
        // iOS-PWA: tear down the WebAudio routing for this track.
        cleanup();
        audioCleanups.delete(track);
      } else {
        // Everyone else: the sacred detach path — UNCHANGED.
        track.detach(audioElement);
      }
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
    sweepIOSAudio();
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
    sweepIOSAudio();
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
      // Tear down any iOS-PWA WebAudio routing (no-op off iOS-PWA). The persistent audioElement is untouched.
      sweepIOSAudio();
    }
  };
}

// ============================================================================================
// Phase-3 GROUP calling. SEPARATE from connectToRoom (1-on-1) so the working 1-on-1 path is never
// touched. N remote participants: their AUDIO is attached to per-track hidden <audio> elements MANAGED
// HERE (React never sees audio — no re-render churn); their VIDEO tracks + the participant set are
// surfaced to the provider (onParticipants) for the tile grid to attach.
// ============================================================================================

/** One remote participant in a group call (identity = their user_id). */
export type GroupParticipant = {
  identity: string;
  videoTrack: RemoteVideoTrack | null;
};

export type GroupConnection = {
  setMuted: (muted: boolean) => Promise<void>;
  setCameraEnabled: (enabled: boolean) => Promise<void>;
  getCameraDevices: () => Promise<MediaDeviceInfo[]>;
  switchCamera: (deviceId?: string) => Promise<void>;
  disconnect: () => Promise<void>;
};

export type GroupConnectOptions = {
  video?: boolean;
  onLocalVideo?: (track: LocalVideoTrack | null) => void;
  /** Fired whenever the remote participant set OR their video tracks change (drives the tile grid). */
  onParticipants?: (participants: GroupParticipant[]) => void;
  onDisconnected?: (reason?: string) => void;
};

export async function connectToGroupRoom(
  roomName: string,
  opts: GroupConnectOptions = {}
): Promise<GroupConnection> {
  const { url, token } = await createCallToken(roomName);
  const { Room, RoomEvent, DisconnectReason, Track, VideoPresets } = await import("livekit-client");

  const reasonName = (reason?: number) =>
    reason === undefined ? "unknown" : `${DisconnectReason[reason] ?? "?"}(${reason})`;

  const room: LiveKitRoom = new Room({
    adaptiveStream: true,
    dynacast: true,
    videoCaptureDefaults: { resolution: VideoPresets.h720.resolution },
    publishDefaults: {
      videoSimulcastLayers: [VideoPresets.h180, VideoPresets.h360, VideoPresets.h720]
    }
  });

  let currentCameraId: string | undefined;
  let currentFacing: "user" | "environment" = "user";
  const cameraTrack = () =>
    room.localParticipant.getTrackPublication(Track.Source.Camera)?.videoTrack as
      | LocalVideoTrack
      | undefined;
  const refireLocalVideo = () => opts.onLocalVideo?.(cameraTrack() ?? null);

  const AUDIO_MARKER = "data-livekit-group-audio";
  // iOS-PWA WebAudio cleanups (keyed by track); empty off iOS-PWA → the plain <audio> path below.
  const audioCleanups = new Map<RemoteTrack, () => void>();
  const attachAudio = (track: RemoteTrack) => {
    if (track.kind !== "audio") return;
    if (isIOSPWA()) {
      // iOS home-screen PWA: <audio> playback is silent → route each remote's audio through WebAudio.
      audioCleanups.set(track, routeIOSAudio(track));
      return;
    }
    const el = track.attach();
    el.setAttribute(AUDIO_MARKER, "");
    el.autoplay = true;
    el.style.display = "none";
    document.body.appendChild(el);
  };
  const detachAudio = (track: RemoteTrack) => {
    if (track.kind !== "audio") return;
    const cleanup = audioCleanups.get(track);
    if (cleanup) {
      cleanup();
      audioCleanups.delete(track);
      return;
    }
    track.detach().forEach((el) => el.parentNode?.removeChild(el));
  };
  const sweepAudio = () => {
    document.querySelectorAll(`[${AUDIO_MARKER}]`).forEach((el) => el.parentNode?.removeChild(el));
    audioCleanups.forEach((fn) => {
      try {
        fn();
      } catch {
        /* ignore */
      }
    });
    audioCleanups.clear();
  };

  // Remote participant set + their (nullable) video track. A tile shows for EVERY connected participant;
  // a camera-off participant just has videoTrack: null (the tile renders their avatar).
  const identities = new Set<string>();
  const videoByIdentity = new Map<string, RemoteVideoTrack>();
  const emit = () =>
    opts.onParticipants?.(
      [...identities].map((identity) => ({ identity, videoTrack: videoByIdentity.get(identity) ?? null }))
    );

  room.on(RoomEvent.ParticipantConnected, (p) => {
    identities.add(p.identity);
    emit();
  });
  room.on(RoomEvent.ParticipantDisconnected, (p) => {
    identities.delete(p.identity);
    videoByIdentity.delete(p.identity);
    emit();
  });
  room.on(RoomEvent.TrackSubscribed, (track, _pub, participant) => {
    identities.add(participant.identity);
    if (track.kind === "audio") attachAudio(track);
    else if (track.kind === "video") videoByIdentity.set(participant.identity, track as RemoteVideoTrack);
    emit();
  });
  room.on(RoomEvent.TrackUnsubscribed, (track, _pub, participant) => {
    if (track.kind === "audio") detachAudio(track);
    else if (track.kind === "video") videoByIdentity.delete(participant.identity);
    emit();
  });
  room.on(RoomEvent.Reconnecting, () => console.warn(TAG, "group livekit reconnecting…"));
  room.on(RoomEvent.Reconnected, () => console.info(TAG, "group livekit reconnected"));
  room.on(RoomEvent.Disconnected, (reason) => {
    console.warn(TAG, "group livekit Disconnected", { reason: reasonName(reason) });
    sweepAudio();
    opts.onDisconnected?.(reasonName(reason));
  });

  try {
    console.info(TAG, "connecting to GROUP room", roomName);
    await room.connect(url, token);
    // Participants already present at connect time.
    room.remoteParticipants.forEach((p) => {
      identities.add(p.identity);
      p.audioTrackPublications.forEach((pub) => pub.track && attachAudio(pub.track as RemoteTrack));
      p.videoTrackPublications.forEach(
        (pub) => pub.track && videoByIdentity.set(p.identity, pub.track as RemoteVideoTrack)
      );
    });
    emit();
    await room.localParticipant.setMicrophoneEnabled(true);
    if (opts.video) {
      try {
        await room.localParticipant.setCameraEnabled(true);
        currentCameraId =
          cameraTrack()?.mediaStreamTrack?.getSettings?.().deviceId ??
          room.getActiveDevice?.("videoinput");
        opts.onLocalVideo?.(cameraTrack() ?? null);
      } catch (err) {
        console.warn(TAG, "group camera enable failed — audio-only", err);
        opts.onLocalVideo?.(null);
      }
    }
    console.info(TAG, "connected to GROUP room", roomName, { video: !!opts.video });
  } catch (error) {
    console.error(TAG, "group connect failed", error);
    sweepAudio();
    await room.disconnect().catch(() => undefined);
    throw error;
  }

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
    setCameraEnabled: async (enabled) => {
      try {
        await room.localParticipant.setCameraEnabled(enabled);
        if (enabled) {
          currentCameraId = cameraTrack()?.mediaStreamTrack?.getSettings?.().deviceId ?? currentCameraId;
        }
        opts.onLocalVideo?.(enabled ? (cameraTrack() ?? null) : null);
      } catch (err) {
        console.warn(TAG, "group camera toggle failed", err);
        opts.onLocalVideo?.(null);
      }
    },
    switchCamera: async (deviceId) => {
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
        if (cams.length <= 1) return;
        if (deviceId) {
          await room.switchActiveDevice("videoinput", deviceId);
          currentCameraId = deviceId;
          refireLocalVideo();
          return;
        }
        if (cams.length === 2) {
          await flipFacing();
          return;
        }
        try {
          let idx = cams.findIndex((c) => c.deviceId === currentCameraId);
          if (idx === -1) idx = 0;
          const target = cams[(idx + 1) % cams.length].deviceId;
          await room.switchActiveDevice("videoinput", target);
          currentCameraId = target;
          refireLocalVideo();
        } catch (cycleErr) {
          console.warn(TAG, "group deviceId cycle failed — facingMode fallback", cycleErr);
          await flipFacing();
        }
      } catch (err) {
        console.warn(TAG, "group camera switch failed — keeping current", err);
      }
    },
    disconnect: async () => {
      console.warn(TAG, "app called group room.disconnect()");
      await room.disconnect().catch(() => undefined);
      sweepAudio();
    }
  };
}
