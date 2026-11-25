// Real-browser gate for the hand-over when a page ends; needs no service.
// npm --prefix examples/advanced test -- unload-browser-check
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { test } from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const source = new URL(
  "../packages/retrace_frontend/src/client_ffi.mjs",
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
