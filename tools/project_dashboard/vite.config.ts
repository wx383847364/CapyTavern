import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: import.meta.dirname,
  plugins: [react()],
  build: {
    outDir: "dist/client",
    emptyOutDir: true,
  },
  test: {
    environment: "jsdom",
    setupFiles: "./tests/setup.ts",
    include: ["tests/**/*.test.ts", "tests/**/*.test.tsx"],
  },
});
