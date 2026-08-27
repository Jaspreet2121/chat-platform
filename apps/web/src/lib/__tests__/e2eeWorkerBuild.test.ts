import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * The E2EE worker's DELIVERY, pinned end to end.
 *
 * This exists because the bundler-resolved form silently broke in production and nothing caught it:
 * `new Worker(new URL("livekit-client/e2ee-worker", import.meta.url))` emitted a real chunk (so a
 * build-output check passed) but turbopack's runtime then called its module-map resolver with a URL
 * OBJECT where a string specifier is required, throwing
 * `TypeError: e.indexOf is not a function` at worker construction in prod mode only. Every E2EE call
 * degraded to plain.
 *
 * The worker is now VENDORED into public/ and fetched from a fixed same-origin path, so no bundler
 * rewriting is involved at all. The risk that replaces it is DRIFT — a livekit-client upgrade leaving
 * a stale copy behind — which is exactly what the hash lock below refuses.
 */

const APP = process.cwd();
const VENDORED = join(APP, "public", "livekit-e2ee-worker.mjs");
const PACKAGE_ROOT = join(APP, "node_modules", "livekit-client");

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

describe("vendored E2EE worker", () => {
  it("is committed in public/ and is a non-trivial ES module", () => {
    expect(existsSync(VENDORED)).toBe(true);

    const source = readFileSync(VENDORED, "utf8");
    // It is loaded with { type: "module" } — the UMD build would fail at runtime.
    expect(source.length).toBeGreaterThan(10_000);
    expect(/\bexport\b|\bimport\b/.test(source)).toBe(true);
  });

  it("is served from the URL the client actually requests", async () => {
    // The constant and the file on disk must agree; a rename in one place would 404 in production
    // and silently degrade every call to plain.
    const { E2EE_WORKER_URL } = await import("@/lib/calls");
    expect(E2EE_WORKER_URL).toBe("/livekit-e2ee-worker.mjs");
    expect(existsSync(join(APP, "public", E2EE_WORKER_URL.replace(/^\//, "")))).toBe(true);
  });

  it("HASH LOCK: matches the installed livekit-client's ESM worker byte for byte", () => {
    if (!existsSync(PACKAGE_ROOT)) return; // no install (fresh clone) — nothing to compare against

    const manifest = JSON.parse(readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8"));
    const entry = manifest.exports?.["./e2ee-worker"]?.import;

    // If livekit-client stops exporting this, the vendor script must be revisited — fail loudly
    // rather than silently shipping a stale worker.
    expect(entry, "livekit-client no longer exports ./e2ee-worker (import)").toBeTruthy();

    const upstream = join(PACKAGE_ROOT, entry);
    expect(sha256(VENDORED)).toBe(sha256(upstream));
  });

  it("the vendor step is wired into the build, so the copy cannot lag the library", () => {
    const scripts = JSON.parse(readFileSync(join(APP, "package.json"), "utf8")).scripts;
    expect(scripts.prebuild).toContain("vendor-e2ee-worker");
  });
});

/**
 * The standalone image ships public/ and .next/static separately from the server bundle; neither is
 * copied automatically. These assert the layout the Dockerfile depends on.
 */
const NEXT_DIR = join(APP, ".next");

describe.skipIf(!existsSync(join(NEXT_DIR, "static")))("production build layout", () => {
  it("the standalone server does NOT bundle static/ or public/ (the Dockerfile copies them)", () => {
    const standalone = join(NEXT_DIR, "standalone");
    if (!existsSync(standalone)) return;

    // Documented here so a future "why is the worker 404ing?" is answered by a test rather than by
    // a production incident: apps/web/Dockerfile copies .next/static AND public into the image.
    expect(existsSync(join(standalone, ".next", "static"))).toBe(false);
  });

  it("no client chunk still references the bundler-resolved worker URL", () => {
    const chunkDir = join(NEXT_DIR, "static", "chunks");
    const walk = (dir: string): string[] =>
      readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
        const path = join(dir, entry.name);
        return entry.isDirectory() ? walk(path) : [path];
      });

    const offenders = walk(chunkDir)
      .filter((p) => p.endsWith(".js"))
      .filter((p) => readFileSync(p, "utf8").includes("livekit-client/e2ee-worker"));

    // That bare specifier is what turbopack mis-resolves at runtime. It must not appear in app code
    // any more — its presence means someone reintroduced the broken form.
    expect(offenders).toEqual([]);
  });
});
