import { beforeEach, describe, expect, it, vi } from "vitest";

const compress = vi.hoisted(() => vi.fn());
vi.mock("browser-image-compression", () => ({ default: compress }));

import { IMAGE_PROFILES, compressImage } from "@/lib/imageCompression";

function file(bytes: number, type = "image/jpeg"): File {
  return new File([new Uint8Array(bytes)], "photo.jpg", { type });
}

beforeEach(() => {
  compress.mockReset();
  // A stand-in that honours the profile's byte budget, so "was it reduced?" is a real question.
  compress.mockImplementation(async (input: File, options: { maxSizeMB: number }) =>
    file(Math.min(input.size, options.maxSizeMB * 1024 * 1024))
  );
});

describe("the profiles", () => {
  it("DATING photos: 1440px / 0.4MB — big enough for a full-bleed card, small enough to paint fast", () => {
    expect(IMAGE_PROFILES.datingPhoto).toEqual({
      maxSizeMB: 0.4,
      maxWidthOrHeight: 1440,
      initialQuality: 0.8
    });
  });

  it("the existing profiles are unchanged — this extraction moved code, it did not retune it", () => {
    expect(IMAGE_PROFILES.avatar).toEqual({
      maxSizeMB: 0.5,
      maxWidthOrHeight: 512,
      initialQuality: 0.8
    });
    expect(IMAGE_PROFILES.attachment).toEqual({
      maxSizeMB: 1,
      maxWidthOrHeight: 1920,
      initialQuality: 0.8
    });
  });
});

describe("compressImage", () => {
  it("a 4MB camera photo comes back under the dating budget", async () => {
    const out = await compressImage(file(4 * 1024 * 1024), "datingPhoto");

    expect(out.size).toBeLessThanOrEqual(0.4 * 1024 * 1024);
    expect(out.size).toBeLessThan(4 * 1024 * 1024);
  });

  it("passes the named profile through, on a web worker", async () => {
    await compressImage(file(4 * 1024 * 1024), "datingPhoto");

    expect(compress).toHaveBeenCalledTimes(1);
    expect(compress.mock.calls[0][1]).toEqual({
      ...IMAGE_PROFILES.datingPhoto,
      useWebWorker: true
    });
  });

  it("NEVER sets preserveExif — a dating photo must not carry the camera's GPS to strangers", async () => {
    await compressImage(file(1024), "datingPhoto");

    expect(compress.mock.calls[0][1]).not.toHaveProperty("preserveExif");
  });

  it("falls back to the ORIGINAL file when compression fails — large beats not uploading", async () => {
    compress.mockRejectedValueOnce(new Error("canvas is not available"));
    const original = file(4 * 1024 * 1024);

    await expect(compressImage(original, "datingPhoto")).resolves.toBe(original);
  });

  it("a file already under the budget is left alone", async () => {
    const small = file(50 * 1024);
    expect((await compressImage(small, "datingPhoto")).size).toBe(50 * 1024);
  });
});
