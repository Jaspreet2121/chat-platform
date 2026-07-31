import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

// The web suite pins WIRE SHAPES and PURE RULES — the things that break silently in production — not
// rendering. So the default environment is `node` (faster, and honest about what is under test); the
// one file that needs browser globals opts in with a `// @vitest-environment jsdom` docblock.
//
// No network, no real timers: every test stubs `fetch` at the boundary.
export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/__tests__/**/*.test.ts"],
    clearMocks: true,
    restoreMocks: true
  },
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url))
    }
  }
});
