// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { DatingProfile } from "@/lib/api";
import { photoEntries } from "@/lib/dating";

/**
 * THE EDITOR'S OWN PHOTOS — rendered from the server's presigned photo_urls, and PATCHed back as ids.
 *
 * The profile read returned ids with no URLs, so every saved photo drew an empty "Photo N" tile and
 * the screen issued no media request at all. Two things have to hold together: the tiles render the
 * right URL in the right slot, and the round-trip still sends IDS — sending a URL where an id belongs
 * would fail ownership validation on the next save.
 */

const uploadMediaBlob = vi.hoisted(() => vi.fn());
const updateDatingProfile = vi.hoisted(() => vi.fn());

vi.mock("browser-image-compression", () => ({ default: vi.fn(async (f: File) => f) }));
vi.mock("@/lib/upload", () => ({ uploadMediaBlob }));
vi.mock("@/lib/api", async () => {
  const actual = await vi.importActual<typeof import("@/lib/api")>("@/lib/api");
  return { ...actual, updateDatingProfile };
});

import { DatingSetup } from "@/components/dating/DatingSetup";

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const ID_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const ID_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const URL_A = "https://media.growblic.com/chat-media/a.jpg?X-Amz-Expires=7200";
const URL_B = "https://media.growblic.com/chat-media/b.jpg?X-Amz-Expires=7200";

function profileWith(overrides: Partial<DatingProfile> = {}): DatingProfile {
  return {
    enabled: true,
    dob: "1996-04-02",
    age: 30,
    gender: "woman",
    interested_in: ["man"],
    intention: "relationship",
    turn_ons: [],
    bio: "hi",
    photos: [ID_A, ID_B],
    photo_urls: [URL_A, URL_B],
    location: { lat: 12.9, lng: 77.6, name: "Bengaluru" },
    prefs: {
      min_age: 18,
      max_age: 50,
      max_distance_km: 50,
      genders: ["man"],
      intentions: [],
      require_shared_turn_on: false
    },
    ...overrides
  };
}

let container: HTMLDivElement;
let root: Root;

async function render(profile: DatingProfile) {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  await act(async () => {
    root.render(createElement(DatingSetup, { profile, catalog: null, onSaved: () => undefined }));
  });
}

function tileSources(): (string | null)[] {
  return [...container.querySelectorAll("img")].map((img) => img.getAttribute("src"));
}

async function clickSave() {
  const button = [...container.querySelectorAll("button")].find(
    (b) => b.textContent?.trim() === "Save changes"
  );
  if (!button) throw new Error("no Save button rendered");
  await act(async () => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

beforeEach(() => {
  uploadMediaBlob.mockReset();
  updateDatingProfile.mockReset();
  updateDatingProfile.mockResolvedValue(profileWith());
  URL.createObjectURL = vi.fn(() => "blob:local-preview");
  URL.revokeObjectURL = vi.fn();
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

describe("rendering saved photos", () => {
  it("draws every saved photo from its presigned URL — not an empty placeholder", async () => {
    await render(profileWith());

    expect(tileSources()).toEqual([URL_A, URL_B]);
  });

  it("keeps URL and id in the SAME slot: the second photo's URL renders second", async () => {
    // Reversed ids AND urls: slot order follows the server's list, not any id-based guess.
    await render(profileWith({ photos: [ID_B, ID_A], photo_urls: [URL_B, URL_A] }));

    expect(tileSources()).toEqual([URL_B, URL_A]);
  });

  it("falls back to a placeholder when the server sends no URL for a slot", async () => {
    await render(profileWith({ photo_urls: [null, URL_B] }));

    expect(tileSources()).toEqual([URL_B]);
    expect(container.textContent).toContain("Photo 1");
  });

  it("an older gateway that omits photo_urls still renders — placeholders, as before", async () => {
    await render(profileWith({ photo_urls: undefined }));

    expect(tileSources()).toEqual([]);
    expect(container.textContent).toContain("Photo 1");
  });
});

describe("the save round-trip", () => {
  it("PATCHes the photo IDS, never the URLs it renders", async () => {
    await render(profileWith());
    await clickSave();

    expect(updateDatingProfile).toHaveBeenCalledTimes(1);
    const body = updateDatingProfile.mock.calls[0][0];

    expect(body.photos).toEqual([ID_A, ID_B]);

    for (const value of body.photos as string[]) {
      expect(value).not.toMatch(/^https?:/);
      expect(value).not.toMatch(/^blob:/);
    }
  });

  it("re-seeds the tiles from the PATCH response, so a save leaves no stale slot", async () => {
    await render(profileWith());

    // The server answers with a different order (another device reordered between load and save).
    updateDatingProfile.mockResolvedValue(
      profileWith({ photos: [ID_B, ID_A], photo_urls: [URL_B, URL_A] })
    );
    await clickSave();

    expect(tileSources()).toEqual([URL_B, URL_A]);
  });
});

describe("photoEntries — the zip itself", () => {
  it("pairs by INDEX, and keeps a session-local preview the server could not presign", () => {
    const current = [{ mediaId: ID_B, preview: "blob:just-uploaded" }];

    expect(photoEntries({ photos: [ID_A, ID_B], photo_urls: [URL_A, null] }, current)).toEqual([
      { mediaId: ID_A, preview: URL_A },
      { mediaId: ID_B, preview: "blob:just-uploaded" }
    ]);
  });

  it("an empty profile is an empty list, never a crash", () => {
    expect(photoEntries({})).toEqual([]);
    expect(photoEntries({ photos: [] })).toEqual([]);
  });
});
