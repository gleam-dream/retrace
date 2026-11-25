// Cost of the delivery runtime under Node with an in-memory store: wake-ups of
// an idle client, storage rows read while draining a backlog, and rows read
// while saving during an outage. Nothing is sent over the network.
// Run: node dev/delivery-bench.mjs
// RETRACE_CLIENT_FFI=/path/to/client_ffi.mjs measures another revision.
import { mock } from "node:test";
import { pathToFileURL } from "node:url";
const { startWith, enqueue, stop } = await import(
  process.env.RETRACE_CLIENT_FFI
    ? pathToFileURL(process.env.RETRACE_CLIENT_FFI).href
    : "../packages/retrace_frontend/src/client_ffi.mjs"
);
const settle = () => new Promise((resolve) => setImmediate(resolve));
const body = (n) =>
  JSON.stringify({
    session: { id: "bench" },
    checkpoint: { sequence: n, model: "x".repeat(4000) },
    entries: [{}],
  });
function store() {
  const rows = new Map(),
    reads = { calls: 0, rows: 0 };
  return {
    rows,
    reads,
    all: async () => {
      reads.calls++;
      reads.rows += rows.size;
      return [...rows].map(([key, value]) => ({ key, body: value }));
    },
    put: async (key, value) => void rows.set(key, value),
    remove: async (key) => void rows.delete(key),
  };
}
const key = (n) => `bench:${String(n).padStart(16, "0")}`;
const acknowledge = async (sent) => {
  const batch = JSON.parse(sent);
  return JSON.stringify({
    session_id: "bench",
    ack: batch.checkpoint.sequence + 1,
  });
};

// The upload operation in both transport shapes: a function for revisions
// before sessions were opened by the collector, and `send` for later ones.
const uploads = (send) => Object.assign(send, { send });
async function idle(seconds) {
  mock.timers.enable({ apis: ["setTimeout"] });
  const queue = store();
  let statuses = 0;
  const client = startWith(
    "q",
    10,
    1e6,
    () => statuses++,
    async () => queue,
    uploads(acknowledge),
  );
  await settle();
  const before = { reads: queue.reads.calls, statuses };
  for (let step = 0; step < seconds * 2; step++) {
    mock.timers.tick(500);
    await settle();
  }
  stop(client);
  mock.timers.reset();
  return `storage_reads=${queue.reads.calls - before.reads} status_callbacks=${statuses - before.statuses}`;
}
async function drain(backlog) {
  const queue = store();
  for (let n = 0; n < backlog; n++) queue.rows.set(key(n), body(n));
  let acknowledged = 0;
  const started = performance.now();
  const client = startWith(
    "q",
    1e6,
    1e9,
    (_, ack) => (acknowledged = ack),
    async () => queue,
    uploads(acknowledge),
  );
  while (acknowledged < backlog) await settle();
  const elapsed = performance.now() - started;
  stop(client);
  return `rows_read=${queue.reads.rows} storage_reads=${queue.reads.calls} wall_ms=${elapsed.toFixed(0)}`;
}
async function outage(backlog, saves) {
  mock.timers.enable({ apis: ["setTimeout"] });
  const queue = store();
  for (let n = 0; n < backlog; n++) queue.rows.set(key(n), body(n));
  let attempts = 0;
  const client = startWith(
    "q",
    1e6,
    1e9,
    () => {},
    async () => queue,
    uploads(async () => {
      attempts++;
      throw Error("offline");
    }),
  );
  await settle();
  const before = queue.reads.rows;
  const started = performance.now();
  for (let n = 0; n < saves; n++) {
    await new Promise((saved) => enqueue(client, body(backlog + n), saved));
    await settle();
  }
  const elapsed = performance.now() - started;
  stop(client);
  mock.timers.reset();
  return `rows_read=${queue.reads.rows - before} upload_attempts=${attempts} wall_ms=${elapsed.toFixed(0)}`;
}
for (let attempt = 1; attempt <= 3; attempt++) {
  console.log(`run ${attempt}: idle 60 s: ${await idle(60)}`);
  console.log(
    `run ${attempt}: drain 1000 saved batches of 4 KB: ${await drain(1000)}`,
  );
  console.log(
    `run ${attempt}: 200 saves during an outage, 1000 already saved: ${await outage(1000, 200)}`,
  );
}
