import {
  chromium,
  expect,
} from "../examples/app/node_modules/@playwright/test/index.mjs";
import { mkdir } from "node:fs/promises";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1280, height: 900 },
});
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
const user = `browser-${Date.now()}`;
const base = process.env.RETRACE_APP_URL || "http://127.0.0.1:5190";
await mkdir(".artifacts", { recursive: true });
try {
  let disconnected = true;
  await page.route("**/batches", (route) =>
    disconnected && route.request().method() === "POST"
      ? route.abort()
      : route.continue(),
  );
  await page.goto(`${base}/?user=${user}`);
  await expect(
    page.getByText("All saved entries delivered", { exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Add a point", exact: true }).click();
  await page
    .getByRole("button", { name: "Record an unchanged state", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Read device information", exact: true })
    .click();
  await expect(page.getByLabel("Device result", { exact: true })).toContainText(
    "Browser preview",
  );
  const fact = (label) =>
    page
      .locator(".fact")
      .filter({ has: page.locator("span", { hasText: label }) })
      .locator("strong");
  await expect(fact("Saved locally")).toHaveText("4");
  await expect(fact("Queued batches")).toHaveText("4");
  const id = await page.locator(".session-id").textContent();
  await page.reload();
  await expect(fact("Observed transitions")).toHaveText("0");
  await expect(fact("Queued batches")).toHaveText("4");
  disconnected = false;
  await page.getByRole("button", { name: "Retry upload", exact: true }).click();
  await expect(fact("Uploaded this run")).toHaveText("4");
  await expect(fact("Queued batches")).toHaveText("0");
  await page.screenshot({ path: ".artifacts/web-desktop.png", fullPage: true });
  await page
    .getByRole("button", { name: "Browse sessions", exact: true })
    .click();
  await page.getByLabel("User reference", { exact: true }).fill(user);
  await page
    .getByRole("button", { name: "Refresh sessions", exact: true })
    .click();
  await page
    .getByRole("button")
    .filter({ has: page.locator("small", { hasText: id }) })
    .click();
  await expect(
    page.getByLabel("Recorded device result", { exact: true }),
  ).toContainText("Browser preview");
  await expect(page.locator("[data-points]")).toHaveText("1");
  await page.getByRole("button", { name: "First", exact: true }).click();
  await expect(page.locator("[data-points]")).toHaveText("0");
  await page.getByRole("button", { name: "Next", exact: true }).click();
  await expect(page.locator("[data-points]")).toHaveText("1");
  await page.getByRole("button", { name: "Next", exact: true }).click();
  await expect(fact("Recorded sequence")).toHaveText("2");
  await expect(page.locator("[data-points]")).toHaveText("1");
  await page.getByRole("button", { name: "Latest", exact: true }).click();
  await expect(fact("Recorded sequence")).toHaveText("4");
  await page.screenshot({
    path: ".artifacts/replay-desktop.png",
    fullPage: true,
  });
  const response = await page.request.get(
    `http://127.0.0.1:4417/sessions/${id}/batches`,
  );
  expect((await response.json()).length).toBe(4); // Navigation did not record or execute app effects.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({
    path: ".artifacts/replay-mobile.png",
    fullPage: true,
  });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page
    .getByRole("button", { name: "Live application", exact: true })
    .click();
  await expect(page.locator("[data-points]")).toHaveText("0");
  await page.screenshot({ path: ".artifacts/web-mobile.png", fullPage: true });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  expect(errors).toEqual([]);
  console.log(
    "PASS offline IndexedDB persistence across reload, upload recovery, indexed search, typed replay including unchanged state, isolated live model, desktop/mobile layout",
  );
} finally {
  await browser.close();
}
