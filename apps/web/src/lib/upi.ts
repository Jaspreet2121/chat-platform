// UPI helpers for the web client (100): decoding a QR out of an uploaded image, and reading a
// `upi://pay?...` payload well enough to CONFIRM a scan before it is saved. The server remains the
// authority — it re-parses the payload and owns canonicalisation; this only powers the preview.

import jsQR from "jsqr";

/**
 * Decode a QR from an image File. → the encoded string, or null when no code was found. Draws to a
 * canvas because jsQR wants raw RGBA pixels. Large photos are downscaled first: a 12MP screenshot is
 * both slow to scan and no more accurate than a 1600px one.
 */
export async function decodeQrFromFile(file: File): Promise<string | null> {
  if (typeof document === "undefined") return null;

  const bitmap = await createImageBitmap(file);
  try {
    const MAX_EDGE = 1600;
    const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));

    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) return null;

    context.drawImage(bitmap, 0, 0, width, height);
    const { data } = context.getImageData(0, 0, width, height);

    const result = jsQR(data, width, height, { inversionAttempts: "attemptBoth" });
    return result?.data ?? null;
  } finally {
    bitmap.close();
  }
}

export type ParsedUpi = { upiId: string; payeeName?: string };

// Mirrors the server's VPA rule (UserService.Upi) so the preview refuses what the PATCH would.
const VPA = /^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$/;

/**
 * Read the identity out of a `upi://pay?...` payload for the confirm step. → null when it isn't a
 * UPI payment link or carries no valid payee address. Merchant params are deliberately NOT touched
 * here: they ride the raw payload to the server, which preserves them verbatim.
 */
export function parseUpiPayload(payload: string): ParsedUpi | null {
  const [scheme, query] = payload.split("?", 2);
  if (!query) return null;
  // The scheme match is case-insensitive server-side ("UPI://PAY?..." exists in the wild).
  if (scheme.trim().toLowerCase() !== "upi://pay") return null;

  const params = new URLSearchParams(query);
  const upiId = params.get("pa")?.trim();
  if (!upiId || !VPA.test(upiId)) return null;

  const payeeName = params.get("pn")?.trim() || undefined;
  return { upiId, payeeName };
}

/** The deep link a payer's app opens. Built from the stored identity, not from a raw scan. */
export function upiPayLink(upiId: string, payeeName?: string | null): string {
  const params = new URLSearchParams({ pa: upiId });
  if (payeeName?.trim()) params.set("pn", payeeName.trim());
  params.set("cu", "INR");
  // URLSearchParams encodes spaces as "+", which strict PSP parsers reject — use %20.
  return `upi://pay?${params.toString().replace(/\+/g, "%20")}`;
}
