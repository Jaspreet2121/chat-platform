import { describe, expect, it } from "vitest";
import { confirmMatches, confirmPhrase } from "@/lib/adminConfirm";

describe("confirmPhrase", () => {
  it("prefers the identifier a human recognises the account by", () => {
    expect(confirmPhrase({ username: "guru", phone_number: "+15550100001" })).toBe("guru");
    expect(confirmPhrase({ phone_number: "+15550100001", email: "a@b.c" })).toBe("+15550100001");
    expect(confirmPhrase({ email: "a@b.c" })).toBe("a@b.c");
  });

  it("falls back to the id only when there is nothing else", () => {
    // An account with no username, phone or email is exactly the one where picking the wrong row
    // would be easiest, so it still gets a phrase rather than an empty box that accepts anything.
    expect(confirmPhrase({ user_id: "11111111-2222" })).toBe("11111111-2222");
    expect(confirmPhrase({ username: "   ", user_id: "abc" })).toBe("abc");
  });

  it("is empty for no target at all", () => {
    expect(confirmPhrase(null)).toBe("");
    expect(confirmPhrase({})).toBe("");
  });
});

describe("confirmMatches", () => {
  const target = { username: "Guru", phone_number: "+15550100001" };

  it("ignores case and surrounding space", () => {
    expect(confirmMatches("guru", target)).toBe(true);
    expect(confirmMatches("  GURU  ", target)).toBe(true);
  });

  it("compares a phone number digit-for-digit, however it was typed", () => {
    const phoneOnly = { phone_number: "+91 83770 03300" };
    expect(confirmMatches("+918377003300", phoneOnly)).toBe(true);
    expect(confirmMatches("+91 83770 03300", phoneOnly)).toBe(true);
    expect(confirmMatches("(+91) 83770-03300", phoneOnly)).toBe(true);
    // A different number must not pass just because it is phone-shaped.
    expect(confirmMatches("+918377003301", phoneOnly)).toBe(false);
  });

  it("refuses an empty box, a partial match and the wrong account", () => {
    expect(confirmMatches("", target)).toBe(false);
    expect(confirmMatches("   ", target)).toBe(false);
    expect(confirmMatches("gur", target)).toBe(false);
    expect(confirmMatches("guru2", target)).toBe(false);
    expect(confirmMatches("+15550100002", target)).toBe(false);
  });

  it("cannot be confirmed when there is no phrase to type", () => {
    // Otherwise a target the UI failed to load would be confirmable by typing nothing.
    expect(confirmMatches("anything", {})).toBe(false);
    expect(confirmMatches("", {})).toBe(false);
    expect(confirmMatches("", { phone_number: "+ -" })).toBe(false);
  });
});
