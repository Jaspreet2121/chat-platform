// Client-side thumbnail generation for encrypted images (E2EE_FRAME.md §8.1). Downscales an image
// File to a small JPEG via canvas — returns the raw bytes + dimensions for sealFile to encrypt with
// the file key. Skips non-images and any failure (the send proceeds without a thumb).

const THUMB_MAX_EDGE = 128;
const THUMB_QUALITY = 0.6;

export async function makeImageThumb(
  file: File
): Promise<{ bytes: Uint8Array; w: number; h: number } | undefined> {
  if (typeof document === "undefined" || !file.type.startsWith("image/")) return undefined;

  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, THUMB_MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const w = Math.max(1, Math.round(bitmap.width * scale));
    const h = Math.max(1, Math.round(bitmap.height * scale));

    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) return undefined;
    ctx.drawImage(bitmap, 0, 0, w, h);
    bitmap.close();

    const blob: Blob | null = await new Promise((resolve) =>
      canvas.toBlob(resolve, "image/jpeg", THUMB_QUALITY)
    );
    if (!blob) return undefined;

    return { bytes: new Uint8Array(await blob.arrayBuffer()), w, h };
  } catch {
    return undefined;
  }
}
