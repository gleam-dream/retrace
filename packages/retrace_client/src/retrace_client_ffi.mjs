// Host-owned delivery runtime. No application reducer, native effect, or UI.
async function openStorage(name, maxItems, maxBytes) {
  const size = (value) => new TextEncoder().encode(value).byteLength;
  const check = (all, key, body) => {
    const others = all.filter((row) => row.key !== key);
    if (
      others.length >= maxItems ||
      others.reduce((n, row) => n + size(row.body), size(body)) > maxBytes
    )
      throw new Error("Recording queue is full");
    const existing = all.find((row) => row.key === key);
    if (existing && existing.body !== body)
      throw new Error("Conflicting local batch");
  };
  if (globalThis.__TAURI_INTERNALS__) {
    const { load } = await import("@tauri-apps/plugin-store");
    const store = await load(`${name}.json`, { autoSave: false, defaults: {} });
    const all = async () =>
      (await store.entries()).map(([key, body]) => ({ key, body }));
    let pending = Promise.resolve();
    const serial = (run) => {
      const result = pending.then(run);
      pending = result.catch(() => {});
      return result;
    };
    return {
      all: () => serial(all),
      put: (key, body) =>
        serial(async () => {
          check(await all(), key, body);
          await store.set(key, body);
          await store.save();
        }),
      remove: (key) =>
        serial(async () => {
          await store.delete(key);
          await store.save();
        }),
      close() {},
    };
  }
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

export function start(endpoint, name, maxItems, maxBytes, onStatus) {
  const valid =
    /^[a-zA-Z0-9_-]{1,100}$/.test(name) && maxItems > 0 && maxBytes > 0;
  const client = {
    endpoint: endpoint.replace(/\/$/, ""),
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
    ? openStorage(name, maxItems, maxBytes)
    : Promise.reject(new Error("Invalid queue configuration"));
  // Observe startup failures even when no event is ever enqueued.
  client.storage.then(
    () => retry(client),
    () => onStatus(0, 0, "Recording storage unavailable"),
  );
  return client;
}

export function enqueue(client, body, saved) {
  client.saving = client.saving
    .then(async () => {
      if (client.stopped || client.fault)
        throw new Error("Recording stopped after a persistence failure");
      const batch = JSON.parse(body);
      const key = `${batch.session.id}:${String(batch.checkpoint.sequence).padStart(16, "0")}`;
      const storage = await client.storage;
      await storage.put(key, body);
      saved(true, "Saved locally");
    })
    .catch((error) => {
      client.fault = true;
      saved(false, error.message || "Recording persistence failed");
    })
    .then(() => retry(client));
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
      let response;
      try {
        response = await fetch(`${client.endpoint}/batches`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: row.body,
          signal: client.controller.signal,
        });
      } finally {
        clearTimeout(timeout);
        client.controller = null;
      }
      if (!response.ok)
        throw new Error(
          response.status === 409
            ? "Recording conflict; saved batch retained"
            : "Collector unavailable; retrying",
        );
      const ack = await response.json();
      if (
        ack.session_id !== batch.session.id ||
        ack.ack !== batch.checkpoint.sequence + batch.entries.length
      )
        throw new Error("Invalid acknowledgement; saved batch retained");
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
