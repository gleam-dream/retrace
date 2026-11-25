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

// Governing design: Capture coordination / Batched capture groups observations.
const settle = () => new Promise((r) => setImmediate(r));
function batched(batching, t) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const rows = new Map(),
    received = [],
    encoded = [];
  const store = {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (k, b) => rows.set(k, b),
    remove: async (k) => rows.delete(k),
  };
  const transport = async (body) => {
    const b = JSON.parse(body);
    received.push(b);
    return JSON.stringify({
      session_id: b.session.id,
      ack: b.entries.at(-1).sequence,
    });
  };
  const recording = { now: 0, received, encoded, state: null };
  let effect;
  [recording.state, effect] = capture.start_with_clock(
    capture.session("Ada", "test-build", "test-v1", "web"),
    new Config("local", "batched", 100, 4000000),
    async () => store,
    transport,
    () => recording.now,
  )[0];
  if (batching)
    recording.state = capture.with_batching(recording.state, batching);
  const dispatch = (m) =>
    (recording.state = capture.update(recording.state, m));
  recording.run = (e) => run(e, dispatch);
  recording.run(effect);
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

test("batched capture sends the observations of one window as one batch with one checkpoint", async (t) => {
  const r = batched(new capture.Batching(1000, 64, 500000), t);
  await settle();
  r.observe({ value: 0 }, 2);
  r.observe({ value: 2 }, 3);
  r.observe({ value: 5 }, 4);
  await r.advance(999);
  assert.equal(capture.info(r.state).captured, 3);
  assert.equal(capture.info(r.state).saved, 0);
  assert.deepEqual(r.received, []);
  await r.advance(1);
  assert.equal(capture.info(r.state).saved, 3);
  // The window starts at the first buffered observation, not at each one.
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

test("batched capture closes a batch at its entry and byte limits", async (t) => {
  const byCount = batched(new capture.Batching(60000, 2, 500000), t);
  await settle();
  for (let n = 0; n < 5; n++) byCount.observe({ value: n }, 1);
  await settle();
  await settle();
  assert.deepEqual(
    shape(byCount.received).map((b) => b[2]),
    [
      [1, 2],
      [3, 4],
    ],
  );
  byCount.run(capture.stop(byCount.state));
  t.mock.timers.reset();
  // An entry that would pass the byte limit starts the next batch instead.
  const byBytes = batched(new capture.Batching(60000, 64, 600), t);
  await settle();
  const big = "x".repeat(150);
  byBytes.observe({ value: 0 }, big);
  byBytes.observe({ value: 1 }, big);
  byBytes.observe({ value: 2 }, big);
  await settle();
  await settle();
  assert.deepEqual(shape(byBytes.received), [[0, '{"value":0}', [1, 2]]]);
  // The limits are clamped to what one wire batch can hold.
  byBytes.run(capture.stop(byBytes.state));
  t.mock.timers.reset();
  const clamped = batched(new capture.Batching(60000, 100000, 500000), t);
  await settle();
  for (let n = 0; n < 130; n++) clamped.observe({ value: n }, 1);
  await settle();
  await settle();
  assert.equal(clamped.received[0].entries.length, 128);
  clamped.run(capture.stop(clamped.state));
});

test("flush and stop save buffered observations without waiting for the window", async (t) => {
  const r = batched(new capture.Batching(60000, 64, 500000), t);
  await settle();
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
  // A flush with nothing buffered does nothing.
  r.run(capture.flush(r.state));
});

test("capture without batching still sends one batch per observation", async (t) => {
  const r = batched(null, t);
  await settle();
  r.observe({ value: 0 }, 2);
  r.observe({ value: 2 }, 3);
  await settle();
  await settle();
  assert.deepEqual(shape(r.received), [
    [0, '{"value":0}', [1]],
    [1, '{"value":2}', [2]],
  ]);
  r.run(capture.stop(r.state));
});
