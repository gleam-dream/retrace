// Custom client storage, upload and viewer source, executed: src/retrace_example/
// local_archive.gleam builds all three from retrace_frontend/client/adapter and the
// typed viewer Source. Only localStorage IO is a JavaScript binding, replaced here by
// an in-memory stand-in. Run after `gleam build`: node --test dev/local_archive.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

// localStorage stand-in: methods are not enumerable, stored keys are.
const stored = {};
Object.defineProperties(stored, {
  getItem: { value: (key) => (key in stored ? stored[key] : null) },
  setItem: { value: (key, value) => void (stored[key] = String(value)) },
});
globalThis.localStorage = stored;

const archive =
  await import("../build/dev/javascript/retrace_example/retrace_example/local_archive.mjs");
const { Result$Ok: Ok } =
  await import("../build/dev/javascript/retrace_example/gleam.mjs");

const settle = (task) =>
  new Promise((resolve) => task((result) => resolve(result)));
const rejected = (task) =>
  settle(task).then((result) => {
    assert.equal(result.isOk(), false);
    return result[0];
  });
const accepted = (task) =>
  settle(task).then((result) => {
    assert.ok(result.isOk(), String(result[0]));
    return result[0];
  });
const clear = () => Object.keys(stored).forEach((key) => delete stored[key]);

const batch = (id, user, checkpoint, sequences) =>
  JSON.stringify({
    format: 1,
    session: {
      id,
      user_ref: user,
      build: "release",
      contract: "membership-screen-v2",
      platform: "web",
    },
    checkpoint: {
      sequence: checkpoint,
      elapsed_ms: checkpoint * 100,
      model: "{}",
    },
    entries: sequences.map((sequence) => ({
      sequence,
      elapsed_ms: sequence * 100,
      kind: "Increment",
      payload: "",
    })),
  });

test("storage enforces the queue's item bound, accepts identical retries and rejects conflicts", async () => {
  clear();
  const open = await archive.storage()("outbox", 2, 10_000);
  await open.put("a", "first");
  await open.put("a", "first"); // identical retry
  await assert.rejects(open.put("a", "different"), /Conflicting local batch/);
  await open.put("b", "second");
  await assert.rejects(open.put("c", "third"), /Recording queue is full/);
  assert.deepEqual((await open.all()).map((row) => row.key).sort(), ["a", "b"]);
  await open.remove("a");
  assert.deepEqual(
    (await open.all()).map((row) => row.key),
    ["b"],
  );
});

test("storage enforces the queue's byte bound", async () => {
  clear();
  const open = await archive.storage()("small", 10, 8);
  await open.put("a", "12345");
  await assert.rejects(open.put("b", "6789"), /Recording queue is full/);
});

test("upload stores each batch under its session and returns a validated receipt", async () => {
  clear();
  const upload = archive.transport();
  const first = batch("s1", "Ada", 0, [1, 2]);
  const receipt = JSON.parse(await upload(first, new AbortController().signal));
  assert.deepEqual(receipt, { session_id: "s1", ack: 2 });
  // The same batch again is an identical retry; changed content under the same
  // checkpoint conflicts.
  assert.deepEqual(
    JSON.parse(await upload(first, new AbortController().signal)),
    receipt,
  );
  await assert.rejects(
    upload(batch("s1", "Ada", 0, [1, 2, 3]), new AbortController().signal),
    /Conflicting local batch/,
  );
  await assert.rejects(
    upload("not a batch", new AbortController().signal),
    /Invalid archive batch/,
  );
});

test("the viewer source lists a user's sessions and pages ranges with a cursor", async () => {
  clear();
  const upload = archive.transport();
  const signal = new AbortController().signal;
  await upload(batch("s1", "Ada", 0, [1, 2]), signal);
  await upload(batch("s1", "Ada", 2, [3, 4]), signal);
  await upload(batch("s1", "Ada", 4, [5]), signal);
  await upload(batch("s2", "Grace", 0, [1]), signal);

  const source = archive.source();
  const sessions = await accepted(source.list_sessions("Ada"));
  assert.deepEqual(
    sessions.toArray().map((summary) => [summary.session.id, summary.sequence]),
    [["s1", 5]],
  );

  const first = await accepted(source.read_range("s1", 0, 2));
  assert.equal(first.batches.toArray().length, 2);
  assert.equal(first.next[0], 4); // cursor is the last absolute sequence returned
  const rest = await accepted(source.read_range("s1", first.next[0], 2));
  assert.equal(rest.batches.toArray().length, 1);
  assert.equal(rest.next.constructor.name, "None");
});
