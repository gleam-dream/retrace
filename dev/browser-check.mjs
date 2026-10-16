import {
  chromium,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";
import { mkdir, writeFile } from "node:fs/promises";
const browser = await chromium.launch({ headless: true });
const user = `browser-${Date.now()}`,
  appUrl = process.env.RETRACE_APP_URL || "http://127.0.0.1:5190",
  viewerUrl = "http://127.0.0.1:5191",
  endpoint = "http://127.0.0.1:4417";
await mkdir(".artifacts/viewer-check", { recursive: true });
try {
  const context = await browser.newContext({
      viewport: { width: 390, height: 844 },
    }),
    app = await context.newPage(),
    errors = [];
  app.on("pageerror", (e) => errors.push(e.message));
  let disconnected = true;
  await app.route("**/batches", (route) =>
    disconnected && route.request().method() === "POST"
      ? route.abort()
      : route.continue(),
  );
  await app.goto(`${appUrl}/?user=${user}&diagnostics`);
  await app.getByText("Recording status", { exact: true }).click();
  await expect(app.locator(".delivery")).toHaveText(
    "All saved entries delivered",
  );
  const id = await app.locator(".session-id").textContent();
  await app.getByText("Recording status", { exact: true }).click();
  await app.getByRole("button", { name: "Add a point", exact: true }).click();
  await app.waitForTimeout(3000); // A real idle gap must remain visible during playback.
  await app
    .getByRole("button", { name: "Record an unchanged state", exact: true })
    .click();
  await app
    .getByRole("button", { name: "Read device information", exact: true })
    .click();
  await expect(app.getByLabel("Device result", { exact: true })).toContainText(
    "Browser preview",
  );
  await app.getByRole("button", { name: "Details", exact: true }).click();
  await expect(
    app.getByRole("heading", { name: "Card details" }),
  ).toBeVisible();
  await app.getByRole("button", { name: "Back to card" }).click();
  await app.setViewportSize({ width: 430, height: 932 });
  await expect(app.locator("[data-saved]")).toHaveAttribute("data-saved", "7");
  await expect(app.locator("[data-queued]")).toHaveAttribute(
    "data-queued",
    "7",
  );
  await app.reload();
  disconnected = false;
  await app.getByText("Recording status", { exact: true }).click();
  await app.getByRole("button", { name: "Retry upload" }).click();
  await expect(app.locator("[data-queued]")).toHaveAttribute(
    "data-queued",
    "0",
  );
  await app.getByText("Recording status", { exact: true }).click();
  await expect(
    app.getByRole("button", { name: "Browse sessions" }),
  ).toHaveCount(0);
  await app.screenshot({ path: ".artifacts/viewer-check/app-mobile.png" });
  const before = await (
      await fetch(`${endpoint}/sessions/${id}/batches`)
    ).json(),
    batches = before.map(JSON.parse),
    entries = batches.flatMap((b) => b.entries);
  expect(entries[1].elapsed_ms - entries[0].elapsed_ms).toBeGreaterThanOrEqual(
    2900,
  );
  const viewer = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  viewer.on("pageerror", (e) => errors.push(e.message));
  let uploads = 0;
  viewer.on("request", (req) => {
    if (req.method() === "POST" && new URL(req.url()).pathname === "/batches")
      uploads++;
  });
  await viewer.goto(`${viewerUrl}/?user=${user}&session=${id}`);
  const frame = viewer.frameLocator("iframe"),
    scrubber = viewer.getByRole("slider", { name: "Playback position" });
  await expect(frame.locator("[data-points]")).toHaveText("0");
  const seek = async (time) => {
    await scrubber.fill(String(time));
    await scrubber.dispatchEvent("input");
  };
  await seek(entries[0].elapsed_ms);
  await expect(frame.locator("[data-points]")).toHaveText("1");
  await viewer.getByRole("button", { name: "Play", exact: true }).click();
  const started = Number(await scrubber.inputValue());
  await viewer.waitForTimeout(1000);
  const elapsed = Number(await scrubber.inputValue()) - started;
  expect(elapsed).toBeGreaterThan(800);
  expect(elapsed).toBeLessThan(1300);
  await expect(frame.getByLabel("Device result", { exact: true })).toHaveText(
    "Not requested",
  );
  await viewer.getByRole("button", { name: "Pause", exact: true }).click();
  await seek(entries.find((e) => e.kind === "ShowDetails").elapsed_ms);
  await expect(
    frame.getByRole("heading", { name: "Card details" }),
  ).toBeVisible();
  await seek(entries.at(-1).elapsed_ms);
  await expect(
    frame.getByLabel("Device result", { exact: true }),
  ).toContainText("Browser preview");
  expect(
    await viewer.locator("iframe").evaluate((e) => e.contentWindow.innerWidth),
  ).toBe(430);
  await expect(
    frame.getByRole("button", { name: "Add a point", exact: true }),
  ).toBeVisible();
  await viewer.screenshot({
    path: ".artifacts/viewer-check/desktop.png",
    fullPage: true,
  });
  await seek(0);
  await expect(frame.locator("[data-points]")).toHaveText("0");
  expect(
    await viewer.locator("iframe").evaluate((e) => e.contentWindow.innerWidth),
  ).toBe(390);
  await viewer.setViewportSize({ width: 390, height: 844 });
  await viewer.screenshot({
    path: ".artifacts/viewer-check/mobile.png",
    fullPage: true,
  });
  expect(
    await viewer.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);

  // Artifact/storage failures must clear the old frame and allow recovery.
  await viewer.route(`**/sessions/${id}/batches?after=0`, async (route) => {
    const changed = batches.map((batch) =>
      JSON.stringify({
        ...batch,
        session: { ...batch.session, build: "missing-historical-build" },
      }),
    );
    await route.fulfill({ json: changed });
  });
  await viewer.getByRole("button", { name: "Reload recording" }).click();
  await expect(viewer.locator(".stage-message")).toContainText(
    "artifact for this build is unavailable",
  );
  await expect(viewer.locator(".frame-size")).toBeHidden();
  await expect(
    viewer.getByRole("button", { name: "Play", exact: true }),
  ).toBeDisabled();
  await viewer.unroute(`**/sessions/${id}/batches?after=0`);
  await viewer.getByRole("button", { name: "Reload recording" }).click();
  await expect(frame.locator("[data-points]")).toHaveText("0");
  await viewer.route("**/dev-frame.html?*", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<script>parent.postMessage({api:1,token:new URL(location.href).searchParams.get('token'),type:'ready',build:'wrong-build'},location.origin)</script>`,
    }),
  );
  await viewer.getByRole("button", { name: "Reload recording" }).click();
  await expect(viewer.locator(".stage-message")).toContainText(
    "artifact build does not match",
  );
  await viewer.unroute("**/dev-frame.html?*");
  await viewer.getByRole("button", { name: "Reload recording" }).click();
  await expect(frame.locator("[data-points]")).toHaveText("0");
  expect(
    await (await fetch(`${endpoint}/sessions/${id}/batches`)).json(),
  ).toEqual(before);
  expect(uploads).toBe(0);
  expect(errors).toEqual([]);
  await writeFile(
    ".artifacts/viewer-check/session.json",
    JSON.stringify(
      { id, user, entries, playback_advance_ms: elapsed },
      null,
      2,
    ),
  );
  console.log(
    `PASS offline recovery, full screen, timestamp gaps, seek, route, viewport, inert replay: ${id}`,
  );
} finally {
  await browser.close();
}

await import("./progressive-viewer-browser-check.mjs");
