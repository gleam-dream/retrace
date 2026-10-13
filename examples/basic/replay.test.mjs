import { test } from "node:test";
import assert from "node:assert/strict";
import { toList } from "./build/dev/javascript/retrace_inventory/gleam.mjs";
import { decode_batch } from "./build/dev/javascript/retrace/retrace/wire.mjs";
import {
  load,
  describe,
  InvalidReplay,
} from "./build/dev/javascript/retrace_frontend/retrace_frontend/replay.mjs";
import {
  replay_module,
  NothingReserved,
} from "./build/dev/javascript/retrace_inventory/retrace_inventory/domain.mjs";
import { to_string } from "./build/dev/javascript/lustre/lustre/element.mjs";
const app = replay_module();
const batch = {
  format: 1,
  session: {
    id: "inventory-test",
    user_ref: "stock",
    build: "inventory-v1-dev",
    contract: "inventory-v1",
    platform: "web",
  },
  checkpoint: {
    sequence: 40,
    elapsed_ms: 5000,
    model: JSON.stringify({ on_hand: 4, reserved: 0 }),
  },
  entries: [
    { sequence: 41, elapsed_ms: 6000, kind: "receive", payload: "" },
    { sequence: 42, elapsed_ms: 9000, kind: "reserve", payload: "" },
  ],
};
function run(values, build = "inventory-v1-dev", limit = 5000) {
  return load(
    app,
    toList(
      values.map((b) => {
        const d = decode_batch(JSON.stringify(b));
        assert.ok(d.isOk());
        return d[0];
      }),
    ),
    build,
    limit,
  );
}
test("independent native types, labels, fixed viewport and nonzero checkpoint", () => {
  const result = run([batch]);
  assert.ok(result.isOk());
  const snapshots = result[0].toArray();
  assert.equal(snapshots.at(-1).model.on_hand, 5);
  assert.equal(snapshots.at(-1).model.reserved, 1);
  assert.match(to_string(app.view(snapshots.at(-1).model)), /Field notebooks/);
  const metadata = JSON.parse(describe(app, result[0]));
  assert.deepEqual(
    metadata.map((s) => s.sequence),
    [40, 41, 42],
  );
  assert.equal(metadata[2].label, "Reserved for an order");
  assert.deepEqual(metadata[0].viewport, { width: 900, height: 600 });
});
test("bad build, discontinuity, checkpoint mismatch and bound refuse; corrected retry succeeds", () => {
  assert.equal(run([batch], "wrong").isOk(), false);
  assert.equal(run([batch], undefined, 1).isOk(), false);
  const next = structuredClone(batch);
  next.checkpoint.sequence = 42;
  next.checkpoint.elapsed_ms = 9000;
  next.entries = [
    { sequence: 43, elapsed_ms: 9500, kind: "receive", payload: "" },
  ];
  assert.equal(run([batch, next]).isOk(), false);
  next.checkpoint.model = JSON.stringify({ on_hand: 5, reserved: 1 });
  assert.ok(run([batch, next]).isOk());
  const missing = structuredClone(next);
  missing.checkpoint.sequence = 43;
  missing.entries[0].sequence = 44;
  assert.equal(run([batch, missing]).isOk(), false);
  assert.ok(run([batch]).isOk());
});
test("application refusal retains the native error type", () => {
  const bad = structuredClone(batch);
  bad.entries = [
    { sequence: 41, elapsed_ms: 6000, kind: "release", payload: "" },
  ];
  const result = run([bad]);
  assert.equal(result.isOk(), false);
  assert.ok(result[0] instanceof InvalidReplay);
  const failure = result[0][0];
  assert.equal(failure.sequence, 41);
  assert.ok(failure.cause instanceof NothingReserved);
});
