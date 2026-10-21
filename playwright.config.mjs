import { defineConfig } from "./examples/advanced/node_modules/@playwright/test/index.mjs";

export default defineConfig({
  testDir: "./dev",
  testMatch: ["*browser-check.mjs", "opaque-frame-check.mjs"],
  workers: 1,
  timeout: 60000,
  reporter: [
    ["list"],
    ["json", { outputFile: ".artifacts/browser-results.json" }],
  ],
  outputDir: ".artifacts/playwright",
  use: {
    headless: true,
    launchOptions: process.env.CHROME_BIN
      ? { executablePath: process.env.CHROME_BIN }
      : {},
  },
});
