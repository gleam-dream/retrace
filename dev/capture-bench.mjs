// Upload cost of capture for 1,000 observations: requests, body bytes, model
// encodings and wall time under Node, with one batch per observation and with
// batching. Timers are simulated; storage is in memory; nothing is sent.
// Build first: (cd packages/retrace_frontend && gleam build)
// Run: node dev/capture-bench.mjs [messages] [model-bytes] [interval-ms]
import { mock } from "node:test";
import * as capture from "../packages/retrace_frontend/build/dev/javascript/retrace_frontend/retrace_frontend/capture.mjs";
import { Config } from "../packages/retrace_frontend/build/dev/javascript/retrace_frontend/retrace_frontend/client.mjs";
import { Event } from "../packages/retrace_frontend/build/dev/javascript/retrace/retrace/wire.mjs";
import { perform } from "../packages/retrace_frontend/build/dev/javascript/lustre/lustre/effect.mjs";

const [messages = 1000, modelBytes = 20000, intervalMs = 100] = process.argv
  .slice(2)
  .map(Number);
const settle = () => new Promise((resolve) => setImmediate(resolve));
const nothing = () => {};
const run = (effect, dispatch) =>
  perform(
    effect,
    dispatch,
    nothing,
    nothing,
    nothing,
    nothing,
    nothing,
    nothing,
  );

async function measure(batching) {
  mock.timers.enable({ apis: ["setTimeout"] });
  const rows = new Map();
  const store = {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (key, body) => rows.set(key, body),
    remove: async (key) => rows.delete(key),
  };
  let requests = 0,
    bytes = 0,
    delivered = 0,
    encodings = 0,
    now = 0;
  const transport = async (body) => {
    const batch = JSON.parse(body);
    requests++;
    bytes += Buffer.byteLength(body);
    delivered += batch.entries.length;
    return JSON.stringify({
      session_id: batch.session.id,
      ack: batch.entries.at(-1).sequence,
    });
  };
  let [state, effect] = capture.start_with_clock(
    capture.session("bench", "build", "contract", "web"),
    new Config("unused", "bench", 100000, 1e9),
    async () => store,
    transport,
    () => now,
  )[0];
  if (batching) state = capture.with_batching(state, batching);
  const dispatch = (message) => (state = capture.update(state, message));
  run(effect, dispatch);
  await settle();
  const model = { note: "x".repeat(modelBytes), count: 0 };
  const started = performance.now();
  for (let n = 0; n < messages; n++) {
    [state, effect] = capture.observe(
      state,
      { ...model, count: n },
      n,
      (value) => (encodings++, JSON.stringify(value)),
      (value) => new Event("increment", JSON.stringify({ by: value })),
    );
    run(effect, dispatch);
    now += intervalMs;
    mock.timers.tick(intervalMs);
    await settle();
  }
  run(capture.flush(state), dispatch);
  const elapsed = performance.now() - started;
  for (let turn = 0; turn < 50 && delivered < messages; turn++) {
    mock.timers.tick(100);
    await settle();
  }
  run(capture.stop(state), dispatch);
  mock.timers.reset();
  const failure = capture.info(state).failure[0];
  if (failure) throw Error(failure);
  return { requests, bytes, delivered, saved: rows.size, encodings, elapsed };
}

const modes = [["one batch per observation", null]];
if (capture.Batching)
  modes.push([
    "batching 1 s / 64 entries",
    new capture.Batching(1000, 64, 524288),
  ]);
console.log(
  `${messages} observations, ${modelBytes}-byte model, one every ${intervalMs} ms (simulated)`,
);
for (const [label, batching] of modes)
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await measure(batching);
    console.log(
      `${label} run ${attempt}: requests=${r.requests} bytes=${r.bytes} ` +
        `delivered=${r.delivered} undelivered_rows=${r.saved} ` +
        `model_encodings=${r.encodings} wall_ms=${r.elapsed.toFixed(0)}`,
    );
  }
