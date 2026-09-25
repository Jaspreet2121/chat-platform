import { describe, expect, it } from "vitest";
import { CONSOLE_ROLES, hasConsoleAccess } from "../adminAccess";

describe("hasConsoleAccess — the web mirror of IAM.console_access?/1", () => {
  it("admits every console role, including the two is_admin excludes", () => {
    for (const role of CONSOLE_ROLES) {
      expect(hasConsoleAccess({ role, permissions: [], is_admin: false })).toBe(true);
    }
    // The bug this fixes: set_user_role sets is_admin only for root/admin, so these two were locked
    // out of a console they hold permissions for.
    expect(hasConsoleAccess({ role: "moderator", is_admin: false })).toBe(true);
    expect(hasConsoleAccess({ role: "support", is_admin: false })).toBe(true);
  });

  it("refuses an ordinary user", () => {
    expect(hasConsoleAccess({ role: "user", permissions: [], is_admin: false })).toBe(false);
    expect(hasConsoleAccess({ role: "user" })).toBe(false);
  });

  it("admits on a non-empty permission list even for a role this build has never heard of", () => {
    // A role added server-side before the web list is updated must not lock its holders out — the
    // server only resolves permissions for a console role.
    expect(hasConsoleAccess({ role: "auditor", permissions: ["audit.view"] })).toBe(true);
  });

  it("keeps the legacy is_admin fallback, the same one RequireAdmin keeps", () => {
    expect(hasConsoleAccess({ is_admin: true })).toBe(true);
    expect(hasConsoleAccess({ role: "", permissions: [], is_admin: true })).toBe(true);
  });

  it("is case- and whitespace-tolerant on the role", () => {
    expect(hasConsoleAccess({ role: "  Moderator " })).toBe(true);
  });

  it("refuses absent, null and empty sessions — never a default-open", () => {
    expect(hasConsoleAccess(null)).toBe(false);
    expect(hasConsoleAccess(undefined)).toBe(false);
    expect(hasConsoleAccess({})).toBe(false);
    expect(hasConsoleAccess({ permissions: [] })).toBe(false);
  });
});
