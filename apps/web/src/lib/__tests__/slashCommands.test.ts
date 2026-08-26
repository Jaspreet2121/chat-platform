// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetCommandsCache, fetchCommands, type QuickReply, type SlashCommand, type UserProfile } from "@/lib/api";
import {
  commandAvailable,
  filterItems,
  pickerItems,
  qrCaption,
  resolveTemplate,
  slashFragment
} from "@/lib/slashCommands";
import { quickReplyError, validateQuickReply } from "@/lib/quickReplies";
import { installFetch } from "./support/fetchMock";

/**
 * The "/" palette (100). The gating rules matter more than the rendering: offering a command whose
 * required profile field is unset would send a message containing a literal "{upi_id}".
 */

const COMMANDS: SlashCommand[] = [
  { name: "qr", kind: "action", label: "Send my UPI QR", requires: "upi_id" },
  { name: "pay", kind: "text", template: "Pay me on UPI: {upi_id}", requires: "upi_id" },
  { name: "location", kind: "action", label: "Share live location" },
  { name: "website", kind: "text", template: "{website}", requires: "website" },
  { name: "contact", kind: "action", label: "Send my contact card" }
];

const profile = (over: Partial<UserProfile> = {}): UserProfile => ({
  user_id: "u1",
  ...over
});

const reply = (shortcut: string, body: string): QuickReply => ({
  id: `id-${shortcut}`,
  shortcut,
  body,
  position: 0
});

afterEach(() => vi.unstubAllGlobals());

describe("slash fragment detection", () => {
  it("opens on a leading '/' and tracks what follows", () => {
    expect(slashFragment("/")).toBe("");
    expect(slashFragment("/pa")).toBe("pa");
  });

  it("closes once the token ends or the draft isn't slash-led", () => {
    // A space means the user is writing a message, not choosing a command.
    expect(slashFragment("/pay now")).toBeNull();
    expect(slashFragment("hello")).toBeNull();
    expect(slashFragment("say /pay")).toBeNull();
    expect(slashFragment("")).toBeNull();
  });
});

describe("requires-gating", () => {
  it("hides a command whose required profile field is unset", () => {
    expect(commandAvailable(COMMANDS[1], profile())).toBe(false);
    expect(commandAvailable(COMMANDS[1], profile({ upi_id: "me@bank" }))).toBe(true);
  });

  it("treats a blank field as unset", () => {
    expect(commandAvailable(COMMANDS[1], profile({ upi_id: "   " }))).toBe(false);
  });

  it("an ungated command is always available", () => {
    expect(commandAvailable(COMMANDS[2], profile())).toBe(true);
  });

  it("the picker drops gated-out commands, and actions this client can't perform", () => {
    const names = pickerItems(COMMANDS, [], profile()).map((item) => item.name);

    // No upi_id → no /qr, no /pay. /contact has no web implementation, so it is not offered either.
    expect(names).not.toContain("qr");
    expect(names).not.toContain("pay");
    expect(names).not.toContain("contact");
    expect(names).toContain("location");
  });

  it("with the profile filled in, the gated commands appear", () => {
    const names = pickerItems(COMMANDS, [], profile({ upi_id: "me@bank" })).map((i) => i.name);
    expect(names).toContain("qr");
    expect(names).toContain("pay");
  });
});

describe("template resolution", () => {
  it("fills placeholders from the caller's own profile", () => {
    expect(resolveTemplate("Pay me on UPI: {upi_id}", profile({ upi_id: "me@bank" }))).toBe(
      "Pay me on UPI: me@bank"
    );
  });

  it("returns null when a placeholder can't be resolved — never a literal {upi_id}", () => {
    expect(resolveTemplate("Pay me on UPI: {upi_id}", profile())).toBeNull();
    expect(resolveTemplate("{website}", profile({ upi_id: "me@bank" }))).toBeNull();
  });

  it("the /qr caption is locked to the documented wording", () => {
    expect(qrCaption(profile({ upi_id: "me@bank" }))).toBe("Pay me on UPI: me@bank");
  });
});

describe("picker filtering", () => {
  const items = () =>
    pickerItems(COMMANDS, [reply("thanks", "Thank you!"), reply("price", "₹500")], profile({ upi_id: "me@bank" }));

  it("prefix-matches by name, case-insensitively", () => {
    expect(filterItems(items(), "pa").map((i) => i.name)).toEqual(["pay"]);
    expect(filterItems(items(), "PA").map((i) => i.name)).toEqual(["pay"]);
  });

  it("matches the user's own quick replies too", () => {
    const names = filterItems(items(), "th").map((i) => i.name);
    expect(names).toEqual(["thanks"]);
  });

  it("an empty fragment shows commands first, then quick replies", () => {
    const all = filterItems(items(), "");
    expect(all[0].source).toBe("command");
    expect(all.at(-1)).toMatchObject({ source: "quick_reply", name: "price" });
  });

  it("a fragment matching nothing yields an empty list (the picker then hides)", () => {
    expect(filterItems(items(), "zzz")).toEqual([]);
  });
});

describe("commands ETag cache", () => {
  beforeEach(() => __resetCommandsCache());

  // The real server always sends a strong ETag on this route; the mock must too, since caching is
  // conditional on it (a server that sent none would simply never be cached — also correct).
  const withEtag = (etag: string) =>
    new Response(JSON.stringify({ commands: COMMANDS }), {
      status: 200,
      headers: { "Content-Type": "application/json", etag }
    });

  it("caches on the first 200, then sends If-None-Match and reuses the body on a 304", async () => {
    const calls = installFetch((_url, init) => {
      const inm = new Headers(init?.headers).get("If-None-Match");
      if (inm === '"abc"') return new Response(null, { status: 304, headers: { etag: '"abc"' } });
      return withEtag('"abc"');
    });

    const first = await fetchCommands();
    expect(first).toHaveLength(COMMANDS.length);
    expect(calls[0].headers.get("If-None-Match")).toBeNull();

    // Second call rides the cached etag and gets a bodiless 304 — the list still resolves.
    const second = await fetchCommands();
    expect(calls[1].headers.get("If-None-Match")).toBe('"abc"');
    expect(second).toHaveLength(COMMANDS.length);
  });

  it("a failed refresh falls back to the cached list rather than breaking the composer", async () => {
    installFetch(() => withEtag('"abc"'));
    await fetchCommands();

    vi.unstubAllGlobals();
    installFetch(() => new Response("nope", { status: 500 }));
    await expect(fetchCommands()).resolves.toHaveLength(COMMANDS.length);
  });
});

describe("quick reply validation", () => {
  it("accepts a well-formed shortcut", () => {
    expect(validateQuickReply("thanks_1", "Thank you!")).toBeNull();
  });

  it("refuses spaces, slashes, uppercase and over-length shortcuts", () => {
    expect(validateQuickReply("two words", "x")).toContain("lowercase");
    expect(validateQuickReply("/thanks", "x")).toContain("lowercase");
    expect(validateQuickReply("a".repeat(26), "x")).toContain("lowercase");
    expect(validateQuickReply("", "x")).toBe("Give it a shortcut.");
  });

  it("refuses a RESERVED built-in shortcut before the server 409s", () => {
    expect(validateQuickReply("qr", "x")).toContain("built-in");
    expect(validateQuickReply("pay", "x")).toContain("built-in");
  });

  it("requires a body, and caps it at 1000 characters", () => {
    expect(validateQuickReply("ok", "   ")).toContain("message");
    expect(validateQuickReply("ok", "x".repeat(1001))).toContain("1000");
  });

  it("maps the server's reserved 409 to fixable copy", () => {
    expect(quickReplyError("quick_reply.reserved", "raw")).toContain("built-in");
    expect(quickReplyError("quick_reply.taken", "raw")).toContain("already use");
    // An unrecognised code keeps the server's own message rather than inventing one.
    expect(quickReplyError("something.else", "raw")).toBe("raw");
  });
});
