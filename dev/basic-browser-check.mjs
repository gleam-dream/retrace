import {
  test,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";
import { mkdir } from "node:fs/promises";
await mkdir(".artifacts/composition-check", { recursive: true });
test.use({ viewport: { width: 1440, height: 1000 } });
test("basic-browser-check", async ({ browser, context, page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.stack || e.message));
  await page.goto("http://127.0.0.1:5193/");
  await expect(
    page.getByRole("status", { name: "Recording delivery" }),
  ).toHaveText("All saved entries delivered");
  await page.getByRole("button", { name: "Receive one", exact: true }).click();
  await page.waitForTimeout(300);
  await page.getByRole("button", { name: "Reserve one", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Recording delivery" }),
  ).toHaveText("All saved entries delivered");
  const replay = await page
    .getByRole("link", { name: "Inspect this recording" })
    .getAttribute("href");
  await page.getByRole("link", { name: "Inspect this recording" }).click();
  const frame = page.frameLocator("iframe");
  await expect(
    page.getByRole("button", { name: /Received a notebook.*#1/ }),
  ).toBeVisible();
  await page.getByRole("button", { name: /Reserved for an order.*#2/ }).click();
  await expect(frame.getByLabel("Reserved", { exact: true })).toHaveText("1");
  await expect(frame.getByLabel("On hand", { exact: true })).toHaveText("5");
  await expect(page.locator(".viewport-label")).toContainText("900 × 600");
  await expect(frame.locator(".replay-root")).toHaveAttribute("inert", "");
  await expect(page.locator(".stage")).toHaveCSS("position", "relative");
  if ((await page.locator(".stage").evaluate((e) => e.clientHeight)) < 300)
    throw Error("Viewer stage did not receive its layout styles");
  await page.screenshot({
    path: ".artifacts/composition-check/inventory-replay.png",
  });
  // Reload a nonzero checkpoint range with original sequence labels.
  await page.goto(`http://127.0.0.1:5193${replay}&after=1`);
  await expect(
    page.getByRole("button", { name: /Reserved for an order.*#2/ }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: /Received a notebook.*#1/ }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: /Reserved for an order.*#2/ }).click();
  await expect(
    page.frameLocator("iframe").getByLabel("Reserved", { exact: true }),
  ).toHaveText("1");
  // Disposal removes the Lustre application and its message subscription.
  const child = page.frames().find((f) => f.url().includes("frame.html"));
  await child.evaluate(() => (window.disposeReplay(), window.disposeReplay()));
  await expect(
    page
      .frameLocator("iframe")
      .getByRole("heading", { name: "Field notebooks" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: /Reserved for an order.*#2/ }).click();
  await expect(
    page
      .frameLocator("iframe")
      .getByRole("heading", { name: "Field notebooks" }),
  ).toHaveCount(0);
  await page.evaluate(() => (window.disposeViewer(), window.disposeViewer()));
  await expect(page.locator("#viewer")).toBeEmpty();
  if (errors.length) throw Error(errors.join("\n"));
  console.log("Basic browser checks passed");
});
