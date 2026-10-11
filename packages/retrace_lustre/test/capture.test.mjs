import { test } from "node:test";
import assert from "node:assert/strict";
import * as capture from "../build/dev/javascript/retrace_lustre/retrace_lustre/capture.mjs";
import { Config } from "../build/dev/javascript/retrace_client/retrace_client.mjs";
import { Event } from "../build/dev/javascript/retrace/retrace/wire.mjs";
import { perform } from "../build/dev/javascript/lustre/lustre/effect.mjs";
const until = async (f) => {
  for (let n = 0; n < 100; n++) {
    if (f()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw Error("timeout");
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
  const transport = async (body) => {
    const b = JSON.parse(body);
    received.push(b);
    return JSON.stringify({
      session_id: b.session.id,
      ack: b.entries.at(-1).sequence,
    });
  };
  const session = capture.session("Ada", "test-build", "test-v1", "web");
  const result = capture.start_with_clock(
    session,
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
  now = 1;
  observe({ value: 5 }, 4);
  assert.equal(capture.info(state).captured, 2);
  assert.match(capture.info(state).failure[0], /time/);
  now = 12;
  observe({ value: 9 }, 1);
  assert.equal(capture.info(state).captured, 2);
  run(capture.stop(state), dispatch);
});
test("capture refuses a transition before connection instead of silently losing history", () => {
  const result = capture.start_with_clock(
    capture.session("Ada", "build", "contract", "web"),
    new Config("x", "x", 1, 100),
    async () => {},
    async () => {},
    () => 0,
  );
  let [state] = result[0];
  [state] = capture.observe(
    state,
    0,
    1,
    JSON.stringify,
    (n) => new Event("Add", String(n)),
  );
  assert.match(capture.info(state).failure[0], /before connection/);
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
    capture.session("Ada", "build", "contract", "web"),
    new Config("x", "x", 2, 10000),
    async () => store,
    async () => {
      throw Error("must not upload");
    },
    () => 1,
  )[0];
  const dispatch = (m) => (state = capture.update(state, m));
  run(effect, dispatch);
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
