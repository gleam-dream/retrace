import * as coreUsage from "./build/dev/javascript/retrace_inventory/usage_core.mjs";
// Adoption walk-through, executed: the inventory application records its accepted
// transitions through retrace_frontend/capture, delivery acknowledges them, and the
// delivered batches replay to the same state. Run with `node --test adoption.test.mjs`
// after `gleam build`. The steps mirror src/retrace_inventory.gleam.
import { test } from "node:test";
import assert from "node:assert/strict";
import { toList } from "./build/dev/javascript/retrace_inventory/gleam.mjs";
import { decode_batch } from "./build/dev/javascript/retrace/retrace/wire.mjs";
import * as capture from "./build/dev/javascript/retrace_frontend/retrace_frontend/capture.mjs";
import { Config } from "./build/dev/javascript/retrace_frontend/retrace_frontend/client.mjs";
import {
  load,
  describe,
} from "./build/dev/javascript/retrace_frontend/retrace_frontend/replay.mjs";
import * as domain from "./build/dev/javascript/retrace_inventory/retrace_inventory/domain.mjs";
import { perform } from "./build/dev/javascript/lustre/lustre/effect.mjs";

const until = async (done) => {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (done()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw Error("Timed out waiting for delivery");
};

// A Lustre effect is run by the application runtime; the example runs it directly.
const run = (effect, dispatch) =>
  perform(effect, dispatch, ...Array(6).fill(() => {}));

// Browser IndexedDB and HTTP are replaced by in-memory storage and an acknowledging
// transport. Both are the documented JavaScript adapter shapes.
function memoryDelivery() {
  const rows = new Map();
  const delivered = [];
  return {
    delivered,
    storage: async () => ({
      all: async () => [...rows].map(([key, body]) => ({ key, body })),
      put: async (key, body) => void rows.set(key, body),
      remove: async (key) => void rows.delete(key),
    }),
    transport: async (body) => {
      const batch = JSON.parse(body);
      delivered.push(batch);
      return JSON.stringify({
        session_id: batch.session.id,
        ack: batch.entries.at(-1).sequence,
      });
    },
  };
}

// Connect capture once, as init does in the application, and always stop it on exit
// so a failed assertion cannot leave delivery timers running.
async function withRecording(clock, body) {
  const delivery = memoryDelivery();
  const session = capture.session(
    "Warehouse",
    domain.build,
    domain.contract,
    "web",
  );
  const started = capture.start_with_clock(
    session,
    new Config("local", "adoption-outbox", 100, 1_048_576),
    delivery.storage,
    delivery.transport,
    clock,
  );
  assert.ok(started.isOk());
  let [state, connect] = started[0];
  const dispatch = (message) => {
    state = capture.update(state, message);
  };
  run(connect, dispatch);
  const recording = {
    delivery,
    get info() {
      return capture.info(state);
    },
    // Observe one accepted transition with the previous state, like update does.
    observe(before, command) {
      const [next, save] = capture.observe(
        state,
        before,
        command,
        domain.encode,
        domain.encode_command,
      );
      state = next;
      run(save, dispatch);
    },
  };
  try {
    await body(recording);
  } finally {
    run(capture.stop(state), dispatch);
  }
}

// The application's own update: reduce first, record only accepted transitions.
function apply(recording, stock, command) {
  const next = domain.reduce(stock, command);
  if (!next.isOk()) return stock;
  recording.observe(stock, command);
  return next[0];
}

const app = domain.replay_module();
const decodeAll = (delivered) =>
  toList(
    delivered.map((batch) => {
      const decoded = decode_batch(JSON.stringify(batch));
      assert.ok(decoded.isOk());
      return decoded[0];
    }),
  );

test("accepted transitions are delivered in order and replay to the live state", async () => {
  let now = 1000;
  await withRecording(
    () => now,
    async (recording) => {
      let live = domain.initial();
      for (const command of [
        new domain.Receive(),
        new domain.Reserve(),
        new domain.Release(),
        new domain.Reserve(),
      ]) {
        now += 750;
        live = apply(recording, live, command);
      }
      const { delivered } = recording.delivery;
      await until(() => recording.info.saved === 4 && delivered.length === 4);
      assert.equal(recording.info.captured, 4);
      assert.deepEqual(
        delivered.map((batch) => batch.entries[0].kind),
        ["receive", "reserve", "release", "reserve"],
      );
      assert.deepEqual(
        delivered.map((batch) => batch.checkpoint.sequence),
        [0, 1, 2, 3],
      );

      const replayed = load(app, decodeAll(delivered), domain.build, 5000);
      assert.ok(replayed.isOk());
      const snapshots = replayed[0].toArray();
      assert.equal(snapshots.length, 5);
      const last = snapshots.at(-1).model;
      assert.deepEqual(
        { on_hand: last.on_hand, reserved: last.reserved },
        { on_hand: live.on_hand, reserved: live.reserved },
      );
      const timeline = JSON.parse(describe(app, replayed[0]));
      assert.deepEqual(
        timeline.map((snapshot) => snapshot.sequence),
        [0, 1, 2, 3, 4],
      );
      assert.deepEqual(
        timeline.slice(1).map((snapshot) => snapshot.label),
        [
          "Received a notebook",
          "Reserved for an order",
          "Released a reservation",
          "Reserved for an order",
        ],
      );
    },
  );
});

test("a refused transition is not recorded and leaves no gap in the history", async () => {
  await withRecording(
    () => 10,
    async (recording) => {
      let live = domain.initial();
      live = apply(recording, live, new domain.Release()); // refused: nothing reserved
      live = apply(recording, live, new domain.Reserve());
      const { delivered } = recording.delivery;
      await until(() => delivered.length === 1);
      assert.equal(recording.info.captured, 1);
      assert.equal(delivered[0].checkpoint.sequence, 0);
      assert.equal(delivered[0].entries[0].kind, "reserve");

      const replayed = load(app, decodeAll(delivered), domain.build, 5000);
      assert.ok(replayed.isOk());
      assert.equal(replayed[0].toArray().at(-1).model.reserved, live.reserved);
    },
  );
});

test("replay refuses a different build than the recording's", async () => {
  await withRecording(
    () => 5,
    async (recording) => {
      apply(recording, domain.initial(), new domain.Receive());
      const { delivered } = recording.delivery;
      await until(() => delivered.length === 1);
      const wrongBuild = load(app, decodeAll(delivered), "another-build", 5000);
      assert.equal(wrongBuild.isOk(), false);
    },
  );
});

test("portable core example records and replays a message", () => {
  coreUsage.main();
});
