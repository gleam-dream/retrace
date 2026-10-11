import { test } from "node:test";
import assert from "node:assert/strict";
import { loadRange } from "../src/range.mjs";
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
