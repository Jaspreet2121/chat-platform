// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Message } from "@/lib/api";
import { useReceiptReporter, type ReceiptChannel } from "@/components/chat/useReceiptReporter";

/**
 * The hook is what page.tsx mounts, so these tests exercise the REAL wiring the chat page uses —
 * a host component rendered with react-dom, not a re-implementation of the rules.
 */

(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

type Props = {
  channel: ReceiptChannel | null;
  messages: Message[];
  selfUserId: string | undefined;
  conversationId: string;
};

function Host(props: Props) {
  useReceiptReporter(props);
  return null;
}

function msg(id: string, sender: string): Message {
  return {
    conversation_id: "c1",
    message_id: id,
    sender_user_id: sender,
    message_type: "text",
    status: "sent",
    created_at: "2026-09-12T00:00:00Z"
  };
}

function fakeChannel() {
  return {
    markDeliveredBatch: vi.fn().mockResolvedValue({}),
    markReadBatch: vi.fn().mockResolvedValue({})
  };
}

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

async function render(props: Props) {
  await act(async () => {
    root.render(createElement(Host, props));
  });
  // Let the chunked pushes (sequential awaits) drain.
  await act(async () => {
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("useReceiptReporter — the chat page's receipt wiring", () => {
  it("a 50-message backfill is ONE delivered push and ONE read push, not fifty of each", async () => {
    const channel = fakeChannel();
    const rows = Array.from({ length: 50 }, (_, i) => msg(`m${i}`, "peer"));
    await render({ channel, messages: rows, selfUserId: "me", conversationId: "c1" });

    expect(channel.markDeliveredBatch).toHaveBeenCalledTimes(1);
    expect(channel.markDeliveredBatch.mock.calls[0][0]).toHaveLength(50);
    expect(channel.markReadBatch).toHaveBeenCalledTimes(1);
    expect(channel.markReadBatch.mock.calls[0][0]).toHaveLength(50);
  });

  it("delivered goes out BEFORE read, so the sender's tick progresses grey → blue", async () => {
    const order: string[] = [];
    const channel: ReceiptChannel = {
      markDeliveredBatch: vi.fn(async () => {
        order.push("delivered");
      }),
      markReadBatch: vi.fn(async () => {
        order.push("read");
      })
    };
    await render({ channel, messages: [msg("m1", "peer")], selfUserId: "me", conversationId: "c1" });
    expect(order).toEqual(["delivered", "read"]);
  });

  it("never reports your OWN messages", async () => {
    const channel = fakeChannel();
    const rows = [msg("mine", "me"), msg("theirs", "peer"), msg("mine2", "me")];
    await render({ channel, messages: rows, selfUserId: "me", conversationId: "c1" });

    expect(channel.markDeliveredBatch).toHaveBeenCalledTimes(1);
    expect(channel.markDeliveredBatch).toHaveBeenCalledWith(["theirs"]);
    expect(channel.markReadBatch).toHaveBeenCalledWith(["theirs"]);
  });

  it("reports once: re-rendering with the same rows pushes nothing; a live arrival pushes only itself", async () => {
    const channel = fakeChannel();
    const rows = [msg("m1", "peer"), msg("m2", "peer")];
    await render({ channel, messages: rows, selfUserId: "me", conversationId: "c1" });
    expect(channel.markReadBatch).toHaveBeenCalledTimes(1);

    // Same rows, new array identity (what every setMessages does) → nothing re-reported.
    await render({ channel, messages: [...rows], selfUserId: "me", conversationId: "c1" });
    expect(channel.markDeliveredBatch).toHaveBeenCalledTimes(1);
    expect(channel.markReadBatch).toHaveBeenCalledTimes(1);

    // A live arrival (mergeMessage appends) → exactly one more push, naming only the new id.
    await render({
      channel,
      messages: [...rows, msg("m3", "peer")],
      selfUserId: "me",
      conversationId: "c1"
    });
    expect(channel.markDeliveredBatch).toHaveBeenCalledTimes(2);
    expect(channel.markDeliveredBatch.mock.calls[1][0]).toEqual(["m3"]);
    expect(channel.markReadBatch.mock.calls[1][0]).toEqual(["m3"]);
  });

  it("the BACKFILL path reports: rows present at first render are delivered, not just live arrivals", async () => {
    const channel = fakeChannel();
    // A thread opened with 3 unread already in the timeline — nothing "arrived live".
    const backfill = [msg("old1", "peer"), msg("old2", "peer"), msg("old3", "peer")];
    await render({ channel, messages: backfill, selfUserId: "me", conversationId: "c1" });
    expect(channel.markDeliveredBatch).toHaveBeenCalledWith(["old1", "old2", "old3"]);
  });

  it("a 300-message backfill chunks into 3 pushes of 100", async () => {
    const channel = fakeChannel();
    const rows = Array.from({ length: 300 }, (_, i) => msg(`m${i}`, "peer"));
    await render({ channel, messages: rows, selfUserId: "me", conversationId: "c1" });
    expect(channel.markDeliveredBatch).toHaveBeenCalledTimes(3);
    expect(channel.markDeliveredBatch.mock.calls.map((c) => c[0].length)).toEqual([100, 100, 100]);
    expect(channel.markReadBatch).toHaveBeenCalledTimes(3);
  });

  it("switching threads resets the dedupe, so the new thread's rows are reported", async () => {
    const channel = fakeChannel();
    await render({ channel, messages: [msg("m1", "peer")], selfUserId: "me", conversationId: "c1" });
    await render({ channel, messages: [msg("m1", "peer")], selfUserId: "me", conversationId: "c2" });
    expect(channel.markReadBatch).toHaveBeenCalledTimes(2);
  });

  it("pushes nothing without a channel or a session", async () => {
    const channel = fakeChannel();
    await render({ channel: null, messages: [msg("m1", "peer")], selfUserId: "me", conversationId: "c1" });
    await render({ channel, messages: [msg("m1", "peer")], selfUserId: undefined, conversationId: "c1" });
    expect(channel.markReadBatch).not.toHaveBeenCalled();
  });
});
