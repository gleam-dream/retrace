// Advanced composition: replace delivery and viewer reads without a collector.
import {
  test,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";
import { mkdir } from "node:fs/promises";
await mkdir(".artifacts/composition-check", { recursive: true });
test.use({ viewport: { width: 430, height: 932 } });
test("composition-browser-check", async ({ browser, context, page }) => {
  // This mode must work even with every collector request denied.
  await context.route("http://127.0.0.1:4417/**", (route) => route.abort());
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(
    "http://127.0.0.1:5190/?user=Composition&storage=local&diagnostics",
  );
  await expect(page.locator(".delivery")).toHaveText(
    "All saved entries delivered",
  );
  const id = await page.locator(".session-id").textContent();
  await page.getByRole("button", { name: "Add a point", exact: true }).click();
  await page.waitForTimeout(300);
  await page
    .getByRole("button", { name: "Record an unchanged state", exact: true })
    .click();
  await expect(page.locator("[data-saved]")).toHaveAttribute("data-saved", "2");
  await expect(page.locator(".delivery")).toHaveText(
    "All saved entries delivered",
  );
  const url = `http://127.0.0.1:5190/viewer/index.html?storage=local&session=${id}`;
  await page.goto(url);
  await page
    .getByRole("button", { name: /Recorded unchanged state.*#2/ })
    .click();
  await expect(page.frameLocator("iframe").locator("[data-points]")).toHaveText(
    "1",
  );
  await expect(page.locator(".viewport-label")).toContainText("430 × 932");
  await expect(
    page.frameLocator("iframe").locator(".replay-root"),
  ).toHaveAttribute("inert", "");
  await page.goto(url + "&after=1");
  await expect(
    page.getByRole("button", { name: /Recorded unchanged state.*#2/ }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: /Added a point.*#1/ }),
  ).toHaveCount(0);
  await page.evaluate((id) => {
    const key = `retrace:advanced:archive:${id}`,
      rows = JSON.parse(localStorage.getItem(key));
    for (const n of Object.keys(rows)) {
      const b = JSON.parse(rows[n]);
      b.session.build = "missing-build";
      rows[n] = JSON.stringify(b);
    }
    localStorage.setItem(key, JSON.stringify(rows));
  }, id);
  await page.reload();
  await expect(page.getByRole("alert")).toContainText(
    "artifact for this build is unavailable",
  );
  await page.evaluate((id) => {
    const key = `retrace:advanced:archive:${id}`,
      rows = JSON.parse(localStorage.getItem(key));
    for (const n of Object.keys(rows)) {
      const b = JSON.parse(rows[n]);
      b.session.build = "membership-screen-v2-dev";
      rows[n] = JSON.stringify(b);
    }
    localStorage.setItem(key, JSON.stringify(rows));
  }, id);
  await page.getByRole("button", { name: "Reload recording" }).click();
  await expect(
    page.getByRole("button", { name: /Recorded unchanged state.*#2/ }),
  ).toBeVisible();
  await page.screenshot({ path: ".artifacts/composition-check/advanced.png" });
  if (errors.length) throw Error(errors.join("\n"));
  console.log("PASS advanced custom composition", id);
});
