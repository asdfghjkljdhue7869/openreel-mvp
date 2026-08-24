import { defineConfig } from "vite";
import path from "path";

export default defineConfig({
  root: "src",
  publicDir: false,
  resolve: {
    alias: [
      { find: /^@openreel\/core$/, replacement: path.resolve(__dirname, "./src/core-lib/src/index.ts") },
      { find: /^@openreel\/core\/(.*)$/, replacement: path.resolve(__dirname, "./src/core-lib/src/$1") },
    ],
  },
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    target: "es2022",
  },
  optimizeDeps: {
    exclude: ["@ffmpeg/ffmpeg", "@ffmpeg/util"],
  },
});
