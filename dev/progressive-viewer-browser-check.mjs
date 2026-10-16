// Real-browser checks through createViewer and the retained v1 frame protocol.
// The fixture uses only load/seek, like historical artifacts; no new append API.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import {
  chromium,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const root = new URL("../packages/retrace_frontend/src/", import.meta.url);
const server = createServer(async (request, response) => {
  try {
    const name = new URL(request.url, "http://localhost").pathname.slice(1);
    if (!name) {
      response.setHeader("Content-Type", "text/html");
      response.end('<main id="viewer"></main>');
    } else if (
      ["viewer.mjs", "range.mjs", "channel.mjs", "timeline.mjs"].includes(name)
    ) {
      response.setHeader("Content-Type", "text/javascript");
      response.end(await readFile(new URL(name, root)));
    } else {
      response.statusCode = 404;
      response.end();
    }
  } catch (error) {
    response.statusCode = 500;
    response.end(error.message);
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  page.setDefaultTimeout(5000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(
    `http://127.0.0.1:${server.address().port}/?session=one&t=180000`,
  );
  await page.evaluate(async () => {
    const { createViewer } = await import("/viewer.mjs");
    const session = (id) => ({
      id,
      user_ref: id,
      build: "v1",
      contract: "c",
      platform: "web",
    });
    const batch = (id, from, to) =>
      JSON.stringify({
        session: session(id),
        checkpoint: { sequence: from, elapsed_ms: from * 60000 },
        entries: Array.from({ length: to - from }, (_, i) => ({
          sequence: from + i + 1,
          elapsed_ms: (from + i + 1) * 60000,
        })),
      });
    window.reads = [];
    window.cancelled = 0;
    window.failed = true;
    const frame = `<body><output>Waiting</output><script>
      const token = window.name.slice(8), origin = ${JSON.stringify(location.origin)};
      const report = (type, body) => parent.postMessage({api:1, token, type, build:'v1', body}, origin);
      addEventListener('message', e => {
        if(e.source !== parent || e.origin !== origin || e.data.token !== token || e.data.api !== 1) return;
        if(e.data.type === 'load') {
          const batches = JSON.parse(e.data.body).map(JSON.parse);
          const all = [batches[0].checkpoint, ...batches.flatMap(b => b.entries)].map(e => ({sequence:e.sequence,elapsed:e.elapsed_ms,viewport:{width:390,height:844},kind:'event',label:'Event '+e.sequence}));
          document.querySelector('output').textContent = String(all[0].sequence);
          report('loaded', JSON.stringify(all));
        } else if(e.data.type === 'seek') document.querySelector('output').textContent = String(e.data.sequence);
      });
      report('ready');
    <\/script>`;
    window.viewerConfig = {
      frameMode: "opaque",
      progressive: true,
      listSessions: async () =>
        ["one", "two"].map((id) => ({ session: session(id), sequence: 4 })),
      readRange: async (id, { after, signal }) => {
        window.reads.push({ id, after });
        if (after === 0) return { batches: [batch(id, 0, 2)], next: 2 };
        return await new Promise((resolve, reject) => {
          signal.addEventListener("abort", () => window.cancelled++, {
            once: true,
          });
          window.release = () =>
            window.failed
              ? reject(Error("Temporary retrieval failure"))
              : resolve({ batches: [batch(id, 2, 4)], next: null });
        });
      },
      resolveArtifact: async () => ({
        api: 1,
        build: "v1",
        isolated_html: frame,
      }),
    };
    window.stop = createViewer(
      document.querySelector("#viewer"),
      window.viewerConfig,
    );
  });
  await expect(page.getByRole("button", { name: /Event 2.*#2/ })).toBeVisible();
  await expect(page.locator(".range-note")).toContainText(
    "loading more events",
  );
  if (new URL(page.url()).searchParams.get("t") !== "180000")
    throw Error("Pending deep link lost before later window");
  await expect.poll(() => page.evaluate(() => window.reads.length)).toBe(2);
  await page.getByRole("button", { name: /Event 2.*#2/ }).click();
  await expect(page.frameLocator("iframe").locator("output")).toHaveText("2");
  const firstFrame = await page.locator("iframe").getAttribute("name");
  await page.evaluate(() => window.release());
  await expect(
    page.getByRole("button", { name: "Retry loading remaining events" }),
  ).toBeVisible();
  await expect(page.frameLocator("iframe").locator("output")).toHaveText("2");
  await page.evaluate(() => (window.failed = false));
  await page
    .getByRole("button", { name: "Retry loading remaining events" })
    .click();
  await expect.poll(() => page.evaluate(() => window.reads.length)).toBe(3);
  await page.evaluate(() => window.release());
  await expect(page.getByRole("button", { name: /Event 4.*#4/ })).toBeVisible();
  await expect(page.frameLocator("iframe").locator("output")).toHaveText("2");
  await expect(page.locator(".clock")).toHaveText("2:00.0 / 4:00.0");
  if ((await page.locator("iframe").getAttribute("name")) !== firstFrame)
    throw Error("Window reload replaced the historical frame");
  await page.getByRole("button", { name: /two.*web · 4 events.*two/ }).click();
  await expect(page.locator(".session-heading h2")).toHaveText("two · Web");
  await expect(page.getByRole("button", { name: /Event 2.*#2/ })).toBeVisible();
  const late = await page.evaluateHandle(() => window.release);
  if (new URL(page.url()).searchParams.get("session") !== "two")
    throw Error("Selection URL not updated");
  await page.getByRole("button", { name: /one.*web · 4 events.*one/ }).click();
  await expect(page.locator(".session-heading h2")).toHaveText("one · Web");
  await late.evaluate((release) => release());
  await expect(page.locator(".count")).toHaveText("2");
  await expect
    .poll(() => page.evaluate(() => window.cancelled))
    .toBeGreaterThan(0);
  await page.evaluate(() => window.stop());
  await expect(page.locator("#viewer")).toBeEmpty();
  await page.evaluate(async () => {
    const { createViewer } = await import("/viewer.mjs");
    history.replaceState(null, "", "?session=one&t=180000");
    window.stop = createViewer(
      document.querySelector("#viewer"),
      window.viewerConfig,
    );
  });
  await expect(page.getByRole("button", { name: /Event 2.*#2/ })).toBeVisible();
  await expect(page.locator(".clock")).toHaveText("2:00.0 / 2:00.0");
  await expect
    .poll(() => page.evaluate(() => window.reads.at(-1).after))
    .toBe(2);
  await page.evaluate(() => window.release());
  await expect(page.locator(".clock")).toHaveText("3:00.0 / 4:00.0");
  await expect(page.frameLocator("iframe").locator("output")).toHaveText("3");
  await page.evaluate(() => window.stop());
  if (errors.length) throw Error(errors.join("\n"));
  console.log(
    "PASS progressive first paint, retained-prefix retry, stable playhead/frame, cancellation and stale-session fencing",
  );
} finally {
  await browser.close();
  server.close();
}
