"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export type RecorderStatus = "idle" | "recording" | "recorded";

// Preferred container/codecs in order; the first MediaRecorder-supported one wins. Chrome/Firefox →
// audio/webm or audio/ogg; Safari (which supports neither) → audio/mp4. All three are in the media
// allow-lists (FE allowedMediaTypes + backend @allowed_content_types).
const PREFERRED_MIME_TYPES = ["audio/webm", "audio/ogg", "audio/mp4"];

function pickMimeType(): string | null {
  if (typeof MediaRecorder === "undefined") return null;
  for (const type of PREFERRED_MIME_TYPES) {
    if (MediaRecorder.isTypeSupported(type)) return type;
  }
  return null; // fall back to the browser default container
}

function extensionFor(mimeType: string): string {
  if (mimeType.includes("webm")) return "webm";
  if (mimeType.includes("ogg")) return "ogg";
  if (mimeType.includes("mp4") || mimeType.includes("mpeg")) return "m4a";
  return "webm";
}

export type VoiceRecorder = {
  status: RecorderStatus;
  /** Elapsed recording time in milliseconds (updates ~5×/sec while recording). */
  elapsedMs: number;
  error: string | null;
  isSupported: boolean;
  /** The recorded audio as a ready-to-upload File (null until stopped without discard). */
  file: File | null;
  /** Object URL for previewing the recording (null until recorded); revoked on reset/unmount. */
  previewUrl: string | null;
  start: () => Promise<void>;
  stop: () => void;
  cancel: () => void;
  reset: () => void;
};

// Encapsulates a tap-to-start / tap-to-stop MediaRecorder session: mic acquisition, the elapsed timer,
// mimeType selection, blob → File, and (critically) releasing the mic tracks on every exit path —
// stop, cancel, and unmount — so the browser's recording indicator never lingers.
export function useVoiceRecorder(): VoiceRecorder {
  const [status, setStatus] = useState<RecorderStatus>("idle");
  const [elapsedMs, setElapsedMs] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const startedAtRef = useRef<number>(0);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const discardRef = useRef(false);

  const isSupported =
    typeof window !== "undefined" &&
    typeof MediaRecorder !== "undefined" &&
    Boolean(navigator.mediaDevices?.getUserMedia);

  const stopTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const releaseStream = useCallback(() => {
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
  }, []);

  const start = useCallback(async () => {
    setError(null);

    if (!isSupported) {
      setError("Voice recording isn't supported in this browser.");
      return;
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      const mimeType = pickMimeType();
      const recorder = mimeType
        ? new MediaRecorder(stream, { mimeType })
        : new MediaRecorder(stream);
      recorderRef.current = recorder;
      chunksRef.current = [];
      discardRef.current = false;

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) chunksRef.current.push(event.data);
      };

      recorder.onstop = () => {
        stopTimer();
        releaseStream();

        if (discardRef.current) {
          chunksRef.current = [];
          return;
        }

        // MediaRecorder reports the full type with a codecs parameter (e.g. "audio/webm; codecs=opus").
        // Normalize to the base type for the allow-list + upload — the recorded container is unchanged,
        // so the base label is correct and the inline <audio> still plays it.
        const rawType = recorder.mimeType || mimeType || "audio/webm";
        const type = rawType.split(";")[0].trim();
        const blob = new Blob(chunksRef.current, { type });
        const name = `voice-message-${Date.now()}.${extensionFor(type)}`;
        setFile(new File([blob], name, { type }));
        setPreviewUrl(URL.createObjectURL(blob));
        setStatus("recorded");
      };

      recorder.start();
      startedAtRef.current = Date.now();
      setElapsedMs(0);
      setStatus("recording");
      timerRef.current = setInterval(() => {
        setElapsedMs(Date.now() - startedAtRef.current);
      }, 200);
    } catch {
      releaseStream();
      setError("Microphone access needed for voice messages.");
      setStatus("idle");
    }
  }, [isSupported, releaseStream, stopTimer]);

  const stop = useCallback(() => {
    const recorder = recorderRef.current;
    if (recorder && recorder.state !== "inactive") {
      discardRef.current = false;
      recorder.stop(); // onstop builds the File + preview
    }
  }, []);

  const cancel = useCallback(() => {
    discardRef.current = true;
    const recorder = recorderRef.current;
    if (recorder && recorder.state !== "inactive") {
      recorder.stop(); // onstop releases the stream and drops the chunks
    } else {
      releaseStream();
    }
    stopTimer();
    setStatus("idle");
    setElapsedMs(0);
    setError(null);
  }, [releaseStream, stopTimer]);

  const reset = useCallback(() => {
    setFile(null);
    setPreviewUrl(null);
    setStatus("idle");
    setElapsedMs(0);
    setError(null);
  }, []);

  // Revoke the previous preview object URL whenever it changes or on unmount (avoids a blob leak).
  useEffect(() => {
    if (!previewUrl) return;
    return () => URL.revokeObjectURL(previewUrl);
  }, [previewUrl]);

  // Unmount safety net: stop a live recorder and release the mic so the recording indicator never
  // lingers if the chat is closed mid-recording. Uses refs only, so it runs exactly once (on unmount).
  useEffect(() => {
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
      const recorder = recorderRef.current;
      if (recorder && recorder.state !== "inactive") {
        discardRef.current = true;
        try {
          recorder.stop();
        } catch {
          // already stopping; ignore
        }
      }
      streamRef.current?.getTracks().forEach((track) => track.stop());
    };
  }, []);

  return {
    status,
    elapsedMs,
    error,
    isSupported,
    file,
    previewUrl,
    start,
    stop,
    cancel,
    reset
  };
}
