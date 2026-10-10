import { defineConfig } from "vite";
export default defineConfig({
  clearScreen: false,
  server: { watch: { ignored: ["**/src-tauri/**"] }, fs: { allow: ["../.."] } },
  build: { target: "es2022" },
});
