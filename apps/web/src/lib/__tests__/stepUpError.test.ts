import { describe, expect, it } from "vitest";
import { ApiRequestError } from "@/lib/api";
import { describeStepUpFailure } from "@/lib/stepUpError";

describe("describeStepUpFailure", () => {
  it("says 'that code didn't work' ONLY when the server refused the code", () => {
    const r = describeStepUpFailure(new ApiRequestError("nope", 403, "admin.reauth_failed"));
    expect(r.message).toBe("That code didn't work. Request a new one.");
    expect(r.retryable).toBe(true);
  });

  it("shows the server's code and message for any other 403", () => {
    // A 403 that is NOT a refused code is a different problem entirely — permission, or a plug in
    // the wrong place — and calling it a wrong code is how an outage looks like a typo.
    const r = describeStepUpFailure(
      new ApiRequestError("Requires permission: users.moderate", 403, "admin.forbidden")
    );
    expect(r.message).toBe("Requires permission: users.moderate (admin.forbidden)");
    expect(r.retryable).toBe(false);
  });

  it("names the 400 the server gives an admin with no phone on file", () => {
    const r = describeStepUpFailure(
      new ApiRequestError("No phone number on this account", 400, "admin.reauth_no_destination")
    );
    expect(r.message).toContain("admin.reauth_no_destination");
    expect(r.code).toBe("admin.reauth_no_destination");
  });

  it("treats 429 as 'wait', with the code visible", () => {
    const r = describeStepUpFailure(new ApiRequestError("rate limited", 429, "otp.rate_limited"));
    expect(r.message).toMatch(/wait a minute/);
    expect(r.message).toContain("otp.rate_limited");
  });

  it("labels 5xx as a server failure and keeps the code", () => {
    const r = describeStepUpFailure(new ApiRequestError("Auth unavailable", 503, "admin.unavailable"));
    expect(r.message).toContain("could not complete");
    expect(r.message).toContain("admin.unavailable");
    expect(r.code).toBe("admin.unavailable");
  });

  it("falls back to the HTTP status as a code when the server sent none", () => {
    const r = describeStepUpFailure(new ApiRequestError("Request failed with 502", 502));
    expect(r.code).toBe("http.502");
  });

  it("recognises a request that never reached the server", () => {
    const r = describeStepUpFailure(new TypeError("Failed to fetch"));
    expect(r.code).toBe("network");
    expect(r.message).toMatch(/never reached the server/);
  });

  it("never throws on something that is not an Error", () => {
    expect(describeStepUpFailure("weird")).toEqual({
      message: "Unknown error.",
      code: "unknown",
      retryable: false
    });
  });
});
