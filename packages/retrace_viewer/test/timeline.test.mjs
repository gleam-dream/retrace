import { test } from "node:test";
import assert from "node:assert/strict";
import {
  positionAt,
  advance,
  clusters,
  previousTime,
} from "../src/timeline.mjs";
const events = [
  { elapsed: 0 },
  { elapsed: 1200 },
  { elapsed: 8500 },
  { elapsed: 8500 },
  { elapsed: 13000 },
];
test("time seek preserves gaps and equal-time sequence order", () => {
  assert.equal(positionAt(events, 8000), 1);
  assert.equal(positionAt(events, 8500), 3);
  assert.equal(positionAt(events, 0), 0);
});
test("wall-clock playback includes gaps, speed and endpoint clamp", () => {
  assert.equal(advance(1200, 3000, 1, 13000), 4200);
  assert.equal(advance(1200, 3000, 2, 13000), 7200);
  assert.equal(advance(12000, 3000, 1, 13000), 13000);
});
test("dense markers cluster without discarding events", () => {
  const groups = clusters(events.slice(1), 13000, 300);
  assert.equal(groups.length, 3);
  assert.equal(groups[1].length, 2);
});

test("previous skips equal-time groups without stalling", () => {
  assert.equal(previousTime(events, 8500), 1200);
  assert.equal(previousTime(events, 8600), 8500);
  assert.equal(previousTime(events, 0), 0);
});
