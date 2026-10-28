import {
  test,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";

test("protected replay preserves decisions when seeking and has no live capabilities", async ({
  page,
  context,
}) => {
  const uploaded = [],
    errors = [];
  let resultRoute;
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    window.persistedBodies = [];
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (row, ...rest) {
      if (row?.body) window.persistedBodies.push(row.body);
      return put.call(this, row, ...rest);
    };
  });
  await page.route("http://127.0.0.1:4417/batches", async (route) => {
    if (route.request().method() === "OPTIONS") {
      return route.fulfill({
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "POST, OPTIONS",
          "access-control-allow-headers": "content-type",
        },
      });
    }
    const body = route.request().postData();
    uploaded.push(body);
    const batch = JSON.parse(body);
    await route.fulfill({
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify({
        session_id: batch.session.id,
        ack: batch.entries.at(-1).sequence,
      }),
    });
  });
  await page.route("**/protected-response.json", (route) => {
    resultRoute = route;
  });
  await page.goto("http://127.0.0.1:5194/protected.html");
  await expect(
    page.getByRole("status", { name: "Recording delivery" }),
  ).toHaveText("All saved entries delivered");
  await page.getByLabel("Private label").fill("§");
  await page.getByRole("button", { name: "Check label", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Validation", exact: true }),
  ).toHaveText("Use at least 3 characters");
  await page.getByRole("button", { name: "Details", exact: true }).click();
  await page.getByLabel("Private label").fill("PRIVATE-BROWSER-SENTINEL-8da2");
  await page.getByRole("button", { name: "Check label", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Outcome", exact: true }),
  ).toHaveText("Checking…");
  await expect.poll(() => Boolean(resultRoute)).toBe(true);
  await resultRoute.fulfill({
    contentType: "application/json",
    body: '{"accepted":true}',
  });
  await expect(
    page.getByRole("status", { name: "Outcome", exact: true }),
  ).toHaveText("Check confirmed");
  await page.getByRole("button", { name: "Lock", exact: true }).click();
  await page.getByRole("button", { name: "Details", exact: true }).click();
  await expect.poll(() => uploaded.length).toBe(8);
  const persisted = await page.evaluate(() => window.persistedBodies);
  expect(persisted).toEqual(uploaded);
  for (const body of [...persisted, ...uploaded]) {
    expect(body).not.toContain("§");
    expect(body).not.toContain("PRIVATE-BROWSER-SENTINEL-8da2");
  }
  // Shut down the live application before measuring historical behavior.
  await page.goto("about:blank");
  const frame = await context.newPage();
  frame.on("pageerror", (error) => errors.push(error.message));
  await frame.addInitScript(() => {
    window.liveCalls = { http: 0, storage: 0, native: 0 };
    const refuse = (kind) => () => {
      window.liveCalls[kind]++;
      throw Error(`Replay attempted ${kind}`);
    };
    window.fetch = refuse("http");
    XMLHttpRequest.prototype.open = refuse("http");
    navigator.sendBeacon = refuse("http");
    window.WebSocket = refuse("http");
    Storage.prototype.setItem = refuse("storage");
    IDBFactory.prototype.open = refuse("storage");
    IDBDatabase.prototype.transaction = refuse("storage");
    window.__TAURI_INTERNALS__ = { invoke: refuse("native") };
    window.__TAURI__ = { core: { invoke: refuse("native") } };
    window.reports = [];
    addEventListener("message", (event) => {
      if (["ready", "loaded", "error"].includes(event.data?.type))
        window.reports.push(event.data);
    });
  });
  await frame.goto(
    "http://127.0.0.1:5194/protected-frame.html?token=protected-check",
  );
  await expect
    .poll(() =>
      frame.evaluate(() => window.reports.some((m) => m.type === "ready")),
    )
    .toBe(true);
  const send = (type, values) =>
    frame.evaluate(
      ({ type, values }) => {
        postMessage(
          { api: 1, token: "protected-check", type, ...values },
          location.origin,
        );
      },
      { type, values },
    );
  await send("load", { body: JSON.stringify(uploaded) });
  await expect
    .poll(() =>
      frame.evaluate(() => window.reports.some((m) => m.type === "loaded")),
    )
    .toBe(true);
  const validation = frame.getByRole("status", {
    name: "Validation",
    exact: true,
  });
  const outcome = frame.getByRole("status", { name: "Outcome", exact: true });
  for (const sequence of [2, 8, 2, 5, 6, 7, 3, 2]) {
    await send("seek", { sequence });
    await expect(frame.getByLabel("Private label")).toHaveValue(
      "Protected content",
    );
    await expect(validation).toHaveText(
      sequence <= 3 ? "Use at least 3 characters" : "Valid label",
    );
    if (sequence === 5) {
      await expect(outcome).toHaveText("Checking…");
      await expect(
        frame.getByRole("button", { name: "Check label", exact: true }),
      ).toBeDisabled();
    }
    if (sequence === 6) await expect(outcome).toHaveText("Check confirmed");
    if (sequence === 7 || sequence === 8)
      await expect(
        frame.getByRole("button", { name: "Unlock", exact: true }),
      ).toBeVisible();
    await expect(
      frame.getByRole("button", { name: "Details", exact: true }),
    ).toHaveAttribute(
      "aria-expanded",
      sequence === 3 || (sequence >= 5 && sequence <= 7) ? "true" : "false",
    );
  }
  // Even synthetic events bypassing DOM inertness are mapped to Ignore by mount.
  await frame.getByLabel("Private label").evaluate((input) => {
    input.value = "a different value";
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await frame
    .getByRole("button", { name: "Check label", exact: true })
    .evaluate((button) => button.click());
  await expect(validation).toHaveText("Use at least 3 characters");
  expect(await frame.evaluate(() => window.liveCalls)).toEqual({
    http: 0,
    storage: 0,
    native: 0,
  });
  // A malformed replacement clears the previous frame instead of exposing a
  // valid prefix. A corrected range and a later checkpoint can be loaded again.
  const malformed = uploaded.map(JSON.parse);
  malformed[5].entries[0].payload = '{"present":"PRIVATE-INVALID"}';
  await send("load", { body: JSON.stringify(malformed.map(JSON.stringify)) });
  await expect(frame.getByLabel("Private label")).toHaveCount(0);
  await expect
    .poll(() =>
      frame.evaluate(() => window.reports.some((m) => m.type === "error")),
    )
    .toBe(true);
  await send("load", { body: JSON.stringify(uploaded.slice(2)) });
  await expect(validation).toHaveText("Use at least 3 characters");
  await expect(frame.getByLabel("Private label")).toHaveValue(
    "Protected content",
  );
  expect(await frame.evaluate(() => window.liveCalls)).toEqual({
    http: 0,
    storage: 0,
    native: 0,
  });
  expect(errors).toEqual([]);
  await frame.close();
});
