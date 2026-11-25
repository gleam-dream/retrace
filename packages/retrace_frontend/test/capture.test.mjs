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
    () => 0,
  )[0];
  state = initial;
  const dispatch = (m) => (state = capture.update(state, m));
  run(connect, dispatch);
  await until(() => capture.info(state).failure[0]);
  assert.match(capture.info(state).failure[0], /rejected/);
  run(capture.stop(state), dispatch);
});
