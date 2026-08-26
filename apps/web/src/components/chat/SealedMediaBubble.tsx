"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Download, FileText, Lock, ShieldAlert } from "lucide-react";
import type { MediaDescriptor } from "@/lib/e2ee/canonical";
import { fetchSecretFile } from "@/lib/e2ee/secretChat";
import { openThumb } from "@/lib/e2ee/mediaCrypto";
import { cn } from "@/lib/cn";
import { formatFileSize } from "./format";

// Images at or below this decrypt-and-render on their own; larger files (and all video/other) wait
// for an explicit tap so a big download is never involuntary (E2EE_FRAME.md §8.3).
const AUTO_IMAGE_MAX_BYTES = 3 * 1024 * 1024;

type LoadState = "idle" | "loading" | "error";
type FetchReason = "fetch_failed" | "hash_mismatch" | "decrypt_failed";

const STUB: Record<FetchReason, string> = {
  // Distinct failures get distinct copy so a tampered file never reads as a flaky network.
  fetch_failed: "Couldn't download this file",
  hash_mismatch: "This file failed its integrity check",
  decrypt_failed: "Couldn't decrypt this file"
};

/** Renders a decrypted-in-memory attachment inside a sealed bubble: images/video inline with a lock
 *  badge, other files as a download row. Plaintext bytes and objectURLs live only in memory and are
 *  revoked on unmount — nothing is persisted. */
export function SealedMediaBubble({
  media,
  isOwn,
  footer
}: {
  media: MediaDescriptor;
  isOwn: boolean;
  footer: React.ReactNode;
}) {
  const isImage = media.mime.startsWith("image/");
  const isVideo = media.mime.startsWith("video/");
  const autoLoad = isImage && media.size <= AUTO_IMAGE_MAX_BYTES;

  const [full, setFull] = useState<string | null>(null);
  const [thumbUrl, setThumbUrl] = useState<string | null>(null);
  const [state, setState] = useState<LoadState>("idle");
  const [reason, setReason] = useState<FetchReason | null>(null);

  // Every objectURL we mint is tracked here and revoked together on unmount.
  const urlsRef = useRef<string[]>([]);
  const track = useCallback((url: string) => {
    urlsRef.current.push(url);
    return url;
  }, []);
  useEffect(
    () => () => {
      for (const url of urlsRef.current) URL.revokeObjectURL(url);
      urlsRef.current = [];
    },
    []
  );

  const objectUrl = useCallback(
    (bytes: Uint8Array, type: string) =>
      track(URL.createObjectURL(new Blob([bytes], { type: type || "application/octet-stream" }))),
    [track]
  );

  // Decrypt the inline thumb once (an instant low-res preview while the full image downloads).
  useEffect(() => {
    if (!media.thumb) return;
    let cancelled = false;
    void (async () => {
      const bytes = await openThumb(media);
      if (cancelled || !bytes) return;
      setThumbUrl(objectUrl(bytes, "image/jpeg"));
    })();
    return () => {
      cancelled = true;
    };
  }, [media, objectUrl]);

  // Shared fetch → decrypt → objectURL, used by both auto-load and tap. setState here is only ever
  // reached from an async callback / event handler, never synchronously in an effect body.
  const load = useCallback(async () => {
    setState("loading");
    const res = await fetchSecretFile(media);
    if (res.ok) {
      setFull(objectUrl(res.bytes, media.mime));
      setState("idle");
      setReason(null);
    } else {
      setReason(res.reason);
      setState("error");
    }
  }, [media, objectUrl]);

  // Auto-load small images (fires from inside the async IIFE, not the effect body).
  useEffect(() => {
    if (!autoLoad) return;
    let cancelled = false;
    void (async () => {
      const res = await fetchSecretFile(media);
      if (cancelled) return;
      if (res.ok) {
        setFull(objectUrl(res.bytes, media.mime));
      } else {
        setReason(res.reason);
        setState("error");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [autoLoad, media, objectUrl]);

  const lockBadge = (
    <span className={cn("flex items-center gap-1 text-[10px]", isOwn ? "text-white/70" : "text-faint")}>
      <Lock className="h-2.5 w-2.5" aria-hidden />
      {footer}
    </span>
  );

  if (state === "error" && reason) {
    return (
      <div className="space-y-1">
        <span className="flex items-center gap-2 text-sm italic opacity-80">
          <ShieldAlert className="h-4 w-4 shrink-0" aria-hidden />
          {STUB[reason]}
        </span>
        {reason === "fetch_failed" ? (
          <button
            type="button"
            onClick={() => void load()}
            className={cn(
              "text-[11px] underline underline-offset-2",
              isOwn ? "text-white/80" : "text-brand"
            )}
          >
            Try again
          </button>
        ) : null}
        {lockBadge}
      </div>
    );
  }

  // Image: full when decrypted, else the thumb preview, else a name/size placeholder to tap.
  if (isImage) {
    if (full) {
      return (
        <div className="space-y-1">
          {/* eslint-disable-next-line @next/next/no-img-element -- in-memory objectURL, not a static asset */}
          <img
            src={full}
            alt={media.name}
            className="max-h-72 w-full rounded-lg object-cover"
          />
          {lockBadge}
        </div>
      );
    }
    return (
      <button
        type="button"
        onClick={() => void load()}
        disabled={state === "loading"}
        className="block w-full space-y-1 text-left"
      >
        {thumbUrl ? (
          // eslint-disable-next-line @next/next/no-img-element -- decrypted thumb objectURL
          <img
            src={thumbUrl}
            alt={media.name}
            className="max-h-72 w-full rounded-lg object-cover blur-[2px]"
          />
        ) : (
          <span className="flex h-32 w-48 max-w-full items-center justify-center rounded-lg bg-black/10 text-xs">
            {state === "loading" ? "Decrypting…" : "Tap to view"}
          </span>
        )}
        {lockBadge}
      </button>
    );
  }

  // Video: decrypt on tap, then an inline player.
  if (isVideo) {
    if (full) {
      return (
        <div className="space-y-1">
          <video src={full} controls className="max-h-72 w-full rounded-lg" />
          {lockBadge}
        </div>
      );
    }
    return (
      <button
        type="button"
        onClick={() => void load()}
        disabled={state === "loading"}
        className="block w-full space-y-1 text-left"
      >
        <span className="flex items-center gap-2 rounded-lg bg-black/10 px-3 py-4 text-sm">
          <FileText className="h-5 w-5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate">{media.name}</span>
          <span className="shrink-0 text-xs opacity-70">
            {state === "loading" ? "Decrypting…" : formatFileSize(media.size)}
          </span>
        </span>
        {lockBadge}
      </button>
    );
  }

  // Any other file: a download row (the decrypted blob is offered via an objectURL, in memory only).
  return (
    <div className="space-y-1">
      {full ? (
        <a
          href={full}
          download={media.name}
          className="flex items-center gap-2 rounded-lg bg-black/10 px-3 py-2 text-sm"
        >
          <Download className="h-5 w-5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate">{media.name}</span>
          <span className="shrink-0 text-xs opacity-70">{formatFileSize(media.size)}</span>
        </a>
      ) : (
        <button
          type="button"
          onClick={() => void load()}
          disabled={state === "loading"}
          className="flex w-full items-center gap-2 rounded-lg bg-black/10 px-3 py-2 text-left text-sm"
        >
          <FileText className="h-5 w-5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate">{media.name}</span>
          <span className="shrink-0 text-xs opacity-70">
            {state === "loading" ? "Decrypting…" : formatFileSize(media.size)}
          </span>
        </button>
      )}
      {lockBadge}
    </div>
  );
}
