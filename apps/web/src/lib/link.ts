import { request } from "./api";

// QR device linking (backend 1fb5f13): the browser mints an anonymous link request, renders its QR,
// and long-polls until the PHONE approves. Security posture on this side: link_id/poll_token live in
// component state only (never persisted, never in URLs the app navigates to, never logged), and the
// QR is re-minted per visit/expiry.

export type LinkQr = {
  link_id: string;
  qr_payload: string;
  expires_in: number;
  poll_token: string;
};

export type LinkedSession = {
  access_token: string;
  refresh_token: string;
  expires_at: string;
  session_id: string;
};

export type LinkWaitResult = {
  state: "pending" | "approved" | "consumed" | "expired";
  session?: LinkedSession;
};

export function createLinkQr(): Promise<LinkQr> {
  return request<LinkQr>("/api/v1/link/qr", { method: "POST" });
}

export function waitLink(
  linkId: string,
  pollToken: string,
  signal?: AbortSignal
): Promise<LinkWaitResult> {
  const params = new URLSearchParams({ poll_token: pollToken });
  return request<LinkWaitResult>(
    `/api/v1/link/qr/${encodeURIComponent(linkId)}/wait?${params.toString()}`,
    { signal }
  );
}

export type PollOutcome =
  | { status: "approved"; session: LinkedSession }
  | { status: "refresh" } // consumed/expired — mint a new code
  | { status: "cancelled" }; // aborted (unmount / tab hidden / expiry timer)

type PollDeps = {
  wait?: typeof waitLink;
  sleep?: (ms: number) => Promise<void>;
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

// The poll loop: each request long-polls ≤25s server-side; `pending` re-polls immediately, network
// errors back off 2s→10s (doubling), consumed/expired ask the caller to mint a fresh code, and an
// abort resolves to `cancelled` (never throws — unmount must be quiet).
export async function pollUntilResolved(
  linkId: string,
  pollToken: string,
  signal: AbortSignal,
  deps: PollDeps = {}
): Promise<PollOutcome> {
  const wait = deps.wait ?? waitLink;
  const sleep = deps.sleep ?? defaultSleep;
  let backoffMs = 2_000;

  for (;;) {
    if (signal.aborted) return { status: "cancelled" };

    try {
      const result = await wait(linkId, pollToken, signal);
      backoffMs = 2_000;

      if (result.state === "approved" && result.session) {
        return { status: "approved", session: result.session };
      }

      if (result.state === "consumed" || result.state === "expired") {
        return { status: "refresh" };
      }

      // "pending" (the ≤25s window elapsed server-side) → immediately poll again.
    } catch (error) {
      if (signal.aborted) return { status: "cancelled" };
      // Network hiccup: back off 2–10s, then keep waiting for the phone.
      void error;
      await sleep(backoffMs);
      backoffMs = Math.min(backoffMs * 2, 10_000);
    }
  }
}
