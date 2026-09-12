import { describe, expect, it } from "vitest";
import { sendFailureMessage } from "@/lib/sendError";

/**
 * The backend uses ONE sentence for every 429 — "Too many requests. Please try again later." — and
 * the API layer renders `error.message` verbatim. A sealed send fetches the device-key registry
 * first, so a throttled `keys.rate_limited` told the user that SENDING was throttled. It was not:
 * the send limiter is 60/min and fail-OPEN, and had not been consulted. Same words, wrong cause.
 */

const apiError = (code: string, message = "Too many requests. Please try again later.") =>
  Object.assign(new Error(message), { code, status: 429 });

describe("sendFailureMessage", () => {
  it("a throttled KEY FETCH does not claim sending is throttled", () => {
    const text = sendFailureMessage(apiError("keys.rate_limited"));

    expect(text).not.toBe("Too many requests. Please try again later.");
    expect(text).toMatch(/encryption keys/i);
    // The user must not be told to stop sending — that was never the limit that rejected.
    expect(text).not.toMatch(/sending too quickly/i);
  });

  it("a degraded key limiter (503) reads as unavailable, not as a rate limit", () => {
    const text = sendFailureMessage(apiError("keys.unavailable", "Service unavailable"));
    expect(text).toMatch(/keys are unavailable/i);
  });

  it("the REAL send limiter says so, and says it plainly", () => {
    const text = sendFailureMessage(apiError("message.rate_limited"));
    expect(text).toMatch(/sending too quickly/i);
    expect(text).not.toMatch(/encryption keys/i);
  });

  it("anything else keeps the server's own wording", () => {
    expect(sendFailureMessage(apiError("message.media_invalid", "That attachment isn't valid."))).toBe(
      "That attachment isn't valid."
    );
    expect(sendFailureMessage(new Error("Network request failed"))).toBe("Network request failed");
  });

  it("a non-Error value still produces something sayable", () => {
    expect(sendFailureMessage("boom")).toBe("Message send failed.");
    expect(sendFailureMessage(undefined)).toBe("Message send failed.");
  });
});
