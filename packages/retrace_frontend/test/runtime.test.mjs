import { test, mock } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import {
  startWith,
  enqueue,
  retry,
  stop,
  httpTransport,
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
const batch = (n = 0, id = "inventory") =>
  JSON.stringify({
    session: { id },
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
    async () => {
      throw Error("offline");
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
    async () => {
      throw Error("offline");
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
    async (body, signal) => {
      assert.ok(signal instanceof AbortSignal);
      sent.push(body);
      return JSON.stringify({ session_id: "inventory", ack: valid ? 1 : 99 });
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
      async () => '{"session_id":"inventory","ack":1}',
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

test("a permanently rejected session is discarded so later sessions deliver", async () => {
  const requests = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const { session, checkpoint } = JSON.parse(body);
      requests.push(session.id);
      if (session.id === "erased") {
        res.writeHead(404, { "content-type": "application/json" });
        res.end('{"error":"Session not found"}');
      } else {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            session_id: session.id,
            ack: checkpoint.sequence + 1,
          }),
        );
      }
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const store = memory(),
    statuses = [];
  // Rows left by an earlier page load, drained in key order: "erased" first.
  await store.put("erased:0000000000000000", batch(0, "erased"));
  await store.put("erased:0000000000000001", batch(1, "erased"));
  await store.put("inventory:0000000000000000", batch(0));
  const client = startWith(
    "queue",
    10,
    10000,
    (...s) => statuses.push(s),
    async () => store,
    httpTransport(`http://127.0.0.1:${server.address().port}`),
  );
  try {
    await until(() => statuses.some((s) => s[1] === 1));
    await until(async () => (await store.all()).length === 0);
    // One refusal settles the whole session: its second batch is never sent.
    assert.deepEqual(requests, ["erased", "inventory"]);
    assert.ok(statuses.some((s) => /rejected/i.test(s[2])));
    // The live writer of a rejected session learns that capture has stopped.
    const outcome = await new Promise((r) =>
      enqueue(client, batch(2, "erased"), (ok, message) => r([ok, message])),
    );
    assert.equal(outcome[0], false);
    assert.match(outcome[1], /rejected/i);
    assert.equal((await store.all()).length, 0);
  } finally {
    stop(client);
    await new Promise((r) => server.close(r));
  }
});

test("an unauthorized, throttled or failing collector keeps the batch for a later retry", async () => {
  for (const status of [401, 403, 408, 429, 503]) {
    let calls = 0;
    const server = http.createServer((req, res) => {
      req.resume();
      calls++;
      res.writeHead(calls === 1 ? status : 200);
      res.end('{"session_id":"inventory","ack":1}');
    });
    await new Promise((r) => server.listen(0, "127.0.0.1", r));
    const store = memory(),
      statuses = [];
    await store.put("inventory:0000000000000000", batch());
    const client = startWith(
      "queue",
      10,
      10000,
      (...s) => statuses.push(s),
      async () => store,
      httpTransport(`http://127.0.0.1:${server.address().port}`),
    );
    try {
      await until(() => calls === 1 && statuses.length >= 2);
      assert.equal((await store.all()).length, 1, `status ${status}`);
      retry(client);
      await until(() => statuses.some((s) => s[1] === 1));
      assert.equal((await store.all()).length, 0);
    } finally {
      stop(client);
      await new Promise((r) => server.close(r));
    }
  }
});

const settle = () => new Promise((r) => setImmediate(r));
test("failed uploads back off exponentially with jitter up to a cap", async () => {
  const attempts = async (random, simulatedMs) => {
    mock.timers.enable({ apis: ["setTimeout"] });
    mock.method(Math, "random", () => random);
    const store = memory();
    await store.put("inventory:0000000000000000", batch());
    const times = [];
    let now = 0;
    const client = startWith(
      "queue",
      10,
      10000,
      () => {},
      async () => store,
      async () => {
        times.push(now);
        throw Error("offline");
      },
    );
    try {
      await settle();
      while (now < simulatedMs) {
        now += 250;
        mock.timers.tick(250);
        await settle();
      }
      return times;
    } finally {
      stop(client);
      mock.timers.reset();
      mock.restoreAll();
    }
  };
  // Largest jitter: each wait is the full exponential step, capped at 60 s.
  assert.deepEqual(
    await attempts(1, 300000),
    [0, 1500, 4500, 10500, 22500, 46500, 94500, 154500, 214500, 274500],
  );
  // Smallest jitter halves every wait, so clients spread over that range.
  assert.deepEqual(await attempts(0, 12000), [0, 750, 2250, 5250, 11250]);
});

test("a delivered batch resets the backoff", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  mock.method(Math, "random", () => 1);
  const store = memory();
  await store.put("inventory:0000000000000000", batch());
  const times = [];
  let now = 0,
    online = false;
  const client = startWith(
    "queue",
    10,
    10000,
    () => {},
    async () => store,
    async (body) => {
      times.push(now);
      if (!online) throw Error("offline");
      const sent = JSON.parse(body);
      return JSON.stringify({
        session_id: "inventory",
        ack: sent.checkpoint.sequence + 1,
      });
    },
  );
  const advance = async (ms) => {
    for (const end = now + ms; now < end;) {
      now += 250;
      mock.timers.tick(250);
      await settle();
    }
  };
  try {
    await settle();
    await advance(4500);
    assert.deepEqual(times, [0, 1500, 4500]);
    online = true;
    await advance(6000);
    assert.deepEqual(times, [0, 1500, 4500, 10500]);
    online = false;
    await store.put("inventory:0000000000000001", batch(1));
    retry(client);
    await settle();
    const failedAt = now;
    await advance(1500);
    assert.deepEqual(times.slice(4), [failedAt, failedAt + 1500]);
  } finally {
    stop(client);
    mock.timers.reset();
    mock.restoreAll();
  }
});

test("a save during a backoff wait does not start another upload attempt", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  mock.method(Math, "random", () => 1);
  const store = memory();
  await store.put("inventory:0000000000000000", batch());
  let attempts = 0;
  const client = startWith(
    "queue",
    10,
    10000,
    () => {},
    async () => store,
    async () => {
      attempts++;
      throw Error("offline");
    },
  );
  try {
    await settle();
    assert.equal(attempts, 1);
    for (let n = 1; n <= 3; n++) {
      await new Promise((r) => enqueue(client, batch(n), r));
      await settle();
    }
    assert.equal((await store.all()).length, 4);
    assert.equal(attempts, 1);
    // The wait still ends on time, and an explicit retry does not wait.
    mock.timers.tick(1500);
    await settle();
    assert.equal(attempts, 2);
    retry(client);
    await settle();
    assert.equal(attempts, 3);
  } finally {
    stop(client);
    mock.timers.reset();
    mock.restoreAll();
  }
});
