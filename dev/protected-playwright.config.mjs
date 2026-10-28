import base from "../playwright.config.mjs";
import { fileURLToPath } from "node:url";

// Run the production bundle, independently of the collector and other examples.
export default {
  ...base,
  testDir: ".",
  testMatch: "protected-browser-check.mjs",
  webServer: {
    command:
      "node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 5194 --strictPort",
    cwd: fileURLToPath(new URL("../examples/basic", import.meta.url)),
    url: "http://127.0.0.1:5194/protected.html",
    timeout: 30000,
  },
};
