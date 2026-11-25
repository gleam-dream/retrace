// Real-browser gate for the hand-over when a page ends; needs no service. The
// capture case loads the built frontend: run `gleam build` in
// packages/retrace_frontend first.
// npm --prefix examples/advanced test -- unload-browser-check
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { test } from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const source = new URL(
  "../packages/retrace_frontend/src/client_ffi.mjs",
  import.meta.url,
);
const built = new URL(
  "../packages/retrace_frontend/build/dev/javascript/",
  import.meta.url,
);
const posts = [];
let origin;
const server = createServer(async (request, response) => {
  if (request.method === "POST") {
    let body = "";
    request.on("data", (chunk) => (body += chunk));
    request.on("end", () => {
      posts.push(JSON.parse(body).checkpoint.sequence);
      // The collector never answers, as when a page leaves mid-upload.
    });
  } else if (request.url === "/client_ffi.mjs") {
    response.setHeader("content-type", "text/javascript");
    response.end(await readFile(source));
  } else if (request.url.startsWith("/built/")) {
    const file = new URL(request.url.slice("/built/".length), built);
    if (!file.href.startsWith(built.href)) return response.end();
    response.setHeader("content-type", "text/javascript");
    response.end(await readFile(file));
  } else {
    response.setHeader("content-type", "text/html");
    response.end("<html><body>page</body></html>");
  }
});
test.beforeAll(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
const arrived = async (count) => {
  for (let turn = 0; turn < 100 && posts.length < count; turn++)
    await new Promise((resolve) => setTimeout(resolve, 50));
  return posts.length >= count;
};

test("unload-browser-check: batches not yet acknowledged are sent again as the page leaves", async ({
  page,
}) => {
  await page.goto(origin);
  await page.evaluate(async (endpoint) => {
    const { startWith, enqueue, browserStorage, httpTransport } =
      await import("/client_ffi.mjs");
    const client = startWith(
      "unload",
      10,
      1000000,
      () => {},
      browserStorage(),
      httpTransport(endpoint),
    );
    const body = (sequence) =>
      JSON.stringify({
        session: { id: "leaving" },
        checkpoint: { sequence },
        entries: [{}],
      });
    await new Promise((saved) => enqueue(client, body(0), saved));
    await new Promise((saved) => enqueue(client, body(1), saved));
  }, origin);
  // The upload loop sent the first batch and waits for its acknowledgement;
  // the second is saved and has never been sent.
  assert.ok(await arrived(1));
  assert.deepEqual(posts, [0]);
  await page.goto(`${origin}/elsewhere`);
  assert.ok(await arrived(3), `collector received ${JSON.stringify(posts)}`);
  assert.deepEqual(posts.slice(1).sort(), [0, 1]);
});

test("unload-browser-check: the open capture batch leaves with the page", async ({
  page,
}) => {
  posts.length = 0;
  await page.goto(origin);
  await page.evaluate(async (endpoint) => {
    const { startWith, enqueue, browserStorage, httpTransport } =
      await import("/built/retrace_frontend/client_ffi.mjs");
    const { buffer, bufferAdd } =
      await import("/built/retrace_frontend/capture_ffi.mjs");
    const client = startWith(
      "unload-capture",
      10,
      1000000,
      () => {},
      browserStorage(),
      httpTransport(endpoint),
    );
    // Two observations held in the open batch of a one-minute window.
    for (const sequence of [1, 2])
      bufferAdd(
        buffer(client),
        { sequence },
        100,
        () => [{ sequence: 0 }, 10],
        60000,
        128,
        500000,
        (checkpoint, entries) =>
          enqueue(
            client,
            JSON.stringify({
              session: { id: "capturing" },
              checkpoint,
              entries: entries.toArray(),
            }),
            () => {},
          ),
      );
  }, origin);
  assert.deepEqual(posts, []);
  await page.goto(`${origin}/elsewhere`);
  assert.ok(await arrived(1), "the open batch was not handed over");
  assert.deepEqual(posts, [0]);
});
