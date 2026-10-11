// Simulator capture is native evidence; this file verifies its replay on the Mac.
import {
  chromium,
  expect,
} from "../../examples/advanced/node_modules/@playwright/test/index.mjs";
import { mkdir, writeFile } from "node:fs/promises";
const id = process.argv[2];
if (!id || !/^[a-f0-9-]{36}$/.test(id))
  throw Error("Pass the Simulator session UUID");
const endpoint = `http://127.0.0.1:4417/sessions/${id}/batches`,
  before = await (await fetch(endpoint)).json(),
  batches = before.map(JSON.parse),
  allEvents = batches.flatMap((b) => b.entries),
  events = allEvents.filter((e) => e.kind !== "Resized");
expect(events.map((e) => e.kind)).toEqual([
  "Increment",
  "NoChange",
  "RequestDevice",
  "DeviceReceived",
  "ShowDetails",
  "ShowCard",
]);
expect(events[3].payload).toBe("ios / aarch64");
expect(batches[0].session.platform).toBe("tauri");
expect(events[1].elapsed_ms - events[0].elapsed_ms).toBeGreaterThanOrEqual(
  3000,
);
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
  });
  let uploads = 0;
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("request", (r) => {
    if (r.method() === "POST" && new URL(r.url()).pathname === "/batches")
      uploads++;
  });
  await page.goto(`http://127.0.0.1:5191/?user=Ada&session=${id}`);
  const frame = page.frameLocator("iframe"),
    slider = page.getByRole("slider", { name: "Playback position" });
  await expect(frame.locator("[data-points]")).toHaveText("0");
  expect(
    await page.locator("iframe").evaluate((e) => e.contentWindow.innerWidth),
  ).toBe(JSON.parse(batches[0].checkpoint.model).viewport.width);
  const seek = async (time) => {
    await slider.fill(String(time));
    await slider.dispatchEvent("input");
  };
  await seek(events[0].elapsed_ms);
  await page.getByRole("button", { name: "Play", exact: true }).click();
  await page.waitForTimeout(1500);
  const elapsed = Number(await slider.inputValue()) - events[0].elapsed_ms;
  expect(elapsed).toBeGreaterThan(1250);
  expect(elapsed).toBeLessThan(1800);
  await expect(frame.getByLabel("Device result", { exact: true })).toHaveText(
    "Not requested",
  );
  await page.getByRole("button", { name: "Pause", exact: true }).click();
  await seek(events[4].elapsed_ms);
  await expect(
    frame.getByRole("heading", { name: "Card details" }),
  ).toBeVisible();
  await seek(events.at(-1).elapsed_ms);
  await expect(frame.getByLabel("Device result", { exact: true })).toHaveText(
    "ios / aarch64",
  );
  await expect(frame.locator("[data-points]")).toHaveText("1");
  expect(await (await fetch(endpoint)).json()).toEqual(before);
  expect(uploads).toBe(0);
  expect(errors).toEqual([]);
  await mkdir(".artifacts/simulator-check", { recursive: true });
  await page.screenshot({
    path: ".artifacts/simulator-check/browser-replay.png",
    fullPage: true,
  });
  await writeFile(
    ".artifacts/simulator-check/replay-evidence.json",
    JSON.stringify(
      {
        session: batches[0].session,
        events,
        measured_playback_ms: elapsed,
        assertions: [
          "native capture with 3-second gap",
          "matching compiled artifact",
          "full viewport and route replay",
          "original-speed gap",
          "no replay uploads",
          "unchanged history",
        ],
      },
      null,
      2,
    ),
  );
  console.log(
    `PASS Simulator → collector → matching artifact → timed browser replay: ${id}`,
  );
} finally {
  await browser.close();
}
