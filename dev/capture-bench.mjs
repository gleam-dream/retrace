// Upload cost and replay granularity of capture for 1,000 observations:
// requests, body bytes, model encodings, entries per batch and wall time under
// Node. Timers are simulated, storage is in memory, and nothing leaves Node.
// Build first: (cd packages/retrace_frontend && gleam build)
// Run: node dev/capture-bench.mjs [messages] [model-bytes] [interval-ms] [windows]
// `windows` is a comma-separated list of flush windows in ms. Set
// RETRACE_FRONTEND_BUILD to another revision's build/dev/javascript directory
// to measure it; a revision without a flush window sends one batch per message.
import { mock } from "node:test";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(
  process.env.RETRACE_FRONTEND_BUILD ||
    new URL(
      "../packages/retrace_frontend/build/dev/javascript",
      import.meta.url,
    ).pathname,
);
const load = (path) => import(pathToFileURL(resolve(root, path)).href);
const capture = await load("retrace_frontend/retrace_frontend/capture.mjs");
const { Config } = await load("retrace_frontend/retrace_frontend/client.mjs");
const { Event, Metadata } = await load("retrace/retrace/wire.mjs");
const { perform } = await load("lustre/lustre/effect.mjs");

const [messages = 1000, modelBytes = 20000, intervalMs = 100] = process.argv
  .slice(2, 5)
  .map(Number);
const windows = (process.argv[5] || "0,250,1000").split(",").map(Number);
// A revision before the flush window takes no window argument.
const windowed = capture.start_with_clock.length === 6;
const settle = () => new Promise((r) => setImmediate(r));
const nothing = () => {};
const run = (effect, dispatch) =>
  perform(effect, dispatch, ...Array(6).fill(nothing));

async function measure(windowMs) {
  mock.timers.enable({ apis: ["setTimeout"] });
  const rows = new Map();
  const store = {
    all: async () => [...rows].map(([key, body]) => ({ key, body })),
    put: async (key, body) => rows.set(key, body),
    remove: async (key) => rows.delete(key),
  };
  const sizes = [];
  let requests = 0,
    bytes = 0,
    delivered = 0,
    encodings = 0,
    now = 0;
  const transport = {
    open: async (metadata) =>
      JSON.stringify({
        session: { id: "bench", ...JSON.parse(metadata) },
        token: "bench-token",
      }),
    send: async (body) => {
      const batch = JSON.parse(body);
      requests++;
      bytes += Buffer.byteLength(body);
      delivered += batch.entries.length;
      sizes.push(batch.entries.length);
      return JSON.stringify({
        session_id: batch.session.id,
        ack: batch.entries.at(-1).sequence,
      });
    },
  };
  const args = [
    new Metadata("bench", "build", "contract", "web"),
    new Config("unused", "bench", 100000, 1e9),
    async () => store,
    transport,
    ...(windowed ? [windowMs] : []),
    () => now,
  ];
  let [state, effect] = capture.start_with_clock(...args)[0];
  const dispatch = (message) => (state = capture.update(state, message));
  run(effect, dispatch);
  for (let turn = 0; turn < 50 && !capture.info(state).session[0]; turn++)
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
  if (capture.flush) run(capture.flush(state), dispatch);
  const elapsed = performance.now() - started;
  for (let turn = 0; turn < 200 && delivered < messages; turn++) {
    mock.timers.tick(100);
    await settle();
  }
  run(capture.stop(state), dispatch);
  mock.timers.reset();
  const failure = capture.info(state).failure[0];
  if (failure) throw Error(failure);
  if (delivered !== messages) throw Error(`delivered ${delivered}`);
  return {
    requests,
    bytes,
    encodings,
    mean: messages / requests,
    max: Math.max(...sizes),
    elapsed,
  };
}

console.log(
  `${messages} observations, ${modelBytes}-byte model, one every ${intervalMs} ms (simulated), root ${root}`,
);
for (const windowMs of windowed ? windows : [null])
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await measure(windowMs);
    console.log(
      `${windowMs === null ? "one batch per message" : `window ${windowMs} ms`} run ${attempt}: ` +
        `requests=${r.requests} bytes=${r.bytes} model_encodings=${r.encodings} ` +
        `entries_per_batch_mean=${r.mean.toFixed(1)} entries_per_batch_max=${r.max} ` +
        `wall_ms=${r.elapsed.toFixed(0)}`,
    );
  }
