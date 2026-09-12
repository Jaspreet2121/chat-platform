// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Message } from "@/lib/api";
import type { DecryptOutcome } from "@/lib/e2ee/secretChat";

/**
 * The bubble LAYOUT CONTRACT, pinned on the real MessageList → MessageBubble render.
 *
 * jsdom does no layout, so these tests pin the CSS structure that produced the bug rather than pixel
 * widths (the browser check does the pixels): a bubble is capped at a PERCENTAGE of its column, and a
 * percentage only means what it says when nothing between the bubble and the scroll container
 * shrink-wraps the row to its own text. `items-end` on the run column did exactly that — "hiii" got a
 * bubble narrower than its own timestamp — and the meta line then wrapped because nothing said it
 * couldn't.
 */

vi.mock("@/lib/api", () => ({ getMediaDownloadUrl: vi.fn() }));
vi.mock("@/components/chat/useUserProfile", () => ({
  useUserProfile: () => null,
  primeUserProfile: () => undefined
}));
vi.mock("next/dynamic", () => ({ default: () => () => null }));
vi.mock("next/link", async () => {
  const React = await import("react");
  return { default: (props: Record<string, unknown>) => React.createElement("a", props) };
});
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: () => undefined, replace: () => undefined }),
  usePathname: () => "/chat",
  useSearchParams: () => new URLSearchParams()
}));

import { MessageList } from "@/components/chat/MessageList";

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const ME = "me";
const PEER = "peer";

function msg(id: string, sender: string, extra: Partial<Message> = {}): Message {
  return {
    conversation_id: "c1",
    message_id: id,
    sender_user_id: sender,
    message_type: "text",
    body: id,
    status: "sent",
    created_at: "2026-09-12T13:52:00Z",
    ...extra
  };
}

const MESSAGES: Message[] = [
  msg("hiii", ME, { delivered_by_count: 1 }),
  msg("hgyf", PEER),
  msg("sealed-own", ME, { message_type: "sealed", body: null, read_by_count: 1 }),
  msg("sealed-peer", PEER, { message_type: "sealed", body: null })
];

const SEALED = new Map<string, DecryptOutcome>([
  ["sealed-own", { ok: true, kind: "text", body: "hufrtfygu", senderDeviceId: "web-a" }],
  ["sealed-peer", { ok: true, kind: "text", body: "one sealed reply", senderDeviceId: "web-b" }]
]);

let container: HTMLDivElement;
let root: Root;

beforeEach(async () => {
  Element.prototype.scrollTo = () => undefined;
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  await act(async () => {
    root.render(
      createElement(MessageList, {
        messages: MESSAGES,
        isDirect: true,
        currentUserId: ME,
        isLoading: false,
        hasConversation: true,
        onEdit: async () => undefined,
        onDelete: async () => undefined,
        sealedDecryptions: SEALED
      })
    );
  });
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

function surfaceOf(text: string): HTMLElement {
  const p = [...container.querySelectorAll("p")].find((el) => el.textContent?.includes(text));
  if (!p?.parentElement) throw new Error(`no bubble renders "${text}"`);
  return p.parentElement;
}

function percentBoxOf(surface: HTMLElement): HTMLElement {
  let el: HTMLElement | null = surface;
  while (el && !/max-w-\[\d+%\]/.test(el.className)) el = el.parentElement;
  if (!el) throw new Error("no percentage-capped box above the bubble surface");
  return el;
}

/**
 * THE ROOT CAUSE, as a predicate. Returns the offending class list when something between the
 * percentage-capped box and the scroll container would size it against its own text instead of
 * the column: a row that isn't full width, a row that aligns itself, or a flex column above it
 * that un-stretches its children.
 */
function shrinkWrapOffender(surface: HTMLElement): string | null {
  const row = percentBoxOf(surface).parentElement!;
  if (!/\bw-full\b/.test(row.className)) return `row is not full width: "${row.className}"`;
  if (/\bself-(start|end|center)\b/.test(row.className)) return `row aligns itself: "${row.className}"`;
  let el = row.parentElement;
  while (el && !/\boverflow-y-auto\b/.test(el.className)) {
    if (/\bflex-col\b/.test(el.className) && /\bitems-(start|end|center|baseline)\b/.test(el.className)) {
      return `a column above the bubble un-stretches its children: "${el.className}"`;
    }
    el = el.parentElement;
  }
  return null;
}

describe("bubble width — sized against the COLUMN, never against its own text", () => {
  it.each(["hiii", "hgyf", "hufrtfygu", "one sealed reply"])(
    "a short message (%s) is not shrink-wrapped",
    (text) => {
      const surface = surfaceOf(text);
      expect(percentBoxOf(surface).className).toMatch(/max-w-\[78%\]/);
      expect(shrinkWrapOffender(surface)).toBeNull();
    }
  );

  it("own messages sit on the right by reversing the FULL-WIDTH row, not by aligning a narrow one", () => {
    const ownRow = percentBoxOf(surfaceOf("hiii")).parentElement!;
    const peerRow = percentBoxOf(surfaceOf("hgyf")).parentElement!;
    expect(ownRow.className).toMatch(/\bflex-row-reverse\b/);
    expect(peerRow.className).toMatch(/\bflex-row\b/);
    expect(peerRow.className).not.toMatch(/\bflex-row-reverse\b/);
  });
});

describe("the meta line (time + ticks + lock) never wraps", () => {
  it.each(["hiii", "hgyf", "hufrtfygu", "one sealed reply"])("%s: stamp is nowrap, icons never shrink", (text) => {
    const stamp = surfaceOf(text).querySelector<HTMLElement>("[data-stamp]");
    expect(stamp, "stamp rendered inside the bubble").not.toBeNull();
    expect(stamp!.textContent).toMatch(/\d{2}:\d{2}/);
    expect(stamp!.className).toMatch(/\bwhitespace-nowrap\b/);
    const icons = [...stamp!.querySelectorAll("svg")];
    for (const icon of icons) expect(icon.getAttribute("class")).toMatch(/\bshrink-0\b/);
  });

  it("own messages carry a tick in the stamp; the sealed own one shows the read tick", () => {
    expect(surfaceOf("hiii").querySelector("[data-stamp] [aria-label='Delivered']")).not.toBeNull();
    expect(surfaceOf("hufrtfygu").querySelector("[data-stamp] [aria-label='Read']")).not.toBeNull();
    expect(surfaceOf("hgyf").querySelector("[data-stamp] [aria-label]")).toBeNull();
  });
});

describe("sealed and plain bubbles share ONE chrome", () => {
  it("an own sealed bubble has exactly the classes of an own plain bubble", () => {
    expect(surfaceOf("hufrtfygu").className).toBe(surfaceOf("hiii").className);
    expect(surfaceOf("hiii").className).toMatch(/\bbubble-own-gradient\b/);
    expect(surfaceOf("hiii").className).toMatch(/rounded-\[18px\]/);
    expect(surfaceOf("hiii").className).toMatch(/rounded-br-\[5px\]/);
  });

  it("a peer's sealed bubble has exactly the classes of a peer's plain bubble", () => {
    expect(surfaceOf("one sealed reply").className).toBe(surfaceOf("hgyf").className);
    expect(surfaceOf("hgyf").className).toMatch(/rounded-bl-\[5px\]/);
    expect(surfaceOf("hgyf").className).not.toMatch(/\bbubble-own-gradient\b/);
  });

  it("the only visible difference is the lock badge, at full size, inside the stamp", () => {
    const lock = surfaceOf("hufrtfygu").querySelector<SVGElement>("[data-stamp] [aria-label='Encrypted']");
    expect(lock).not.toBeNull();
    expect(lock!.getAttribute("class")).toMatch(/\bshrink-0\b/);
    expect(surfaceOf("hiii").querySelector("[aria-label='Encrypted']")).toBeNull();
  });
});
