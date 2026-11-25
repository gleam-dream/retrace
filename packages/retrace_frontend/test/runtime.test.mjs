import { test, mock } from "node:test";
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
// A transport that only uploads; these checks never open a session.
const send = (upload) => ({ send: upload });
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
    send(async () => {
      throw Error("offline");
    }),
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
    send(async () => {
      throw Error("offline");
    }),
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
    send(async (body, signal) => {
      assert.ok(signal instanceof AbortSignal);
      sent.push(body);
      return JSON.stringify({ session_id: "inventory", ack: valid ? 1 : 99 });
    }),
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
      send(async () => '{"session_id":"inventory","ack":1}'),
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
      send(async () => {
        times.push(now);
        throw Error("offline");
      }),
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
    send(async (body) => {
      times.push(now);
      if (!online) throw Error("offline");
      const sent = JSON.parse(body);
      return JSON.stringify({
        session_id: "inventory",
        ack: sent.checkpoint.sequence + 1,
      });
    }),
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
    send(async () => {
      attempts++;
      throw Error("offline");
    }),
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

// A store that counts how often and how much the runtime reads from it.
function counting() {
  const store = memory(),
    reads = { calls: 0, rows: 0 };
  return {
    ...store,
    reads,
    all: async () => {
      const rows = await store.all();
      reads.calls++;
      reads.rows += rows.length;
      return rows;
    },
  };
}
const acknowledge = async (body) => {
  const sent = JSON.parse(body);
  return JSON.stringify({
    session_id: sent.session.id,
    ack: sent.checkpoint.sequence + sent.entries.length,
  });
};

test("an idle client neither wakes nor repeats its status", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  const store = counting(),
    statuses = [];
  const client = startWith(
    "queue",
    10,
    10000,
    (...s) => statuses.push(s),
    async () => store,
    send(acknowledge),
  );
  try {
    await settle();
    assert.deepEqual(statuses, [[0, 0, "All saved entries delivered"]]);
    const reads = store.reads.calls;
    for (let second = 0; second < 60; second++) {
      mock.timers.tick(1000);
      await settle();
    }
    assert.equal(store.reads.calls, reads);
    assert.equal(statuses.length, 1);
    // Work still starts a pass at once, and each status is reported once.
    await new Promise((r) => enqueue(client, batch(), r));
    await settle();
    await settle();
    assert.deepEqual(statuses.slice(1), [
      [1, 0, "Uploading saved recording"],
      [0, 1, "All saved entries delivered"],
    ]);
    assert.equal((await store.all()).length, 0);
  } finally {
    stop(client);
    mock.timers.reset();
  }
});

test("draining a backlog reads storage per pass, not per batch", async () => {
  const store = counting();
  for (let n = 0; n < 200; n++)
    await store.put(`inventory:${String(n).padStart(16, "0")}`, batch(n));
  let acknowledged = 0;
  const client = startWith(
    "queue",
    1000,
    1000000,
    (_, ack) => (acknowledged = ack),
    async () => store,
    send(acknowledge),
  );
  try {
    await until(() => acknowledged === 200);
    await until(() => store.reads.calls >= 2);
    // One read for the backlog and one that finds the queue empty.
    assert.equal(store.reads.calls, 2);
    assert.equal(store.reads.rows, 200);
  } finally {
    stop(client);
  }
});

test("a batch saved while a pass is finishing is uploaded without a timer", async () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  const store = memory();
  let acknowledged = 0,
    hold = null,
    reads = 0;
  const gated = {
    ...store,
    // The third read is the one that finds the queue empty after the first
    // upload; hold its result so a save lands before the pass ends.
    all: async () => {
      const rows = await store.all();
      if (++reads === 3) await new Promise((r) => (hold = r));
      return rows;
    },
  };
  const client = startWith(
    "queue",
    10,
    10000,
    (_, ack) => (acknowledged = ack),
    async () => gated,
    send(acknowledge),
  );
  try {
    await settle();
    await new Promise((r) => enqueue(client, batch(0), r));
    for (let n = 0; n < 5 && !hold; n++) await settle();
    assert.ok(hold);
    await new Promise((r) => enqueue(client, batch(1), r));
    hold();
    for (let n = 0; n < 5; n++) await settle();
    assert.equal(acknowledged, 2);
    assert.equal((await store.all()).length, 0);
  } finally {
    stop(client);
    mock.timers.reset();
  }
});

test("the reported queue length follows uploads and discards within one pass", async () => {
  const store = memory(),
    statuses = [];
  await store.put("erased:0000000000000000", batch(0, "erased"));
  await store.put("erased:0000000000000001", batch(1, "erased"));
  await store.put("inventory:0000000000000000", batch(0));
  await store.put("inventory:0000000000000001", batch(1));
  const client = startWith(
    "queue",
    10,
    10000,
    (...s) => statuses.push(s),
    async () => store,
    send(async (body) => {
      const sent = JSON.parse(body);
      if (sent.session.id !== "erased") return acknowledge(body);
      throw Object.assign(Error("Session erased"), { rejected: true });
    }),
  );
  try {
    await until(() => statuses.some((s) => s[1] === 2 && s[0] === 0));
    assert.deepEqual(
      statuses.map((s) => [s[0], s[1]]),
      [
        [4, 0],
        [2, 0],
        [2, 0],
        [1, 1],
        [0, 2],
      ],
    );
    assert.match(statuses.at(-1)[2], /Rejected recording discarded/);
  } finally {
    stop(client);
  }
});

// A page stand-in: the runtime listens on `document` when one exists.
function page(t) {
  const document = new EventTarget();
  document.visibilityState = "visible";
  const previous = globalThis.document;
  globalThis.document = document;
  t.after(() => {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  });
  return {
    hide() {
      document.visibilityState = "hidden";
      document.dispatchEvent(new Event("visibilitychange"));
    },
    show() {
      document.visibilityState = "visible";
      document.dispatchEvent(new Event("visibilitychange"));
    },
  };
}
const sized = (n, bytes) =>
  JSON.stringify({
    session: { id: "inventory" },
    checkpoint: { sequence: n, model: "x".repeat(bytes) },
    entries: [{}],
  });
const sequences = (bodies) =>
  bodies.map((body) => JSON.parse(body).checkpoint.sequence);

test("a hidden page hands unacknowledged batches to the transport's keepalive send", async (t) => {
  const tab = page(t),
    store = memory(),
    handed = [];
  let online = false,
    acknowledged = 0;
  const transport = send(async (body, signal) => {
    if (online) return acknowledge(body);
    // A stalled upload: it ends only when the runtime aborts it.
    return new Promise((_, reject) =>
      signal.addEventListener("abort", () => reject(Error("aborted"))),
    );
  });
  transport.keepalive = (body) => handed.push(body);
  const client = startWith(
    "queue",
    100,
    1000000,
    (_, ack) => (acknowledged = ack),
    async () => store,
    transport,
  );
  let recovered;
  try {
    await settle();
    tab.hide();
    assert.deepEqual(handed, []);
    tab.show();
    await new Promise((r) => enqueue(client, batch(0), r));
    // Still being saved when the page hides: handed over from memory.
    enqueue(client, batch(1), () => {});
    tab.hide();
    assert.deepEqual(sequences(handed), [0, 1]);
    // Each batch is handed over once; the upload loop owns later retries.
    tab.show();
    tab.hide();
    assert.equal(handed.length, 2);
    // Shutdown aborts the regular upload, not what was handed over, and the
    // batches stay saved until a matching acknowledgement.
    await settle();
    stop(client);
    await settle();
    assert.equal((await store.all()).length, 2);
    tab.show();
    tab.hide();
    assert.equal(handed.length, 2);
    online = true;
    recovered = startWith(
      "queue",
      100,
      1000000,
      (_, ack) => (acknowledged = ack),
      async () => store,
      transport,
    );
    await until(() => acknowledged === 2);
    tab.show();
    tab.hide();
    assert.equal(handed.length, 2);
  } finally {
    stop(client);
    if (recovered) stop(recovered);
  }
});

test("the hand-over keeps batch order and stays within the keepalive budget", async (t) => {
  const tab = page(t),
    store = memory(),
    handed = [];
  let online = false,
    acknowledged = 0;
  const transport = send(async (body) => {
    if (!online) throw Error("offline");
    return acknowledge(body);
  });
  transport.keepalive = (body) => handed.push(body);
  const client = startWith(
    "queue",
    100,
    1000000,
    (_, ack) => (acknowledged = ack),
    async () => store,
    transport,
  );
  const save = (body) => new Promise((r) => enqueue(client, body, r));
  try {
    await settle();
    // 64 KiB is the browser's limit for keepalive bodies in flight.
    await save(sized(0, 30000));
    await save(sized(1, 30000));
    await save(sized(2, 30000));
    await save(sized(3, 100));
    tab.hide();
    // Batch 2 does not fit, and batch 3 must not overtake it.
    assert.deepEqual(sequences(handed), [0, 1]);
    tab.show();
    online = true;
    retry(client);
    await until(() => acknowledged === 4);
    // Once the queue has drained, later batches are handed over again.
    online = false;
    await save(sized(4, 100));
    tab.hide();
    assert.deepEqual(sequences(handed), [0, 1, 4]);
  } finally {
    stop(client);
  }
});

test("a transport without a keepalive send is left alone when the page hides", async (t) => {
  const tab = page(t),
    store = memory();
  const client = startWith(
    "queue",
    10,
    10000,
    () => {},
    async () => store,
    send(async () => {
      throw Error("offline");
    }),
  );
  try {
    await new Promise((r) => enqueue(client, batch(), r));
    tab.hide();
    assert.equal((await store.all()).length, 1);
  } finally {
    stop(client);
  }
});

test("the packaged transport's keepalive send posts the batch and ignores the outcome", async () => {
  const received = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      received.push([req.method, req.url, req.headers["content-type"], body]);
      res.writeHead(503);
      res.end();
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    const transport = httpTransport(
      `http://127.0.0.1:${server.address().port}/`,
    );
    transport.keepalive(batch(7));
    await until(() => received.length === 1);
    assert.deepEqual(received[0], [
      "POST",
      "/batches",
      "application/json",
      batch(7),
    ]);
  } finally {
    await new Promise((r) => server.close(r));
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

test("a refused session request is reported once and not retried", async () => {
  let requests = 0;
  const server = http.createServer((req, res) => {
    req.resume();
    requests++;
    res.writeHead(400, { "content-type": "application/json" });
    res.end('{"error":"Invalid recording request"}');
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
    openSession(client, "{}", (...grant) => grants.push(grant));
    await until(() => grants.length === 1);
    assert.equal(grants[0][0], false);
    assert.match(grants[0][1], /rejected/i);
    retry(client);
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(requests, 1);
  } finally {
    stop(client);
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
});
