import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * The E2EE worker must survive the PRODUCTION build, or calls degrade to plain on every browser for a
 * reason no unit test would otherwise see. `new Worker(new URL("livekit-client/e2ee-worker", …))`
 * only works because the bundler rewrites it into an emitted chunk — a bare import, or a bundler that
 * stops resolving that form, silently produces a URL that 404s at runtime.
 *
 * These assertions read the real build output. They SKIP when .next is absent (a plain `vitest` run on
 * a clean checkout) rather than failing for the wrong reason — CI builds before it tests.
 */

const NEXT_DIR = join(process.cwd(), ".next");
const STATIC_DIR = join(NEXT_DIR, "static");
const built = existsSync(STATIC_DIR);

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

describe.skipIf(!built)("E2EE worker in the production build", () => {
  it("emits the livekit e2ee worker as its own asset", () => {
    const emitted = walk(STATIC_DIR).filter((p) => /livekit-client\.e2ee\.worker\./.test(p));

    expect(emitted.length).toBeGreaterThan(0);
    // A module worker is what `{ type: "module" }` requires.
    expect(emitted.some((p) => p.endsWith(".mjs"))).toBe(true);
  });

  it("a client chunk references that asset by its /_next/static URL", () => {
    const chunks = walk(join(STATIC_DIR, "chunks")).filter((p) => p.endsWith(".js"));
    const referencing = chunks.filter((p) =>
      readFileSync(p, "utf8").includes("/_next/static/media/livekit-client.e2ee.worker")
    );

    // If this is empty the URL was never rewritten — the worker would 404 and every call would
    // silently fall back to plain.
    expect(referencing.length).toBeGreaterThan(0);
  });

  it("the standalone server ships .next/static (it is NOT copied automatically)", () => {
    const standalone = join(NEXT_DIR, "standalone");
    if (!existsSync(standalone)) return; // not an `output: standalone` build

    // Next deliberately omits static/ from the standalone bundle; the Dockerfile copies it in
    // (apps/web/Dockerfile: COPY .next/static ./.next/static). This asserts the FACT that it is
    // missing here, so a future "why is static empty?" is answered by the test rather than by a
    // production 404 on the worker.
    expect(existsSync(join(standalone, ".next", "static"))).toBe(false);
  });
});
