import { test } from "node:test";
import assert from "node:assert/strict";
import * as capture from "../build/dev/javascript/retrace_frontend/retrace_frontend/capture.mjs";
import { Config } from "../build/dev/javascript/retrace_frontend/retrace_frontend/client.mjs";
import {
  Event,
  Metadata,
} from "../build/dev/javascript/retrace/retrace/wire.mjs";
import { perform } from "../build/dev/javascript/lustre/lustre/effect.mjs";
import {
  Result$Ok,
  Result$Error,
} from "../build/dev/javascript/retrace_frontend/gleam.mjs";
const until = async (f) => {
  for (let n = 0; n < 100; n++) {
    if (f()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw Error("timeout");
};
// A collector stand-in that issues one session and answers uploads with send.
const collector = (send, id = "issued-1") => ({
  open: async (metadata) =>
    JSON.stringify({
      session: { id, ...JSON.parse(metadata) },
      token: "token-1",
    }),
  send,
});
const refuse = (reason) => async () => {
  throw Error(reason);
};
const run = (effect, dispatch) =>
  perform(
    effect,
    dispatch,
    () => {},
    () => {},
    () => {},
    () => {},
    () => {},
    () => {},
  );
test("failed projection never reaches codecs or delivery and stops capture without copying its error", () => {
  let [state] = capture.start_with_clock(
    new Metadata("opaque", "build", "contract", "web"),
    new Config("local", "projection", 10, 10000),
    async () => {
      throw Error("must not open");
    },
    { open: refuse("must not open"), send: refuse("must not upload") },
    0,
    () => {
      throw Error("must not read clock");
    },
  )[0];
  const encode = () => {
    throw Error("must not encode");
  };
  let effect;
  [state, effect] = capture.observe_projected(
    state,
    Result$Error("PRIVATE-PROJECTION-SENTINEL"),
    encode,
    encode,
  );
  run(effect, () => {
    throw Error("must not dispatch");
  });
  assert.equal(capture.info(state).captured, 0);
  assert.equal(
    capture.info(state).failure[0],
    "Safe projection failed. Start a new session.",
  );
  [state, effect] = capture.observe_projected(
    state,
    Result$Ok([{}, {}]),
    encode,
    encode,
  );
  run(effect, () => {
    throw Error("must not dispatch");
  });
  assert.equal(capture.info(state).captured, 0);
});
test("capture persists typed observations in order, keeps status out of history, and stops on clock failure", async () => {
  let now = 5,
    state;
  const received = [];
  const rows = new Map();
  const store = {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (k, b) => rows.set(k, b),
    remove: async (k) => rows.delete(k),
  };
  const transport = collector(async (body) => {
    const b = JSON.parse(body);
    received.push(b);
    return JSON.stringify({
      session_id: b.session.id,
      ack: b.entries.at(-1).sequence,
    });
  });
  const result = capture.start_with_clock(
    new Metadata("Ada", "test-build", "test-v1", "web"),
    new Config("local", "test", 10, 10000),
    async () => store,
    transport,
    0,
    () => now,
  );
  assert(result.isOk());
  let effect;
  [state, effect] = result[0];
  const dispatch = (m) => (state = capture.update(state, m));
  run(effect, dispatch);
  await until(() => capture.info(state).session[0]);
  const observe = (before, event) => {
    [state, effect] = capture.observe(
      state,
      before,
      event,
      JSON.stringify,
      (n) => new Event("Add", JSON.stringify(n)),
    );
    run(effect, dispatch);
  };
  observe({ value: 0 }, 2);
  now = 9;
  observe({ value: 2 }, 3);
  await until(() => capture.info(state).saved === 2 && received.length === 2);
  assert.deepEqual(
    received.map((b) => [
      b.checkpoint.sequence,
      b.entries[0].sequence,
      b.entries[0].elapsed_ms,
    ]),
    [
      [0, 1, 5],
      [1, 2, 9],
    ],
  );
  assert.equal(received[1].checkpoint.model, '{"value":2}');
  assert.deepEqual(
    received.map((b) => [b.session.id, b.token]),
    [
      ["issued-1", "token-1"],
      ["issued-1", "token-1"],
    ],
  );
  now = 1;
  observe({ value: 5 }, 4);
  assert.equal(capture.info(state).captured, 2);
  assert.match(capture.info(state).failure[0], /time/);
  now = 12;
  observe({ value: 9 }, 1);
  assert.equal(capture.info(state).captured, 2);
  run(capture.stop(state), dispatch);
});
test("capture records nothing until the collector has opened the session", async () => {
  let state, effect, connect;
  const received = [];
  let grant;
  const opened = new Promise((r) => (grant = r));
  const rows = new Map();
  [state, connect] = capture.start_with_clock(
    new Metadata("Ada", "build", "contract", "web"),
    new Config("x", "x", 10, 10000),
    async () => ({
      all: async () => [...rows].map(([key, body]) => ({ key, body })),
      put: async (k, b) => void rows.set(k, b),
      remove: async (k) => void rows.delete(k),
    }),
    {
      open: async (metadata) => {
        await opened;
        return JSON.stringify({
          session: { id: "issued-2", ...JSON.parse(metadata) },
          token: "token-2",
        });
      },
      send: async (body) => {
        const b = JSON.parse(body);
        received.push(b);
        return JSON.stringify({ session_id: b.session.id, ack: 1 });
      },
    },
    0,
    () => 3,
  )[0];
  const dispatch = (m) => (state = capture.update(state, m));
  const observe = (before, event) => {
    [state, effect] = capture.observe(
      state,
      before,
      event,
      JSON.stringify,
      (n) => new Event("Add", String(n)),
    );
    run(effect, dispatch);
  };
  observe({ value: 0 }, 1);
  run(connect, dispatch);
  observe({ value: 1 }, 2);
  assert.equal(capture.info(state).captured, 0);
  assert.equal(capture.info(state).session[0], undefined);
  assert.equal(capture.info(state).failure[0], undefined);
  grant();
  await until(() => capture.info(state).session[0]);
  assert.equal(capture.info(state).session[0].id, "issued-2");
  observe({ value: 3 }, 4);
  await until(() => received.length === 1);
  assert.equal(received[0].checkpoint.sequence, 0);
  assert.equal(received[0].checkpoint.model, '{"value":3}');
  assert.equal(received[0].token, "token-2");
  run(capture.stop(state), dispatch);
});

test("capture refuses invalid metadata before starting anything", () => {
  const result = capture.start_with_clock(
    new Metadata("", "build", "contract", "web"),
    new Config("x", "x", 1, 100),
    async () => {
      throw Error("must not open");
    },
    { open: refuse("must not open"), send: refuse("must not upload") },
    0,
    () => 0,
  );
  assert.ok(!result.isOk());
});

test("persistence failure remains visible and stops subsequent capture", async () => {
  let state, effect;
  const store = {
    all: async () => [],
    put: async () => {
      throw Error("Disk full");
    },
    remove: async () => {},
  };
  [state, effect] = capture.start_with_clock(
    new Metadata("Ada", "build", "contract", "web"),
    new Config("x", "x", 2, 10000),
    async () => store,
    collector(refuse("must not upload")),
    0,
    () => 1,
  )[0];
  const dispatch = (m) => (state = capture.update(state, m));
  run(effect, dispatch);
  await until(() => capture.info(state).session[0]);
  [state, effect] = capture.observe(
    state,
    { value: 0 },
    1,
    JSON.stringify,
    (n) => new Event("Add", String(n)),
  );
  run(effect, dispatch);
  await until(() => capture.info(state).failure[0]);
  assert.match(capture.info(state).failure[0], /Disk full/);
  assert.equal(capture.info(state).saved, 0);
  [state, effect] = capture.observe(
    state,
    { value: 1 },
    2,
    JSON.stringify,
    (n) => new Event("Add", String(n)),
  );
  run(effect, dispatch);
  assert.equal(capture.info(state).captured, 1);
  run(capture.stop(state), dispatch);
});

test("a collector that refuses to open the session stops capture visibly", async () => {
  let state;
  const refusal = Error("Collector rejected the recording (HTTP 400)");
  refusal.rejected = true;
  const [initial, connect] = capture.start_with_clock(
    new Metadata("Ada", "build", "contract", "web"),
    new Config("x", "x", 10, 10000),
    async () => ({
      all: async () => [],
      put: async () => {},
      remove: async () => {},
    }),
    {
      open: async () => {
        throw refusal;
      },
      send: refuse("must not upload"),
    },
    0,
    () => 0,
  )[0];
  state = initial;
  const dispatch = (m) => (state = capture.update(state, m));
  run(connect, dispatch);
  await until(() => capture.info(state).failure[0]);
  assert.match(capture.info(state).failure[0], /rejected/);
  run(capture.stop(state), dispatch);
});

// Governing design: Capture coordination / Batched capture groups observations.
const settle = () => new Promise((r) => setImmediate(r));
async function batched(flushAfterMs, t, keepalive) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const rows = new Map(),
    received = [],
    encoded = [];
  const store = {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (k, b) => rows.set(k, b),
    remove: async (k) => rows.delete(k),
  };
  const transport = collector(async (body) => {
    const b = JSON.parse(body);
    received.push(b);
    return JSON.stringify({
      session_id: b.session.id,
      ack: b.entries.at(-1).sequence,
    });
  });
  if (keepalive) transport.keepalive = keepalive;
  const recording = { now: 0, received, encoded, state: null };
  let effect;
  [recording.state, effect] = capture.start_with_clock(
    new Metadata("Ada", "test-build", "test-v1", "web"),
    new Config("local", "batched", 100, 4000000),
    async () => store,
    transport,
    flushAfterMs,
    () => recording.now,
  )[0];
  const dispatch = (m) =>
    (recording.state = capture.update(recording.state, m));
  recording.run = (e) => run(e, dispatch);
  recording.run(effect);
  for (
    let turn = 0;
    turn < 20 && !capture.info(recording.state).session[0];
    turn++
  )
    await settle();
  assert.ok(capture.info(recording.state).session[0], "session opened");
  recording.observe = (before, event) => {
    recording.now++;
    [recording.state, effect] = capture.observe(
      recording.state,
      before,
      event,
      (model) => {
        encoded.push(model.value);
        return JSON.stringify(model);
      },
      (n) => new Event("Add", JSON.stringify(n)),
    );
    recording.run(effect);
  };
  recording.advance = async (ms) => {
    t.mock.timers.tick(ms);
    await settle();
    await settle();
  };
  return recording;
}
const shape = (received) =>
  received.map((b) => [
    b.checkpoint.sequence,
    b.checkpoint.model,
    b.entries.map((e) => e.sequence),
  ]);

test("observations within the flush window are sent as one batch with one checkpoint", async (t) => {
  const r = await batched(1000, t);
  r.observe({ value: 0 }, 2);
  r.observe({ value: 2 }, 3);
  r.observe({ value: 5 }, 4);
  await r.advance(999);
  assert.equal(capture.info(r.state).captured, 3);
  assert.equal(capture.info(r.state).saved, 0);
  assert.deepEqual(r.received, []);
  await r.advance(1);
  assert.equal(capture.info(r.state).saved, 3);
  // The window starts at the first held observation, not at each one.
  r.observe({ value: 9 }, 1);
  await r.advance(600);
  r.observe({ value: 10 }, 1);
  await r.advance(400);
  assert.deepEqual(shape(r.received), [
    [0, '{"value":0}', [1, 2, 3]],
    [3, '{"value":9}', [4, 5]],
  ]);
  assert.equal(capture.info(r.state).saved, 5);
  // The model is encoded once per batch, for the state before its first entry.
  assert.deepEqual(r.encoded, [0, 9]);
  assert.equal(capture.info(r.state).failure[0], undefined);
  r.run(capture.stop(r.state));
});

test("a zero flush window saves each observation at once as its own batch", async (t) => {
  const r = await batched(0, t);
  r.observe({ value: 0 }, 2);
  r.observe({ value: 2 }, 3);
  await settle();
  await settle();
  assert.deepEqual(shape(r.received), [
    [0, '{"value":0}', [1]],
    [1, '{"value":2}', [2]],
  ]);
  assert.equal(capture.info(r.state).saved, 2);
  r.run(capture.stop(r.state));
});

test("a batch closes at the wire format's entry limit and before its byte budget", async (t) => {
  const byCount = await batched(60000, t);
  for (let n = 0; n < 130; n++) byCount.observe({ value: n }, 1);
  await settle();
  await settle();
  assert.deepEqual(
    byCount.received.map((b) => b.entries.length),
    [128],
  );
  byCount.run(capture.stop(byCount.state));
  t.mock.timers.reset();
  // An entry that would take the batch past half the wire limit starts the
  // next batch with its own checkpoint.
  const byBytes = await batched(60000, t);
  const big = "x".repeat(200000);
  byBytes.observe({ value: 0 }, big);
  byBytes.observe({ value: 1 }, big);
  byBytes.observe({ value: 2 }, big);
  await settle();
  await settle();
  assert.deepEqual(
    shape(byBytes.received).map((b) => [b[0], b[2]]),
    [[0, [1, 2]]],
  );
  byBytes.run(capture.stop(byBytes.state));
});

test("flush and stop save held observations without waiting for the window", async (t) => {
  const r = await batched(60000, t);
  r.observe({ value: 0 }, 1);
  r.run(capture.flush(r.state));
  await settle();
  await settle();
  assert.deepEqual(shape(r.received), [[0, '{"value":0}', [1]]]);
  r.observe({ value: 1 }, 2);
  r.observe({ value: 3 }, 3);
  r.run(capture.stop(r.state));
  await settle();
  await settle();
  // Stop saves the open batch locally; a later runtime uploads it.
  assert.equal(capture.info(r.state).saved, 3);
  assert.equal(r.received.length, 1);
  // A flush with nothing held does nothing.
  r.run(capture.flush(r.state));
});

// Governing design: Capture coordination / the open batch is saved before the
// client hands its unacknowledged batches over when the page leaves.
test("a hidden page saves the open batch and hands it over with the rest", async (t) => {
  const document = new EventTarget();
  document.visibilityState = "visible";
  const previous = globalThis.document;
  globalThis.document = document;
  t.after(() => {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  });
  const handed = [];
  const r = await batched(60000, t, (body) => handed.push(JSON.parse(body)));
  r.observe({ value: 0 }, 2);
  r.observe({ value: 2 }, 3);
  document.visibilityState = "hidden";
  document.dispatchEvent(new globalThis.Event("visibilitychange"));
  // The hand-over is synchronous: the page may run no more code after it.
  assert.deepEqual(
    handed.map((b) => [b.checkpoint.sequence, b.entries.length]),
    [[0, 2]],
  );
  await settle();
  await settle();
  assert.equal(capture.info(r.state).saved, 2);
  r.run(capture.stop(r.state));
});
