const size = (value) => new TextEncoder().encode(value).byteLength;
export function checkCapacity(all, key, body, maxItems, maxBytes) {
  const others = all.filter((row) => row.key !== key);
  if (
    others.length >= maxItems ||
    others.reduce((n, row) => n + size(row.body), size(body)) > maxBytes
  )
    throw new Error("Recording queue is full");
  const existing = all.find((row) => row.key === key);
  if (existing && existing.body !== body)
    throw new Error("Conflicting local batch");
}
// Host-owned delivery runtime. No application reducer, native effect, or UI.
async function openStorage(name, maxItems, maxBytes) {
  // Encoded size of every saved row by key, so that a save checks the limits
  // without reading the saved bodies. Each save first compares this index with
  // the keys in the store, inside its own transaction: a row another writer
  // added is sized, and a row another writer removed is dropped. A key is
  // never reused for different content, so a known size stays correct.
  const sizes = new Map();
  let total = 0;
  const forget = (key) => {
    total -= sizes.get(key) ?? 0;
    sizes.delete(key);
  };
  const remember = (key, bytes) => {
    forget(key);
    sizes.set(key, bytes);
    total += bytes;
  };
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("batches", { keyPath: "key" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  function transaction(mode, run) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction("batches", mode);
      let value;
      tx.oncomplete = () => resolve(value);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () =>
        reject(tx.error || new Error("Recording storage transaction failed"));
      run(
        tx.objectStore("batches"),
        (v) => {
          value = v;
        },
        tx,
        reject,
      );
    });
  }
  return {
    all: () =>
      transaction("readonly", (store, result) => {
        store.getAll().onsuccess = (event) => result(event.target.result);
      }),
    put: (key, body) => {
      const bytes = size(body);
      return transaction("readwrite", (store, result, tx, reject) => {
        store.getAllKeys().onsuccess = (event) => {
          const keys = new Set(event.target.result);
          for (const known of [...sizes.keys()])
            if (!keys.has(known)) forget(known);
          const unknown = [...keys].filter((saved) => !sizes.has(saved));
          let existing;
          let waiting = unknown.length + 1;
          const settled = () => {
            if (--waiting) return;
            try {
              const held = existing ? 1 : 0;
              const heldBytes = existing ? sizes.get(key) : 0;
              if (
                sizes.size - held >= maxItems ||
                total - heldBytes + bytes > maxBytes
              )
                throw new Error("Recording queue is full");
              if (existing && existing.body !== body)
                throw new Error("Conflicting local batch");
              store.put({ key, body });
              result();
            } catch (error) {
              tx.abort();
              reject(error);
            }
          };
          for (const saved of unknown)
            store.get(saved).onsuccess = (found) => {
              remember(saved, size(found.target.result.body));
              settled();
            };
          store.get(key).onsuccess = (found) => {
            existing = found.target.result;
            settled();
          };
        };
      }).then(() => remember(key, bytes));
    },
    remove: (key) =>
      transaction("readwrite", (store) => store.delete(key)).then(() =>
        forget(key),
      ),
    close: () => db.close(),
  };
}

export const browserStorage = () => openStorage;
// A refusal that an identical retry cannot change. Only the session's own
// writer can reach its session, so such a refusal is this client's to settle.
// Authorization, timeout and throttling failures are excluded: the host may
// repair credentials or capacity, and they affect every session alike.
const rejects = (status) =>
  status >= 400 &&
  status < 500 &&
  ![401, 403, 407, 408, 425, 429].includes(status);
// Wait after the given number of consecutive failed passes: an exponential
// step capped at one minute, of which a random half is removed as jitter.
const retryDelay = (failures) => {
  const step = Math.min(60000, 1500 * 2 ** Math.min(failures - 1, 16));
  return Math.round(step / 2 + (Math.random() * step) / 2);
};
// A transport opens sessions and uploads batches; each returns the collector's
// JSON reply. The runtime owns deadlines. A transport marks a permanent
// refusal by throwing an Error whose `rejected` is true.
export const httpTransport = (endpoint) => {
  const post = async (path, body, signal) => {
    const response = await fetch(`${endpoint.replace(/\/$/, "")}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
      signal,
    });
    if (!response.ok) {
      const error = Error(
        rejects(response.status)
          ? `Collector rejected the recording (HTTP ${response.status})`
          : "Collector unavailable; retrying",
      );
      error.rejected = rejects(response.status);
      throw error;
    }
    return response.text();
  };
  return {
    open: (metadata, signal) => post("/sessions", metadata, signal),
    send: (body, signal) => post("/batches", body, signal),
  };
};
export function start(endpoint, name, maxItems, maxBytes, onStatus) {
  return startWith(
    name,
    maxItems,
    maxBytes,
    onStatus,
    openStorage,
    httpTransport(endpoint),
  );
}
export function startWith(name, maxItems, maxBytes, onStatus, open, transport) {
  const valid =
    /^[a-zA-Z0-9_-]{1,100}$/.test(name) &&
    Number.isSafeInteger(maxItems) &&
    maxItems > 0 &&
    Number.isSafeInteger(maxBytes) &&
    maxBytes > 0;
  const client = {
    transport,
    maxItems,
    maxBytes,
    pendingItems: 0,
    pendingBytes: 0,
    writeFailed: false,
    onStatus,
    ack: 0,
    stopped: false,
    busy: false,
    saving: Promise.resolve(),
    timer: null,
    fault: false,
    controller: null,
    failures: 0,
    waiting: false,
    again: false,
    saved: 0,
    reported: [],
    rejected: new Set(),
    opening: null,
  };
  client.storage = valid
    ? Promise.resolve().then(() => open(name, maxItems, maxBytes))
    : Promise.reject(new Error("Invalid queue configuration"));
  // Observe startup failures even when no event is ever enqueued.
  client.storage.then(
    () => retry(client),
    () => report(client, 0, "Recording storage unavailable"),
  );
  return client;
}

export function enqueue(client, body, saved) {
  const bytes = size(body);
  if (
    client.stopped ||
    client.fault ||
    client.pendingItems >= client.maxItems ||
    client.pendingBytes + bytes > client.maxBytes
  ) {
    client.fault = true;
    saved(false, "Capture stopped: pending queue full or runtime unavailable");
    return;
  }
  client.pendingItems++;
  client.pendingBytes += bytes;
  client.saving = client.saving
    .then(async () => {
      if (client.writeFailed)
        throw new Error("Recording stopped after a persistence failure");
      const batch = JSON.parse(body);
      if (client.rejected.has(batch.session.id))
        throw new Error(
          "Collector rejected this session. Start a new session.",
        );
      const key = `${batch.session.id}:${String(batch.checkpoint.sequence).padStart(16, "0")}`;
      const storage = await client.storage;
      await storage.put(key, body);
      client.saved++;
      saved(true, "Saved locally");
    })
    .catch((error) => {
      client.fault = true;
      client.writeFailed = true;
      saved(false, error.message || "Recording persistence failed");
    })
    .finally(() => {
      client.pendingItems--;
      client.pendingBytes -= bytes;
      // A save must not cut a backoff wait short; the pending pass uploads it.
      if (!client.waiting) retry(client);
    });
}

// The open request is retried by every upload pass until it is answered.
export function openSession(client, metadata, opened) {
  if (client.stopped) return;
  client.opening = { metadata, opened };
  retry(client);
}

// Runs one request under the five-second deadline and the abort controller
// that shutdown cancels.
async function request(client, send) {
  client.controller = new AbortController();
  const timeout = setTimeout(() => client.controller?.abort(), 5000);
  try {
    return await send(client.controller.signal);
  } finally {
    clearTimeout(timeout);
    client.controller = null;
  }
}

const sorted = (rows) => rows.sort((a, b) => a.key.localeCompare(b.key));
const sessionOf = (row) => JSON.parse(row.body).session.id;
// Report a status only when it differs from the last one reported.
function report(client, queued, detail) {
  const last = client.reported;
  if (last[0] === queued && last[1] === client.ack && last[2] === detail)
    return;
  client.reported = [queued, client.ack, detail];
  client.onStatus(queued, client.ack, detail);
}
// One pass uploads the saved batches in key order. It reads the store once,
// works through that snapshot, and reads again only to pick up batches saved
// meanwhile; `saved` counts those for the reported queue length. A pass ends
// when a read finds nothing, and no timer runs while the queue is empty.
export function retry(client) {
  if (client.stopped) return;
  if (client.busy) {
    client.again = true;
    return;
  }
  clearTimeout(client.timer);
  client.waiting = false;
  client.busy = true;
  client.again = false;
  let failed = false;
  (async () => {
    const storage = await client.storage;
    let discarded = 0;
    if (client.opening && !client.stopped) {
      const { metadata, opened } = client.opening;
      report(client, client.reported[0] ?? 0, "Opening recording session");
      let grant;
      try {
        grant = await request(client, (signal) =>
          client.transport.open(metadata, signal),
        );
      } catch (error) {
        // A refused request cannot be repaired by sending it again.
        if (error?.rejected !== true || client.stopped) throw error;
        client.opening = null;
        opened(false, error.message);
      }
      if (client.stopped) return;
      if (grant !== undefined) {
        client.opening = null;
        opened(true, grant);
      }
    }
    for (;;) {
      client.saved = 0;
      const rows = sorted(await storage.all());
      if (!rows.length || client.stopped) break;
      // Keys discarded ahead of the current row, and how many remain ahead.
      const gone = new Set();
      let ahead = 0;
      for (const [index, row] of rows.entries()) {
        if (client.stopped) return;
        if (gone.has(row.key)) {
          ahead--;
          continue;
        }
        const left = () => rows.length - index - 1 - ahead + client.saved;
        const batch = JSON.parse(row.body);
        if (!client.rejected.has(batch.session.id)) {
          report(client, left() + 1, "Uploading saved recording");
          try {
            const ack = JSON.parse(
              await request(client, (signal) =>
                client.transport.send(row.body, signal),
              ),
            );
            if (
              ack.session_id !== batch.session.id ||
              ack.ack !== batch.checkpoint.sequence + batch.entries.length
            )
              throw new Error("Invalid acknowledgement; saved batch retained");
          } catch (error) {
            if (error?.rejected !== true || client.stopped) throw error;
            client.rejected.add(batch.session.id);
          }
          if (client.stopped) return;
          if (!client.rejected.has(batch.session.id)) {
            await storage.remove(row.key);
            client.ack += batch.entries.length;
            client.failures = 0;
            continue;
          }
        }
        // The collector refused this session, so no later batch of it can
        // follow contiguously. Free the queue for the other sessions.
        for (const other of rows.slice(index))
          if (!gone.has(other.key) && sessionOf(other) === batch.session.id) {
            await storage.remove(other.key);
            discarded++;
            if (other !== row) {
              gone.add(other.key);
              ahead++;
            }
          }
        report(
          client,
          left(),
          "Collector rejected a recording; its saved batches were discarded",
        );
      }
    }
    if (!client.stopped)
      report(
        client,
        0,
        discarded
          ? "Rejected recording discarded; other saved entries delivered"
          : client.fault
            ? "Capture stopped; saved entries delivered"
            : "All saved entries delivered",
      );
  })()
    .catch(async (error) => {
      failed = true;
      if (!client.stopped) {
        const count = await client.storage
          .then((s) => s.all())
          .then(
            (rows) => rows.length,
            () => 0,
          );
        report(client, count, error.message || "Delivery failed");
      }
    })
    .finally(() => {
      client.busy = false;
      if (client.stopped) return;
      client.failures = failed ? client.failures + 1 : 0;
      client.waiting = failed;
      if (failed)
        client.timer = setTimeout(
          () => retry(client),
          retryDelay(client.failures),
        );
      // A save or retry request that arrived after the last read.
      else if (client.again) retry(client);
    });
}

export function stop(client) {
  client.stopped = true;
  clearTimeout(client.timer);
  client.controller?.abort();
  // Do not close storage while an accepted save or upload deletion is pending.
  // The browser/process owns the final handle lifetime.
}
