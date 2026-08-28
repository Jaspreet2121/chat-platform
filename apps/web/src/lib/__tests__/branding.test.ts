import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * THE REBRAND GUARD. "Skifi" is retired as a user-visible name — the product is
 * "Growblic: Chat, Call, Meet", "Growblic" inside the UI.
 *
 * A rename sweep is only as good as the thing that stops the next paste from undoing it: the old name
 * lives on in a wire format, in every developer's muscle memory, and in whatever half-finished branch
 * gets merged next month. So this walks the shipped source and public assets and fails on any
 * occurrence that is not on the allowlist below.
 *
 * THE ALLOWLIST IS IDENTIFIERS ONLY — never display copy. Each entry is something a user never reads
 * and that could not be renamed without breaking a contract:
 *
 *   * `skifi-e2ee*` — the IndexedDB database name, its Web Lock name and a localStorage key
 *     (src/lib/e2ee/identity.ts). Renaming these ORPHANS every existing device's identity keypair:
 *     the browser would open a fresh, empty database, the device would mint a new keypair, and every
 *     past conversation would fail to decrypt with a "security code changed" pill. A storage key is a
 *     migration, not a rename, and this rebrand does not need one.
 *   * The same names asserted in the e2ee identity test, which opens the database directly.
 *
 * Deliberately NOT on the allowlist, because they are not in this tree: the backend's
 * `skifi-link:v1:` QR payload prefix (api_gateway's link_controller and its tests) is a WIRE FORMAT
 * shared with released mobile clients — Android parses that literal, so changing it would break device
 * linking for everyone who has not updated. It is out of apps/web's reach and stays as it is.
 */

const RETIRED_NAME = /skifi/i;

/** Identifier occurrences that may keep the retired name. Path is repo-relative to apps/web. */
const ALLOWED: { path: string; reason: string }[] = [
  {
    path: "src/lib/e2ee/identity.ts",
    reason: "IndexedDB name, Web Lock name and localStorage key — renaming orphans existing identities"
  },
  {
    path: "src/lib/e2ee/__tests__/identity.test.ts",
    reason: "opens the IndexedDB database above by its literal name"
  }
];

/**
 * This file itself, which necessarily spells the retired name in order to forbid it. Kept OUT of
 * ALLOWED so the allowlist stays exactly "identifiers a user never reads" — a guard excusing itself is
 * not the same kind of exception as a storage key, and conflating them would let the allowlist's own
 * assertions (below) pass on the wrong grounds.
 */
const SELF = "src/lib/__tests__/branding.test.ts";

const APP = process.cwd();
const ROOTS = ["src", "public"];
const SKIP_DIRS = new Set(["node_modules", ".next", "dist", "build", "coverage"]);
/** Binary assets (icons, fonts, the vendored worker) — nothing user-readable to sweep. */
const SKIP_EXT = /\.(png|jpe?g|gif|webp|avif|ico|svg|woff2?|ttf|eot|mp[34]|webm|zip)$/i;

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (!SKIP_EXT.test(entry)) out.push(full);
  }
  return out;
}

function shippedFiles(): string[] {
  return ROOTS.flatMap((root) => walk(join(APP, root)));
}

function isAllowed(relativePath: string): boolean {
  return ALLOWED.some((entry) => entry.path === relativePath);
}

describe("rebrand: Skifi is retired", () => {
  const files = shippedFiles();

  it("finds source to sweep at all (a broken walk must not pass vacuously)", () => {
    expect(files.length).toBeGreaterThan(50);
    expect(files.some((f) => f.endsWith("src/app/layout.tsx"))).toBe(true);
    expect(files.some((f) => f.endsWith("public/manifest.json"))).toBe(true);
  });

  it("has no occurrence of the retired name outside the identifier allowlist", () => {
    const offenders: string[] = [];

    for (const file of files) {
      const rel = relative(APP, file);
      if (rel === SELF || isAllowed(rel)) continue;

      const lines = readFileSync(file, "utf8").split("\n");
      lines.forEach((line, index) => {
        if (RETIRED_NAME.test(line)) offenders.push(`${rel}:${index + 1}: ${line.trim()}`);
      });
    }

    expect(offenders, `user-visible "Skifi" found:\n${offenders.join("\n")}`).toEqual([]);
  });

  it("keeps the allowlist honest — every entry still contains the name it is excused for", () => {
    // An allowlist entry that no longer matches is a licence nobody is using: either the identifier was
    // renamed (and the entry should go) or the file moved (and the entry is silently protecting nothing).
    for (const entry of ALLOWED) {
      const contents = readFileSync(join(APP, entry.path), "utf8");
      expect(RETIRED_NAME.test(contents), `stale allowlist entry: ${entry.path}`).toBe(true);
    }
  });

  it("the allowlist covers storage identifiers only, never display copy", () => {
    // Every excused occurrence must be a storage/lock key. If someone adds a *string shown to a user*
    // to an allowlisted file, this catches it: the retired name may appear only on lines that also
    // declare one of these identifiers.
    const IDENTIFIER_LINE = /(DB_NAME|LOCK_NAME|SEEN_KEY|indexedDB\.open)/;

    for (const entry of ALLOWED) {
      const lines = readFileSync(join(APP, entry.path), "utf8").split("\n");
      lines.forEach((line, index) => {
        if (!RETIRED_NAME.test(line)) return;
        expect(
          IDENTIFIER_LINE.test(line),
          `${entry.path}:${index + 1} is excused but is not a storage identifier: ${line.trim()}`
        ).toBe(true);
      });
    }
  });
});

describe("rebrand: the product name is present where users read it", () => {
  it("the document title and iOS home-screen title name Growblic", () => {
    const layout = readFileSync(join(APP, "src/app/layout.tsx"), "utf8");
    expect(layout).toContain('title: "Growblic: Chat, Call, Meet"');
    expect(layout).toContain('title: "Growblic"');
  });

  it("the PWA manifest names Growblic in both long and short form", () => {
    const manifest = JSON.parse(readFileSync(join(APP, "public/manifest.json"), "utf8"));
    expect(manifest.name).toBe("Growblic: Chat, Call, Meet");
    expect(manifest.short_name).toBe("Growblic");
  });
});
