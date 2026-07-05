"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Check, Loader2, Minus, Plus, X } from "lucide-react";
import { Button, Card } from "@/components";

export type ImageCropModalProps = {
  /** The picked image file to crop. */
  file: File;
  /** Copy for the title (e.g. "Crop photo"). */
  title?: string;
  onCancel: () => void;
  /** Receives the square-cropped image as a new File, ready for the existing upload flow. */
  onCropped: (file: File) => void;
};

const OUTPUT_SIZE = 512; // square output edge (px)
const MAX_ZOOM = 4;

// A self-contained square image cropper (no external dependency). The picked image is shown inside a
// square viewport that the user pans (drag) and zooms (slider / wheel / pinch); on confirm we draw the
// visible square region to a 512×512 canvas and hand back a square JPEG File. That File then flows through
// the EXISTING compress → createMediaUpload → PUT → complete pipeline unchanged, so uploads stay identical.
export function ImageCropModal({ file, title = "Crop photo", onCancel, onCropped }: ImageCropModalProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  const [viewport, setViewport] = useState(0); // rendered viewport edge in CSS px
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  // Pointer bookkeeping for drag (1 pointer) + pinch (2 pointers).
  const pointers = useRef<Map<number, { x: number; y: number }>>(new Map());
  const pinchRef = useRef<{ dist: number; zoom: number } | null>(null);

  // Object URL for the picked file (derived, not state — avoids a setState-in-effect).
  const imageUrl = useMemo(() => URL.createObjectURL(file), [file]);

  // Load the image to read its natural dimensions, and revoke the URL on unmount. setState only runs in
  // the async onload/onerror callbacks (not synchronously in the effect body).
  useEffect(() => {
    const img = new Image();
    img.onload = () => {
      imgRef.current = img;
      setNatural({ w: img.naturalWidth, h: img.naturalHeight });
    };
    img.onerror = () => setError("Could not load that image.");
    img.src = imageUrl;
    return () => URL.revokeObjectURL(imageUrl);
  }, [imageUrl]);

  // Track the viewport's rendered size (responsive) so the geometry math uses real CSS pixels. The
  // ResizeObserver fires its first callback asynchronously with the initial size — no synchronous setState.
  useEffect(() => {
    const el = viewportRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setViewport(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onCancel();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  // "cover" baseline: at zoom=1 the image's shorter side exactly fills the viewport.
  const baseScale = natural && viewport ? viewport / Math.min(natural.w, natural.h) : 1;
  const displayScale = baseScale * zoom;
  const renderW = natural ? natural.w * displayScale : 0;
  const renderH = natural ? natural.h * displayScale : 0;

  // Keep the image covering the viewport: clamp pan to the overflow half-extents.
  function clampPan(next: { x: number; y: number }, rw = renderW, rh = renderH) {
    const maxX = Math.max(0, (rw - viewport) / 2);
    const maxY = Math.max(0, (rh - viewport) / 2);
    return {
      x: Math.min(maxX, Math.max(-maxX, next.x)),
      y: Math.min(maxY, Math.max(-maxY, next.y))
    };
  }

  function applyZoom(nextZoom: number) {
    const z = Math.min(MAX_ZOOM, Math.max(1, nextZoom));
    const rw = natural ? natural.w * baseScale * z : 0;
    const rh = natural ? natural.h * baseScale * z : 0;
    setZoom(z);
    setPan((p) => clampPan(p, rw, rh));
  }

  function onPointerDown(event: React.PointerEvent) {
    (event.target as Element).setPointerCapture?.(event.pointerId);
    pointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
  }

  function onPointerMove(event: React.PointerEvent) {
    const prev = pointers.current.get(event.pointerId);
    if (!prev) return;
    const cur = { x: event.clientX, y: event.clientY };
    pointers.current.set(event.pointerId, cur);

    if (pointers.current.size >= 2) {
      // Pinch-zoom: scale relative to the change in finger distance.
      const pts = Array.from(pointers.current.values());
      const dist = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      if (!pinchRef.current) pinchRef.current = { dist, zoom };
      else if (pinchRef.current.dist > 0) {
        applyZoom(pinchRef.current.zoom * (dist / pinchRef.current.dist));
      }
      return;
    }
    // Single-pointer drag → pan.
    setPan((p) => clampPan({ x: p.x + (cur.x - prev.x), y: p.y + (cur.y - prev.y) }));
  }

  function endPointer(event: React.PointerEvent) {
    pointers.current.delete(event.pointerId);
    if (pointers.current.size < 2) pinchRef.current = null;
  }

  function onWheel(event: React.WheelEvent) {
    applyZoom(zoom - event.deltaY * 0.0015 * zoom);
  }

  async function handleConfirm() {
    if (!imgRef.current || !natural || !viewport) return;
    setBusy(true);
    setError("");
    try {
      // Map the viewport square back to source pixels. posX/posY = image top-left in viewport coords.
      const posX = (viewport - renderW) / 2 + pan.x;
      const posY = (viewport - renderH) / 2 + pan.y;
      const sx = -posX / displayScale;
      const sy = -posY / displayScale;
      const sSize = viewport / displayScale;

      const canvas = document.createElement("canvas");
      canvas.width = OUTPUT_SIZE;
      canvas.height = OUTPUT_SIZE;
      const ctx = canvas.getContext("2d");
      if (!ctx) throw new Error("Canvas not supported.");
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(
        imgRef.current,
        Math.max(0, sx),
        Math.max(0, sy),
        Math.min(sSize, natural.w),
        Math.min(sSize, natural.h),
        0,
        0,
        OUTPUT_SIZE,
        OUTPUT_SIZE
      );

      const blob: Blob | null = await new Promise((resolve) =>
        canvas.toBlob(resolve, "image/jpeg", 0.9)
      );
      if (!blob) throw new Error("Could not process the image.");

      const base = file.name.replace(/\.[^.]+$/, "") || "avatar";
      onCropped(new File([blob], `${base}.jpg`, { type: "image/jpeg" }));
    } catch (cropError) {
      setError(cropError instanceof Error ? cropError.message : "Could not crop the image.");
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onCancel} className="absolute inset-0" />

      <Card className="relative w-full max-w-sm p-6 animate-scale-in">
        <button
          type="button"
          onClick={onCancel}
          aria-label="Close"
          className="absolute right-3 top-3 rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
        >
          <X className="h-4 w-4" aria-hidden />
        </button>

        <h2 className="mb-4 text-base font-semibold text-fg">{title}</h2>

        {/* Square crop viewport — drag to reposition, zoom with the slider / wheel / pinch. */}
        <div
          ref={viewportRef}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endPointer}
          onPointerCancel={endPointer}
          onWheel={onWheel}
          className="relative mx-auto aspect-square w-full max-w-[280px] cursor-grab touch-none overflow-hidden rounded-2xl border border-border bg-elevated active:cursor-grabbing"
        >
          {imageUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={imageUrl}
              alt=""
              draggable={false}
              className="pointer-events-none absolute left-0 top-0 max-w-none select-none"
              style={{
                width: renderW || undefined,
                height: renderH || undefined,
                transform: `translate3d(${(viewport - renderW) / 2 + pan.x}px, ${
                  (viewport - renderH) / 2 + pan.y
                }px, 0)`
              }}
            />
          ) : null}
          {/* Circular guide so users frame a round avatar. */}
          <div
            className="pointer-events-none absolute inset-0 rounded-2xl ring-1 ring-inset ring-white/20 [box-shadow:0_0_0_9999px_transparent]"
            aria-hidden
          >
            <div className="absolute inset-4 rounded-full ring-2 ring-white/70" />
          </div>
        </div>

        {/* Zoom control */}
        <div className="mt-4 flex items-center gap-3">
          <button
            type="button"
            onClick={() => applyZoom(zoom - 0.2)}
            aria-label="Zoom out"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <Minus className="h-4 w-4" aria-hidden />
          </button>
          <input
            type="range"
            min={1}
            max={MAX_ZOOM}
            step={0.01}
            value={zoom}
            onChange={(event) => applyZoom(Number(event.target.value))}
            aria-label="Zoom"
            className="h-1.5 flex-1 cursor-pointer appearance-none rounded-full bg-border accent-brand"
          />
          <button
            type="button"
            onClick={() => applyZoom(zoom + 0.2)}
            aria-label="Zoom in"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <Plus className="h-4 w-4" aria-hidden />
          </button>
        </div>

        {error ? <p className="mt-3 text-xs text-danger">{error}</p> : null}

        <div className="mt-5 flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
          <Button type="button" onClick={() => void handleConfirm()} disabled={busy || !natural}>
            {busy ? (
              <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
            ) : (
              <Check className="h-4 w-4" aria-hidden />
            )}
            Use photo
          </Button>
        </div>
      </Card>
    </div>
  );
}
