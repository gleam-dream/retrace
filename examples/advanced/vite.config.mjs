import { defineConfig } from "vite";
export default defineConfig({
  clearScreen: false,
  define: {
    __RETRACE_BUILD__: JSON.stringify(
      process.env.RETRACE_BUILD_ID || "membership-screen-v2-dev",
    ),
  },
  server: { watch: { ignored: ["**/src-tauri/**"] }, fs: { allow: ["../.."] } },
  build: { target: "es2022" },
});
