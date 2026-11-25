import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import {
  startWith,
  enqueue,
  retry,
  stop,
  httpTransport,
  openSession,
} from "../src/client_ffi.mjs";
function memory() {
  const rows = new Map();
  return {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (key, body) => {
      rows.set(key, body);
    },
    remove: async (key) => {
      rows.delete(key);
    },
  };
}
const batch = (n = 0) =>
  JSON.stringify({
    session: { id: "inventory" },
    checkpoint: { sequence: n },
    entries: [{}],
  });
const until = async (predicate) => {
  for (let i = 0; i < 800; i++) {
    if (await predicate()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw Error("Timed out");
};
test("body timeout retains saved batch and permits retry", async () => {
  let calls = 0;
  const server = http.createServer((req, res) => {
    req.resume();
    calls++;
    res.writeHead(200, { "content-type": "application/json" });
    if (calls === 1) res.write('{"ack":');
    else res.end('{"session_id":"inventory","ack":1}');
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const store = memory(),
    statuses = [];
  const client = startWith(
    "queue",
    10,
    10000,
    (...s) => statuses.push(s),
    async () => store,
    httpTransport(`http://127.0.0.1:${server.address().port}`),
  );
  try {
    await new Promise((r) =>
      enqueue(client, batch(), (ok) => {
        assert.ok(ok);
        r();
      }),
    );
    await until(() => statuses.some((s) => /abort|timeout/i.test(s[2])));
    assert.equal((await store.all()).length, 1);
    retry(client);
    await until(() => statuses.some((s) => s[1] === 1));
    assert.equal((await store.all()).length, 0);
  } finally {
    stop(client);
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
});
test("pending item admission is bounded before slow persistence", async () => {
  let release;
  const ready = new Promise((r) => (release = r)),
    store = memory(),
    results = [];
  const client = startWith(
    "queue",
    1,
    10000,
    () => {},
    async () => {
      await ready;
      return store;
    },
    {
      send: async () => {
        throw Error("offline");
      },
    },
  );
  enqueue(client, batch(), (ok) => results.push(ok));
  enqueue(client, batch(1), (ok) => results.push(ok));
  assert.deepEqual(results, [false]);
  release();
  await until(() => results.length === 2);
  assert.deepEqual(results, [false, true]);
  assert.equal((await store.all()).length, 1);
  stop(client);
});
test("pending byte budget refuses oversized capture immediately", () => {
  const client = startWith(
    "queue",
    10,
    1,
    () => {},
    async () => memory(),
    {
      send: async () => {
        throw Error("offline");
      },
    },
  );
  let outcome;
  enqueue(client, batch(), (ok) => (outcome = ok));
  assert.equal(outcome, false);
  stop(client);
});
test("custom transport retains bad receipt and retries identical content", async () => {
  const store = memory(),
    sent = [],
    statuses = [];
  let valid = false;
  const client = startWith(
    "queue",
    10,
    10000,
    (...s) => statuses.push(s),
    async () => store,
    {
      send: async (body, signal) => {
        assert.ok(signal instanceof AbortSignal);
        sent.push(body);
        return JSON.stringify({ session_id: "inventory", ack: valid ? 1 : 99 });
      },
    },
  );
  try {
    enqueue(client, batch(), () => {});
    await until(() =>
      statuses.some((s) => s[2].includes("Invalid acknowledgement")),
    );
    assert.equal((await store.all()).length, 1);
    valid = true;
    retry(client);
    await until(() => statuses.some((s) => s[1] === 1));
    assert.equal(sent[0], sent[1]);
  } finally {
    stop(client);
  }
});

test("shutdown aborts a stalled body and a fresh runtime recovers the outbox", async () => {
  let accepted;
  const request = new Promise((resolve) => (accepted = resolve));
  const server = http.createServer((req, res) => {
    req.resume();
    res.writeHead(200);
    res.write('{"ack":');
    accepted();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const store = memory();
  const client = startWith(
    "queue",
    10,
    10000,
    () => {},
    async () => store,
    httpTransport(`http://127.0.0.1:${server.address().port}`),
  );
  let recovered;
  try {
    await new Promise((resolve) =>
      enqueue(client, batch(), (ok) => {
        assert.ok(ok);
        resolve();
      }),
    );
    await request;
    stop(client);
    assert.equal((await store.all()).length, 1);
    let acknowledged = 0;
    recovered = startWith(
      "queue",
      10,
      10000,
      (_, ack) => {
        acknowledged = ack;
      },
      async () => store,
      { send: async () => '{"session_id":"inventory","ack":1}' },
    );
    await until(() => acknowledged === 1);
    assert.equal((await store.all()).length, 0);
  } finally {
    stop(client);
    if (recovered) stop(recovered);
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("an unanswered session request is retried before uploads, and its grant reaches the caller once", async () => {
  const requests = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      requests.push([req.url, body]);
      if (requests.length === 1) {
        res.writeHead(503).end();
        return;
      }
      res.writeHead(201, { "content-type": "application/json" });
      res.end('{"session":{"id":"issued"},"token":"t"}');
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const grants = [];
  const client = startWith(
    "queue",
    10,
    10000,
    () => {},
    async () => memory(),
    httpTransport(`http://127.0.0.1:${server.address().port}`),
  );
  try {
    openSession(client, '{"user_ref":"ada"}', (...grant) => grants.push(grant));
    await until(() => requests.length === 1);
    retry(client);
    await until(() => grants.length === 1);
    assert.deepEqual(requests, [
      ["/sessions", '{"user_ref":"ada"}'],
      ["/sessions", '{"user_ref":"ada"}'],
    ]);
    assert.deepEqual(grants, [
      [true, '{"session":{"id":"issued"},"token":"t"}'],
    ]);
    retry(client);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(requests.length, 2);
  } finally {
    stop(client);
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
});
