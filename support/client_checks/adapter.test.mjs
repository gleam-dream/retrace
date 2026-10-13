import { test } from "node:test";
import assert from "node:assert/strict";
import * as consumer from "./build/dev/javascript/retrace_client_checks/retrace_client_checks.mjs";
import * as client from "./build/dev/javascript/retrace_frontend/retrace_frontend/client.mjs";
import { Store } from "./build/dev/javascript/retrace_frontend/retrace_frontend/client/adapter.mjs";
import {
  Result$Ok as Ok,
  Result$Error as ErrorResult,
  toList,
} from "./build/dev/javascript/retrace_client_checks/gleam.mjs";
import {
  Session,
  Batch,
  Event,
  encode,
} from "./build/dev/javascript/retrace/retrace/wire.mjs";
import {
  Checkpoint,
  Origin,
  Entry,
} from "./build/dev/javascript/retrace/retrace.mjs";

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check) {
  for (let i = 0; i < 800; i++) {
    if (await check()) return;
    await pause(10);
  }
  throw Error("Timed out waiting for public operation");
}
const success = (value) => (reply) => {
  reply(Ok(value));
  return () => {};
};
const failure = (reason) => (reply) => {
  reply(ErrorResult(new consumer.Unavailable(reason)));
  return () => {};
};
const config = () => new client.Config("unused", "typed-consumer", 4, 10000);
function batch() {
  const origin = new Origin("typed-session", "stock-v1");
  return new Batch(
    new Session("typed-session", "Warehouse", "build-1", "stock-v1", "web"),
    new Checkpoint(origin, 0, 0, '{"stock":4}'),
    toList([
      new Entry(origin, 1, 1000, new Event("receive", '{"quantity":1}')),
    ]),
  );
}
const receipt = '{"session_id":"typed-session","ack":1}';
function memory() {
  const rows = new Map();
  const state = {
    rows,
    puts: 0,
    removes: 0,
    failPut: false,
    failRemove: false,
    save: null,
  };
  state.store = new Store(
    () => success(toList([...rows.values()])),
    (row) => (reply) => {
      state.puts++;
      const finish = () => {
        if (state.failPut)
          reply(ErrorResult(new consumer.Unavailable("disk full")));
        else {
          rows.set(row.key, row);
          reply(Ok(undefined));
        }
      };
      if (state.save) state.save(finish);
      else finish();
      return () => {
        throw Error("Storage must not be cancelled");
      };
    },
    (key) => (reply) => {
      state.removes++;
      if (state.failRemove)
        reply(ErrorResult(new consumer.Unavailable("delete failed")));
      else {
        rows.delete(key);
        reply(Ok(undefined));
      }
      return () => {};
    },
  );
  state.adapter = consumer.storage(() => success(state.store));
  return state;
}
const save = (runtime, value = batch()) =>
  new Promise((resolve) => client.enqueue(runtime, value, resolve));

// Governing design: Client delivery / Typed client adapters preserve operation ownership.
test("Gleam operations are cold, preserve exact bytes and first completion", async () => {
  let calls = 0,
    cancelled = 0;
  const upload = consumer.transport((body) => {
    calls++;
    assert.equal(body, ' { "opaque": true }\n');
    return (reply) => {
      reply(Ok(' { "receipt": true }\n'));
      reply(ErrorResult(new consumer.Unavailable("late")));
      return () => cancelled++;
    };
  });
  assert.equal(calls, 0);
  const controller = new AbortController();
  assert.equal(
    await upload(' { "opaque": true }\n', controller.signal),
    ' { "receipt": true }\n',
  );
  controller.abort();
  assert.equal(cancelled, 0);
  assert.equal(
    await consumer.transport(consumer.immediate_receipt)(
      "Gleam deferred reply",
      new AbortController().signal,
    ),
    "Gleam deferred reply",
  );
});

test("provider errors and throws settle; first result survives later throw", async () => {
  await assert.rejects(
    consumer.transport(() => failure("offline"))(
      "batch",
      new AbortController().signal,
    ),
    /Provider: offline/,
  );
  await assert.rejects(
    consumer.transport(() => {
      throw Error("construct");
    })("batch", new AbortController().signal),
    /construct/,
  );
  await assert.rejects(
    consumer.transport(() => () => {
      throw Error("execute");
    })("batch", new AbortController().signal),
    /execute/,
  );
  assert.equal(
    await consumer.transport(() => (reply) => {
      reply(Ok(receipt));
      throw Error("after completion");
    })("batch", new AbortController().signal),
    receipt,
  );
});

test("pre-start and reentrant cancellation settle and cancel at most once", async () => {
  const before = new AbortController();
  before.abort();
  let started = 0;
  await assert.rejects(
    consumer.transport(() => {
      started++;
      return success(receipt);
    })("batch", before.signal),
    /cancelled/,
  );
  assert.equal(started, 0);
  const during = new AbortController();
  let cancelled = 0;
  await assert.rejects(
    consumer.transport(() => (reply) => {
      during.abort();
      reply(Ok(receipt));
      return () => {
        cancelled++;
        throw Error("cleanup failed");
      };
    })("batch", during.signal),
    /cancelled/,
  );
  during.abort();
  assert.equal(cancelled, 1);
});

test("typed custom store gets queue settings; bad receipt retains identical bytes for retry", async () => {
  const state = memory(),
    settings = [],
    sent = [],
    statuses = [];
  let valid = false;
  const storage = consumer.storage((queue) => {
    settings.push(queue);
    return success(state.store);
  });
  assert.equal(settings.length, 0);
  const runtime = client.start_with(
    config(),
    storage,
    consumer.transport((body) => {
      sent.push(body);
      return success(
        valid ? receipt : '{"session_id":"typed-session","ack":9}',
      );
    }),
    (status) => statuses.push(status),
  );
  try {
    assert.ok((await save(runtime)).isOk());
    await until(() =>
      statuses.some((s) => s.detail.includes("Invalid acknowledgement")),
    );
    assert.equal(settings[0].name, "typed-consumer");
    assert.equal(settings[0].max_items, 4);
    assert.equal(settings[0].max_bytes, 10000);
    assert.equal(state.rows.size, 1);
    assert.equal(state.removes, 0);
    assert.equal(sent[0], encode(batch()));
    valid = true;
    client.retry(runtime);
    await until(() => state.rows.size === 0);
    assert.equal(sent[1], sent[0]);
  } finally {
    client.stop(runtime);
  }
});

test("shutdown cancels pending upload; late success cannot delete; new runtime recovers", async () => {
  const state = memory();
  let replyLate,
    cancelled = 0,
    recovered;
  const runtime = client.start_with(
    config(),
    state.adapter,
    consumer.transport(() => (reply) => {
      replyLate = reply;
      return () => {
        cancelled++;
      };
    }),
    () => {},
  );
  try {
    assert.ok((await save(runtime)).isOk());
    await until(() => replyLate);
    client.stop(runtime);
    replyLate(Ok(receipt));
    await pause(10);
    assert.equal(cancelled, 1);
    assert.equal(state.rows.size, 1);
    assert.equal(state.removes, 0);
    recovered = client.start_with(
      config(),
      state.adapter,
      consumer.transport(() => success(receipt)),
      () => {},
    );
    await until(() => state.rows.size === 0);
  } finally {
    client.stop(runtime);
    if (recovered) client.stop(recovered);
  }
});

test("deadline cancels a custom task even if it never replies; retry recovers", async () => {
  const state = memory(),
    statuses = [];
  let cancelled = 0,
    online = false;
  const runtime = client.start_with(
    config(),
    state.adapter,
    consumer.transport(() =>
      online
        ? success(receipt)
        : () => () => {
            cancelled++;
          },
    ),
    (s) => statuses.push(s),
  );
  try {
    assert.ok((await save(runtime)).isOk());
    await until(() => statuses.some((s) => s.detail.includes("cancelled")));
    assert.equal(cancelled, 1);
    assert.equal(state.rows.size, 1);
    online = true;
    client.retry(runtime);
    await until(() => state.rows.size === 0);
  } finally {
    client.stop(runtime);
  }
});

test("admitted save completes after shutdown without cancelling caller storage", async () => {
  const state = memory();
  let finish, recovered;
  state.save = (work) => {
    finish = work;
  };
  const runtime = client.start_with(
    config(),
    state.adapter,
    consumer.transport(() => failure("offline")),
    () => {},
  );
  try {
    const saved = save(runtime);
    await until(() => finish);
    client.stop(runtime);
    finish();
    assert.ok((await saved).isOk());
    assert.equal(state.rows.size, 1);
    recovered = client.start_with(
      config(),
      state.adapter,
      consumer.transport(() => success(receipt)),
      () => {},
    );
    await until(() => state.rows.size === 0);
  } finally {
    client.stop(runtime);
    if (recovered) client.stop(recovered);
  }
});

test("storage startup/write/delete errors settle and preserve recovery", async () => {
  const failed = client.start_with(
    config(),
    consumer.storage(() => failure("open failed")),
    consumer.transport(() => success(receipt)),
    () => {},
  );
  try {
    assert.equal((await save(failed))[0], "Provider: open failed");
  } finally {
    client.stop(failed);
  }
  const state = memory();
  state.failPut = true;
  const failedWrite = client.start_with(
    config(),
    state.adapter,
    consumer.transport(() => success(receipt)),
    () => {},
  );
  try {
    assert.equal((await save(failedWrite))[0], "Provider: disk full");
    assert.equal(state.rows.size, 0);
  } finally {
    client.stop(failedWrite);
  }
  state.failPut = false;
  state.failRemove = true;
  const statuses = [];
  const runtime = client.start_with(
    config(),
    state.adapter,
    consumer.transport(() => success(receipt)),
    (s) => statuses.push(s),
  );
  try {
    assert.ok((await save(runtime)).isOk());
    await until(() => statuses.some((s) => s.detail.includes("delete failed")));
    assert.equal(state.rows.size, 1);
    state.failRemove = false;
    client.retry(runtime);
    await until(() => state.rows.size === 0);
  } finally {
    client.stop(runtime);
  }
});
