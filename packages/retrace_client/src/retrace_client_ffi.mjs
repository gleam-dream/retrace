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
  const check = (all, key, body) =>
    checkCapacity(all, key, body, maxItems, maxBytes);
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
    put: (key, body) =>
      transaction("readwrite", (store, result, tx, reject) => {
        store.getAll().onsuccess = (event) => {
          try {
            check(event.target.result, key, body);
            store.put({ key, body });
            result();
          } catch (error) {
            tx.abort();
            reject(error);
          }
        };
      }),
    remove: (key) => transaction("readwrite", (store) => store.delete(key)),
    close: () => db.close(),
  };
}

export const browserStorage = () => openStorage;
// Transport returns an acknowledgement JSON string. Runtime owns its deadline.
export const httpTransport = (endpoint) => async (body, signal) => {
  const response = await fetch(`${endpoint.replace(/\/$/, "")}/batches`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    signal,
  });
  if (!response.ok)
    throw Error(
      response.status === 409
        ? "Recording conflict; saved batch retained"
        : "Collector unavailable; retrying",
    );
  return response.text();
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
  };
  client.storage = valid
    ? Promise.resolve().then(() => open(name, maxItems, maxBytes))
    : Promise.reject(new Error("Invalid queue configuration"));
  // Observe startup failures even when no event is ever enqueued.
  client.storage.then(
    () => retry(client),
    () => onStatus(0, 0, "Recording storage unavailable"),
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
      const key = `${batch.session.id}:${String(batch.checkpoint.sequence).padStart(16, "0")}`;
      const storage = await client.storage;
      await storage.put(key, body);
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
      retry(client);
    });
}

export function retry(client) {
  if (client.stopped || client.busy) return;
  clearTimeout(client.timer);
  client.busy = true;
  (async () => {
    const storage = await client.storage;
    let rows = await storage.all();
    rows.sort((a, b) => a.key.localeCompare(b.key));
    while (rows.length && !client.stopped) {
      const row = rows[0];
      const batch = JSON.parse(row.body);
      client.onStatus(rows.length, client.ack, "Uploading saved recording");
      client.controller = new AbortController();
      const timeout = setTimeout(() => client.controller?.abort(), 5000);
      try {
        const ack = JSON.parse(
          await client.transport(row.body, client.controller.signal),
        );
        if (
          ack.session_id !== batch.session.id ||
          ack.ack !== batch.checkpoint.sequence + batch.entries.length
        )
          throw new Error("Invalid acknowledgement; saved batch retained");
      } finally {
        clearTimeout(timeout);
        client.controller = null;
      }
      if (client.stopped) break;
      await storage.remove(row.key);
      client.ack += batch.entries.length;
      rows = await storage.all();
      rows.sort((a, b) => a.key.localeCompare(b.key));
    }
    if (!client.stopped)
      client.onStatus(
        rows.length,
        client.ack,
        client.fault
          ? "Capture stopped; saved entries delivered"
          : "All saved entries delivered",
      );
  })()
    .catch(async (error) => {
      if (!client.stopped) {
        const count = await client.storage
          .then((s) => s.all())
          .then(
            (rows) => rows.length,
            () => 0,
          );
        client.onStatus(count, client.ack, error.message || "Delivery failed");
      }
    })
    .finally(() => {
      client.busy = false;
      if (!client.stopped) client.timer = setTimeout(() => retry(client), 1500);
    });
}

export function stop(client) {
  client.stopped = true;
  clearTimeout(client.timer);
  client.controller?.abort();
  // Do not close storage while an accepted save or upload deletion is pending.
  // The browser/process owns the final handle lifetime.
}
