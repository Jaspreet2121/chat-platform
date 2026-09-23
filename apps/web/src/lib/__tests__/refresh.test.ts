import { describe, expect, it } from "vitest";
import {
  classifyRefreshResponse,
  createSingleFlight,
  shouldSignOut
} from "../refresh";

describe("createSingleFlight", () => {
  it("collapses concurrent callers into exactly one execution", async () => {
    let calls = 0;
    let release!: (value: string) => void;
    const gate = new Promise<string>((resolve) => {
      release = resolve;
    });

    const single = createSingleFlight(async () => {
      calls += 1;
      return gate;
    });

    // Ten simultaneous 401s, the whole point of the rule: N parallel refreshes of the same token
    // look like REUSE to the server and would sign the user out.
    const all = Promise.all(Array.from({ length: 10 }, () => single()));
    release("token");

    expect(await all).toEqual(Array(10).fill("token"));
    expect(calls).toBe(1);
  });

  it("starts a fresh execution once the previous one has settled", async () => {
    let calls = 0;
    const single = createSingleFlight(async () => {
      calls += 1;
      return calls;
    });

    expect(await single()).toBe(1);
    expect(await single()).toBe(2);
  });

  it("does not wedge the slot shut when a run rejects", async () => {
    let calls = 0;
    const single = createSingleFlight(async () => {
      calls += 1;
      if (calls === 1) throw new Error("network");
      return "ok";
    });

    await expect(single()).rejects.toThrow("network");
    // Without the finally-release, every later refresh would replay the same rejection forever.
    await expect(single()).resolves.toBe("ok");
    expect(calls).toBe(2);
  });

  it("shares the rejection with everyone waiting on the same flight", async () => {
    const single = createSingleFlight(async () => {
      throw new Error("boom");
    });

    const a = single();
    const b = single();
    await expect(a).rejects.toThrow("boom");
    await expect(b).rejects.toThrow("boom");
  });
});

describe("shouldSignOut", () => {
  it("is true for exactly the four server verdicts", () => {
    for (const code of [
      "auth.refresh_expired",
      "auth.refresh_invalid",
      "auth.session_revoked",
      "auth.refresh_reused"
    ]) {
      expect(shouldSignOut(code)).toBe(true);
    }
  });

  it("is false for anything else — an allowlist, not a denylist", () => {
    for (const code of [
      "auth.session_invalid",   // a DIFFERENT code; not a refresh verdict
      "auth.unavailable",       // auth is down — the session is probably fine
      "message.rate_limited",
      "conversations.request_not_found",
      "",
      "AUTH.REFRESH_EXPIRED",   // case matters; we compare exact wire strings
      " auth.refresh_expired",  // whitespace is not trimmed anywhere upstream
      undefined,
      null
    ]) {
      expect(shouldSignOut(code as string | null | undefined)).toBe(false);
    }
  });
});

describe("classifyRefreshResponse", () => {
  it("refreshes on a 2xx carrying an access token", () => {
    expect(classifyRefreshResponse(200, { access_token: "new" })).toEqual({ status: "refreshed" });
  });

  it("treats a 2xx with no access token as transient, not as a sign-out", () => {
    // A proxy returning 200 with an empty body must not destroy the session.
    expect(classifyRefreshResponse(200, {})).toEqual({
      status: "failed",
      reason: "refresh returned no access_token"
    });
  });

  it("signs out on a 401 carrying one of the four codes", () => {
    expect(classifyRefreshResponse(401, { error: { code: "auth.refresh_reused" } })).toEqual({
      status: "signed_out",
      code: "auth.refresh_reused"
    });
  });

  it("does NOT sign out on a 401 with an unrecognised code", () => {
    // A gateway that was not rebuilt alongside auth answers with its own codes. Signing out on those
    // would turn a deploy-ordering mistake into a mass logout.
    const outcome = classifyRefreshResponse(401, { error: { code: "auth.something_new" } });
    expect(outcome.status).toBe("failed");
  });

  it("does NOT sign out on a 5xx, a 400, or an unparseable body", () => {
    for (const [status, body] of [
      [500, null],
      [502, null],
      [503, { error: { code: "auth.unavailable" } }],
      [400, { error: { code: "invalid_request" } }],
      [401, null]
    ] as const) {
      expect(classifyRefreshResponse(status, body).status).toBe("failed");
    }
  });
});
