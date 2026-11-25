// Real-browser gate for the packaged IndexedDB queue; needs no service.
// npm --prefix examples/advanced test -- storage-browser-check
// RETRACE_CLIENT_FFI=/path/to/client_ffi.mjs times another revision.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { test } from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const source =
  process.env.RETRACE_CLIENT_FFI ||
  new URL("../packages/retrace_frontend/src/client_ffi.mjs", import.meta.url);
let origin;
const server = createServer(async (request, response) => {
  if (request.url === "/client_ffi.mjs") {
    response.setHeader("content-type", "text/javascript");
    response.end(await readFile(source));
  } else {
    response.setHeader("content-type", "text/html");
    response.end("<html><body>storage</body></html>");
  }
});
test.beforeAll(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(() => new Promise((resolve) => server.close(resolve)));

test("storage-browser-check: limits hold for one and for two writers", async ({
  page,
}) => {
  await page.goto(origin);
  const outcome = await page.evaluate(async () => {
    const { browserStorage } = await import("/client_ffi.mjs");
    const attempt = (work) =>
      work.then(
        () => "saved",
        (error) => error.message,
      );
    const open = browserStorage();
    const first = await open("limits", 3, 40);
    const second = await open("limits", 3, 40);
    const log = [];
    log.push(await attempt(first.put("a", "0123456789")));
    log.push(await attempt(first.put("a", "0123456789"))); // identical retry
    log.push(await attempt(first.put("a", "different!"))); // conflict
    log.push(await attempt(second.put("b", "0123456789"))); // other writer
    log.push(await attempt(first.put("c", "éééééééééééé"))); // 24 UTF-8 bytes
    log.push(await attempt(first.put("c", "0123456789")));
    log.push(await attempt(first.put("d", "0"))); // item limit
    log.push(await attempt(first.put("a", "0123456789"))); // retry when full
    await second.remove("b");
    log.push(await attempt(first.put("d", "0123456789")));
    log.push(await attempt(first.put("e", "0"))); // items again
    await first.remove("a");
    log.push(await attempt(first.put("e", "012345678901234567890"))); // 41 bytes
    log.push(await attempt(first.put("e", "0123456789")));
    const keys = (await second.all()).map((row) => row.key).sort();
    first.close();
    second.close();
    return { log, keys };
  });
  assert.deepEqual(outcome.log, [
    "saved",
    "saved",
    "Conflicting local batch",
    "saved",
    "Recording queue is full",
    "saved",
    "Recording queue is full",
    "saved",
    "saved",
    "Recording queue is full",
    "Recording queue is full",
    "saved",
  ]);
  assert.deepEqual(outcome.keys, ["c", "d", "e"]);
});

test("storage-browser-check: a save does not read the saved bodies", async ({
  page,
}) => {
  await page.goto(origin);
  const outcome = await page.evaluate(async () => {
    const { browserStorage } = await import("/client_ffi.mjs");
    let bodyReads = 0;
    const getAll = IDBObjectStore.prototype.getAll;
    IDBObjectStore.prototype.getAll = function (...args) {
      bodyReads++;
      return getAll.apply(this, args);
    };
    const store = await browserStorage()("cost", 100000, 1e9);
    const body = "x".repeat(4000);
    const key = (n) => `bench:${String(n).padStart(16, "0")}`;
    const opened = bodyReads;
    const started = performance.now();
    for (let n = 0; n < 1000; n++) await store.put(key(n), body + n);
    const elapsed = performance.now() - started;
    const saved = (await store.all()).length;
    store.close();
    return { bodyReads: bodyReads - opened - 1, elapsed, saved };
  });
  console.log(
    `1000 saves of 4 KB into IndexedDB: wall_ms=${outcome.elapsed.toFixed(0)} whole_store_reads=${outcome.bodyReads}`,
  );
  assert.equal(outcome.saved, 1000);
  if (!process.env.RETRACE_CLIENT_FFI) assert.equal(outcome.bodyReads, 0);
});
