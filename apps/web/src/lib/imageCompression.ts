import imageCompression from "browser-image-compression";

/**
 * THE ONE IMAGE-COMPRESSION STEP, and the profiles it runs with.
 *
 * Four call sites each carried their own inline copy of these options, so a FIFTH (the dating
 * uploader) could — and did — simply not have one: dating photos were PUT byte-for-byte, a 4 MB
 * camera photo taking ~3.0 s to paint against ~0.35 s at ~300 KB. Profiles live here so a new
 * uploader picks one by name instead of re-deciding the numbers, and so changing them is one edit.
 *
 * EXIF IS STRIPPED, which matters most for dating. browser-image-compression reads the orientation
 * tag and applies the rotation to the canvas, then writes the output WITHOUT the EXIF block
 * (`preserveExif` defaults to false) — so the photo stays upright while the camera's GPS
 * coordinates, device id and timestamp do not travel with a picture shown to strangers. Do not set
 * `preserveExif: true` here: that would put the GPS back.
 */
export const IMAGE_PROFILES = {
  /**
   * Avatars and group photos: rendered at ~40-96 px, never full-bleed. 512 px covers a 3× retina
   * 96 px tile with room to spare.
   */
  avatar: { maxSizeMB: 0.5, maxWidthOrHeight: 512, initialQuality: 0.8 },

  /**
   * DATING CARD PHOTOS — viewed far larger than an avatar, and the reason this module exists.
   *
   * 1440 px: a dating card is full-bleed, so on a 3× phone (390 CSS px ≈ 1170 device px) 1440 is the
   * first round number that still oversamples it, and it covers a tablet/desktop card too. Going
   * higher buys pixels no screen shows; going lower (1080) is visibly soft on a 3× phone.
   *
   * 0.4 MB: the measured budget — ~300 KB paints in ~0.35 s against ~3.0 s for the 4 MB original,
   * and a deck card carries several photos. Slightly above 300 KB so the quality ladder rarely has
   * to drop below ~0.7 on a detailed photo.
   */
  datingPhoto: { maxSizeMB: 0.4, maxWidthOrHeight: 1440, initialQuality: 0.8 },

  /** Chat attachments: viewed inline, tappable to full screen, and kept forever. */
  attachment: { maxSizeMB: 1, maxWidthOrHeight: 1920, initialQuality: 0.8 }
} as const;

export type ImageProfile = keyof typeof IMAGE_PROFILES;

/**
 * Compress `file` with the named profile. NEVER throws: a compression failure (an image canvas
 * cannot decode, a worker that won't start) falls back to the original bytes, because a photo that
 * uploads large beats a photo that does not upload at all. Every original call site did the same.
 */
export async function compressImage(file: File, profile: ImageProfile): Promise<File> {
  try {
    return await imageCompression(file, { ...IMAGE_PROFILES[profile], useWebWorker: true });
  } catch {
    return file;
  }
}
