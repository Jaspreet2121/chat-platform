import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/app/**/*.{ts,tsx}", "./src/components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: "#17202a",
        paper: "#f7f9fb",
        line: "#d8dee6",
        brand: "#2563eb",
        mint: "#0f766e"
      }
    }
  },
  plugins: []
};

export default config;
