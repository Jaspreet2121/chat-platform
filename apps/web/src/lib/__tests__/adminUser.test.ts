import { describe, expect, it } from "vitest";
import { identitySubtitle, identityTitle, maskPhone, userTitle } from "@/lib/adminUser";

describe("maskPhone", () => {
  it("keeps the country code and the last four digits, hides the rest", () => {
    expect(maskPhone("+918377003300")).toBe("+91 •••••• 3300");
    expect(maskPhone("+15550199001")).toBe("+1 •••••• 9001");
  });

  it("masks however the number was stored", () => {
    expect(maskPhone("+91 83770 03300")).toBe("+91 •••••• 3300");
  });

  it("never reveals a short or empty value", () => {
    expect(maskPhone(null)).toBe("");
    expect(maskPhone("")).toBe("");
    expect(maskPhone("12345")).toBe("•••••");
  });
});

describe("identityTitle", () => {
  it("prefers the name, then the handle, then says so", () => {
    expect(identityTitle({ display_name: "Guru", username: "guru" })).toBe("Guru");
    expect(identityTitle({ display_name: "  ", username: "guru" })).toBe("@guru");
    expect(identityTitle({ username: "@guru" })).toBe("@guru");
    expect(identityTitle({})).toBe("(no name)");
    expect(identityTitle(null)).toBe("(no name)");
  });

  it("is NEVER a phone number, even when that is all there is", () => {
    // The whole point of the rule: a person with no name and no handle is "(no name)", not their
    // phone, on every list in the console.
    expect(identityTitle({ phone_number: "+918377003300" })).toBe("(no name)");
    expect(userTitle({ display_name: null, username: null })).toBe("(no name)");
  });
});

describe("identitySubtitle", () => {
  it("shows the handle under a name, and the phone masked", () => {
    expect(
      identitySubtitle({ display_name: "Guru", username: "guru", phone_number: "+918377003300" })
    ).toBe("@guru · +91 •••••• 3300");
  });

  it("does not repeat the handle when it is already the title", () => {
    expect(identitySubtitle({ username: "guru", phone_number: "+918377003300" })).toBe(
      "+91 •••••• 3300"
    );
  });

  it("is empty when there is nothing safe to add", () => {
    expect(identitySubtitle({ display_name: "Guru" })).toBe("");
    expect(identitySubtitle(null)).toBe("");
  });
});
