// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { DatingProfile } from "@/lib/api";

/**
 * THE DATING UPLOAD PATH, driven through the real component.
 *
 * Dating photos were the one upload in the app that shipped the camera's original bytes — a 4 MB
 * photo PUT byte-for-byte, ~3.0s to paint. This renders the REAL DatingSetup and drops a 4 MB file
 * on its file input, so the assertion is about what actually reaches the uploader: bypassing
 * compression anywhere between the input handler and uploadMediaBlob turns it red.
 */

const compress = vi.hoisted(() => vi.fn());
const uploadMediaBlob = vi.hoisted(() => vi.fn());

vi.mock("browser-image-compression", () => ({ default: compress }));
vi.mock("@/lib/upload", () => ({ uploadMediaBlob }));
vi.mock("@/lib/api", async () => {
  const actual = await vi.importActual<typeof import("@/lib/api")>("@/lib/api");
  return { ...actual, updateDatingProfile: vi.fn() };
});

import { DatingSetup } from "@/components/dating/DatingSetup";
import { IMAGE_PROFILES } from "@/lib/imageCompression";

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const ORIGINAL_BYTES = 4 * 1024 * 1024;

const PROFILE: DatingProfile = {
  enabled: true,
  dob: "1996-04-02",
  age: 30,
  gender: "woman",
  interested_in: ["man"],
  intention: "relationship",
  turn_ons: [],
  bio: "hi",
  photos: [],
  location: { lat: 12.9, lng: 77.6, name: "Bengaluru" },
  prefs: {
    min_age: 18,
    max_age: 50,
    max_distance_km: 50,
    genders: ["man"],
    intentions: [],
    require_shared_turn_on: false
  }
};

function fileOf(bytes: number, name = "IMG_4021.HEIC-ish.jpg"): File {
  return new File([new Uint8Array(bytes)], name, { type: "image/jpeg" });
}

let container: HTMLDivElement;
let root: Root;

beforeEach(async () => {
  compress.mockReset();
  uploadMediaBlob.mockReset();
  // Honours the byte budget it is handed, so the size assertion below measures the REAL profile.
  compress.mockImplementation(async (input: File, options: { maxSizeMB: number }) =>
    fileOf(Math.min(input.size, options.maxSizeMB * 1024 * 1024))
  );
  uploadMediaBlob.mockResolvedValue({ mediaId: "media-1", objectKey: "k" });
  URL.createObjectURL = vi.fn(() => "blob:preview");
  URL.revokeObjectURL = vi.fn();

  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  await act(async () => {
    root.render(
      createElement(DatingSetup, { profile: PROFILE, catalog: null, onSaved: () => undefined })
    );
  });
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

async function choosePhoto(file: File) {
  const input = container.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) throw new Error("the dating setup renders no file input");
  Object.defineProperty(input, "files", {
    configurable: true,
    value: { 0: file, length: 1, item: (i: number) => (i === 0 ? file : null) }
  });
  await act(async () => {
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("adding a dating photo", () => {
  it("COMPRESSES before upload — a 4MB camera photo does not go out byte-for-byte", async () => {
    await choosePhoto(fileOf(ORIGINAL_BYTES));

    expect(uploadMediaBlob).toHaveBeenCalledTimes(1);
    const sent = uploadMediaBlob.mock.calls[0][0].blob as File;

    expect(sent.size).toBeLessThanOrEqual(IMAGE_PROFILES.datingPhoto.maxSizeMB * 1024 * 1024);
    expect(sent.size).toBeLessThan(ORIGINAL_BYTES);
  });

  it("uses the DATING profile, not the avatar one — a card is viewed far larger than a tile", async () => {
    await choosePhoto(fileOf(ORIGINAL_BYTES));

    expect(compress).toHaveBeenCalledTimes(1);
    expect(compress.mock.calls[0][1]).toMatchObject({
      maxWidthOrHeight: IMAGE_PROFILES.datingPhoto.maxWidthOrHeight,
      maxSizeMB: IMAGE_PROFILES.datingPhoto.maxSizeMB
    });
  });

  it("uploads as a user_avatar asset with the ORIGINAL filename, exactly as before", async () => {
    await choosePhoto(fileOf(ORIGINAL_BYTES, "beach.jpg"));

    expect(uploadMediaBlob.mock.calls[0][0]).toMatchObject({
      filename: "beach.jpg",
      purpose: "user_avatar",
      contentType: "image/jpeg"
    });
  });

  it("still uploads when compression fails — the original is the fallback, never a dropped photo", async () => {
    compress.mockRejectedValueOnce(new Error("no canvas"));
    await choosePhoto(fileOf(ORIGINAL_BYTES));

    expect(uploadMediaBlob).toHaveBeenCalledTimes(1);
    expect((uploadMediaBlob.mock.calls[0][0].blob as File).size).toBe(ORIGINAL_BYTES);
  });
});
