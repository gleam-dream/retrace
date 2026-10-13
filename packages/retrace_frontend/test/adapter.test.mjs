import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import * as viewer from "../build/dev/javascript/retrace_frontend/retrace_frontend/viewer.mjs";
import { Session } from "../build/dev/javascript/retrace/retrace/wire.mjs";
// Consume the public Task callback contract directly.
const request = (task) =>
  new Promise((resolve, reject) => {
    task((result) =>
      result.isOk() ? resolve(result[0]) : reject(Error(result[0])),
    );
  });
const session = {
  id: "test-session",
  user_ref: "Ada",
  build: "build-a",
  contract: "v1",
  platform: "web",
};
test("default collector and artifact readers preserve identity and report errors", async () => {
  const server = http.createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url.startsWith("/sessions?"))
      res.end(JSON.stringify([{ session, sequence: 1 }]));
    else if (req.url.includes("/batches?after=0"))
      res.end(
        JSON.stringify([
          JSON.stringify({
            session,
            checkpoint: { sequence: 0 },
            entries: [{ sequence: 1 }],
          }),
          JSON.stringify({
            session,
            checkpoint: { sequence: 1 },
            entries: [{ sequence: 2 }],
          }),
        ]),
      );
    else if (req.url === "/build-a/manifest.json")
      res.end(
        JSON.stringify({
          api: 1,
          build: "build-a",
          contract: "v1",
          url: "/frame.html",
        }),
      );
    else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    const base = `http://127.0.0.1:${server.address().port}`,
      source = viewer.collector(base);
    const rows = await request(source.list_sessions("Ada"));
    assert.equal(rows.toArray()[0].session.build, "build-a");
    const page = await request(source.read_range("test-session", 0, 128));
    assert.equal(page.batches.toArray().length, 2);
    const small = await request(source.read_range("test-session", 0, 1));
    assert.equal(small.batches.toArray().length, 1);
    assert.equal(small.next[0], 1);
    const resolve = viewer.artifacts(base),
      s = new Session(...Object.values(session));
    assert.equal((await request(resolve(s))).url, "/frame.html");
    await assert.rejects(
      request(resolve(new Session("x", "Ada", "missing", "v1", "web"))),
      /unavailable/,
    );
    await assert.rejects(
      request(resolve(new Session("x", "Ada", "build-a", "wrong", "web"))),
      /match/,
    );
    const dev = viewer.with_development(resolve, "dev", "v1", "/dev.html");
    assert.equal(
      (await request(dev(new Session("x", "Ada", "dev", "v1", "web"))))
        .development,
      true,
    );
  } finally {
    await new Promise((r) => server.close(r));
  }
});
