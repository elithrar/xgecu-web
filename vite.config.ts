import { defineConfig } from "vite";
import dts from "vite-plugin-dts";

export default defineConfig({
  build: {
    lib: {
      entry: "js/src/index.ts",
      name: "XgecuWeb",
      formats: ["es"],
      fileName: () => "index.js"
    },
    target: "es2022",
    sourcemap: true,
    rollupOptions: {
      external: []
    }
  },
  plugins: [
    dts({
      entryRoot: "js/src",
      outDir: "dist"
    })
  ],
  test: {
    environment: "node",
    include: ["js/test/**/*.test.ts"]
  }
});
