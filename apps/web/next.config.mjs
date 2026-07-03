import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Lean production Docker image: `next build` emits .next/standalone (self-contained server.js).
  output: "standalone",
  turbopack: {
    root: __dirname
  }
};

export default nextConfig;
