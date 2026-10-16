import { test } from "node:test";
import assert from "node:assert/strict";
import { loadRange, createRangeReader } from "../src/range.mjs";
const batch = (start, end) =>
  JSON.stringify({
    session: { id: "s" },
    checkpoint: { sequence: start },
    entries: Array.from({ length: end - start }, (_, i) => ({
      sequence: start + i + 1,
    })),
  });
test("pages from a nonzero checkpoint preserve absolute cursors", async () => {
  const seen = [];
  const result = await loadRange(
    async (id, request) => {
      seen.push(request.after);
      return request.after === 40
        ? { batches: [batch(40, 42)], next: 42 }
        : { batches: [batch(42, 43)], next: null };
    },
    "s",
    { after: 40 },
  );
  assert.deepEqual(seen, [40, 42]);
  assert.equal(result.length, 2);
});
test("missing pages, stalled cursors and oversized ranges refuse, corrected retry succeeds", async () => {
  for (const page of [
    { batches: [batch(41, 42)], next: null },
    { batches: [batch(0, 1)], next: 0 },
    { batches: [], next: 1 },
  ])
    await assert.rejects(loadRange(async () => page, "s"));
  await assert.rejects(
    loadRange(async () => ({ batches: [batch(0, 3)], next: null }), "s", {
      maxEntries: 2,
    }),
  );
  assert.equal(
    (await loadRange(async () => ({ batches: [batch(0, 2)], next: null }), "s"))
      .length,
    1,
  );
});

const timedBatch = (start, end, step = 1000, extra = {}) =>
  JSON.stringify({
    session: {
      id: "s",
      build: "b",
      contract: "c",
      user_ref: "u",
      platform: "web",
      ...extra,
    },
    checkpoint: { sequence: start, elapsed_ms: start * step },
    entries: Array.from({ length: end - start }, (_, i) => ({
      sequence: start + i + 1,
      elapsed_ms: (start + i + 1) * step,
    })),
  });
test("progressive windows start before later pages and preserve whole checkpoints", async () => {
  let reads = 0;
  const reader = createRangeReader(async (_, { after }) => {
    reads++;
    return after === 0
      ? {
          batches: [
            timedBatch(0, 1, 180000),
            timedBatch(1, 2, 180000),
            timedBatch(2, 3, 180000),
          ],
          next: 3,
        }
      : { batches: [timedBatch(3, 4, 180000)], next: null };
  }, "s");
  const first = await reader.next();
  assert.equal(reads, 1);
  assert.equal(first.after, 1);
  assert.equal(first.complete, false);
  const second = await reader.next();
  assert.equal(reads, 1);
  assert.equal(second.after, 2);
  assert.equal((await reader.next()).after, 3);
  const last = await reader.next();
  assert.equal(reads, 2);
  assert.equal(last.complete, true);
  assert.equal(last.after, 4);
});
test("later read failure retries without losing or duplicating a playable prefix", async () => {
  let fail = true;
  const cursors = [];
  const reader = createRangeReader(async (_, { after }) => {
    cursors.push(after);
    if (after === 0) return { batches: [timedBatch(0, 1)], next: 1 };
    if (fail) throw Error("temporary outage");
    return { batches: [timedBatch(1, 2)], next: null };
  }, "s");
  assert.equal((await reader.next()).after, 1);
  await assert.rejects(reader.next(), /temporary outage/);
  fail = false;
  assert.equal((await reader.next()).after, 2);
  assert.deepEqual(cursors, [0, 1, 1]);
});
test("progressive reads reject altered identity, gaps, backwards time and budget overflow atomically", async () => {
  for (const invalid of [
    timedBatch(1, 2, 1000, { build: "other" }),
    timedBatch(2, 3),
    timedBatch(1, 2, 1),
    timedBatch(1, 3),
  ]) {
    let broken = true;
    const reader = createRangeReader(
      async (_, { after }) =>
        after === 0
          ? { batches: [timedBatch(0, 1)], next: 1 }
          : { batches: [broken ? invalid : timedBatch(1, 2)], next: null },
      "s",
      { maxEntries: 2 },
    );
    await reader.next();
    await assert.rejects(reader.next());
    broken = false;
    assert.equal((await reader.next()).after, 2);
  }
  const encoded = timedBatch(0, 1);
  await assert.rejects(
    createRangeReader(async () => ({ batches: [encoded], next: null }), "s", {
      maxBytes: 1,
    }).next(),
    /byte/,
  );
});
test("cancellation fences late progressive replies and invalid options refuse", async () => {
  const controller = new AbortController();
  let resolve;
  const reader = createRangeReader(
    () => new Promise((r) => (resolve = r)),
    "s",
    { signal: controller.signal },
  );
  const pending = reader.next();
  controller.abort();
  resolve({ batches: [timedBatch(0, 1)], next: null });
  await assert.rejects(pending, /abort/i);
  for (const options of [
    { after: -1 },
    { after: 1.5 },
    { maxBytes: 0 },
    { windowMs: 0 },
    { pageSize: 129 },
    { windowEntries: 0 },
  ])
    assert.throws(
      () => createRangeReader(async () => {}, "s", options),
      /bounds/,
    );
});
