// Copy livekit-client's E2EE worker into public/ so it is served as a PLAIN STATIC ASSET.
//
// WHY NOT let the bundler handle it: turbopack's rewrite of
//   new Worker(new URL("livekit-client/e2ee-worker", import.meta.url))
// emits a call into its module-map resolver with a URL OBJECT where the resolver requires a string
// specifier, so the production runtime throws `TypeError: e.indexOf is not a function` while
// constructing the worker (turbopack runtime `w()` → `e.indexOf("#")`). Every E2EE call then fell
// back to plain. A file in public/ is fetched by a fixed same-origin URL with no bundler rewriting
// at all, so it behaves identically in dev, `next start`, and the standalone Docker image.
//
// Run automatically by `prebuild`, so the vendored copy can never lag the installed library. The
// committed copy keeps the app working even if someone builds without the hook, and
// e2eeWorkerBuild.test.ts hashes both files so a livekit-client upgrade cannot silently drift.

import { copyFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = join(here, "..");
const packageRoot = join(appRoot, "node_modules", "livekit-client");
const manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));

// Read the package's own export map and take the IMPORT condition specifically. `require.resolve`
// would hand back the UMD `.js` build, which cannot be loaded as `{ type: "module" }` — the worker
// must be the ESM artifact.
const entry = manifest.exports?.["./e2ee-worker"]?.import;
if (!entry) {
  throw new Error("livekit-client no longer exports ./e2ee-worker (import) — update this script");
}

const source = join(packageRoot, entry);
const destination = join(appRoot, "public", "livekit-e2ee-worker.mjs");

mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);

console.log(
  `vendored livekit-client@${manifest.version} e2ee worker (${entry}) → public/livekit-e2ee-worker.mjs`
);
