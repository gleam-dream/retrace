import { test } from "node:test";
import assert from "node:assert/strict";
import { toList } from "../build/dev/javascript/retrace_example/gleam.mjs";
import { decode_batch } from "../build/dev/javascript/retrace/retrace/wire.mjs";
import {
  load,
  describe,
} from "../build/dev/javascript/retrace_frontend/retrace_frontend/replay.mjs";
import { module as replayModule } from "../build/dev/javascript/retrace_example/retrace_example/replay.mjs";
const app = replayModule();
const model = {
  points: 0,
  compact: false,
  device: "Not requested",
  details: false,
  viewport: { width: 390, height: 844, top: 0, bottom: 0 },
};
const batch = {
  format: 1,
  session: {
    id: "session",
    user_ref: "test",
    build: "release",
    contract: "membership-screen-v2",
    platform: "web",
  },
  checkpoint: { sequence: 0, elapsed_ms: 0, model: JSON.stringify(model) },
  entries: [
    { sequence: 1, elapsed_ms: 1200, kind: "Increment", payload: "" },
    { sequence: 2, elapsed_ms: 8500, kind: "NoChange", payload: "" },
  ],
};
function decode(value) {
  const result = decode_batch(JSON.stringify(value));
  assert.equal(result.isOk(), true);
  return result[0];
}
const run = (values) => load(app, toList(values.map(decode)), "release", 5000);
test("valid range retains its initial state, timestamp gap and unchanged transition", () => {
  const result = run([batch]);
  assert.equal(result.isOk(), true);
  assert.deepEqual(
    JSON.parse(describe(app, result[0])).map((s) => [s.sequence, s.elapsed]),
    [
      [0, 0],
      [1, 1200],
      [2, 8500],
    ],
  );
});
test("a checkpoint range is accepted; wrong build and changed metadata refuse replay", () => {
  assert.equal(load(app, toList([decode(batch)]), "other", 5000).isOk(), false);
  const partial = structuredClone(batch);
  partial.checkpoint.sequence = 2;
  partial.checkpoint.elapsed_ms = 8500;
  partial.entries = [
    { sequence: 3, elapsed_ms: 9000, kind: "Increment", payload: "" },
  ];
  assert.equal(run([partial]).isOk(), true);
  partial.session.user_ref = "another";
  assert.equal(run([batch, partial]).isOk(), false);
});
test("an inconsistent checkpoint or unknown application event refuses the whole range", () => {
  const next = structuredClone(batch);
  next.checkpoint.sequence = 2;
  next.checkpoint.elapsed_ms = 8500;
  next.entries = [
    { sequence: 3, elapsed_ms: 9000, kind: "Increment", payload: "" },
  ];
  assert.equal(run([batch, next]).isOk(), false);
  const unknown = structuredClone(batch);
  unknown.entries[1].kind = "Unknown";
  assert.equal(run([unknown]).isOk(), false);
});
