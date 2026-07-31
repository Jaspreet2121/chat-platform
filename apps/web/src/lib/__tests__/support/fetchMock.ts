import { vi } from "vitest";

/**
 * The single boundary every test stubs: `fetch`. Nothing here touches the network, a real timer, or
 * localStorage beyond what a test sets itself — so the suite is deterministic and runs from a fresh
 * clone with no local state.
 */

export type RecordedCall = {
  url: string;
  method: string;
  headers: Headers;
  /** JSON-decoded request body when it was a JSON string; the raw value otherwise (e.g. a Blob). */
  body: unknown;
};

export type Route = (url: string, init: RequestInit | undefined) => Response | Promise<Response>;

/** Install a routing `fetch` stub. Returns the recorded calls, in order. */
export function installFetch(route: Route): RecordedCall[] {
  const calls: RecordedCall[] = [];

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : String(input);
      calls.push({
        url,
        method: (init?.method ?? "GET").toUpperCase(),
        headers: new Headers(init?.headers),
        body: decodeBody(init?.body)
      });

      return route(url, init);
    })
  );

  return calls;
}

function decodeBody(body: BodyInit | null | undefined): unknown {
  if (typeof body !== "string") return body ?? null;
  try {
    return JSON.parse(body);
  } catch {
    return body;
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204 });
}

/** An API error in the server's envelope shape (`{error: {code, message}}`). */
export function apiError(message: string, status = 400, code = "test.error"): Response {
  return json({ error: { code, message } }, status);
}

/** Fail a request without a JSON body — the "couldn't even parse an envelope" path. */
export function failure(status: number): Response {
  return new Response("nope", { status });
}
