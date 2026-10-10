const started = performance.now();
export const endpoint = () =>
  import.meta.env.VITE_RETRACE_ENDPOINT || "http://127.0.0.1:4417";
export const sessionId = () => crypto.randomUUID();
export const userRef = () =>
  new URL(location.href).searchParams.get("user") || "Ada";
export const platform = () =>
  globalThis.__TAURI_INTERNALS__ ? "tauri" : "web";
export const elapsed = () => Math.floor(performance.now() - started);
export function sessions(user, callback) {
  fetch(`${endpoint()}/sessions?user=${encodeURIComponent(user)}`, {
    signal: AbortSignal.timeout(5000),
  })
    .then(async (response) => {
      if (!response.ok) throw Error("Collector unavailable. Try again.");
      return response.text();
    })
    .then(
      (body) => callback(true, body),
      (error) => callback(false, error.message),
    );
}
export function recording(id, callback) {
  (async () => {
    let after = 0,
      all = [];
    for (let page = 0; page < 40; page++) {
      const response = await fetch(
        `${endpoint()}/sessions/${encodeURIComponent(id)}/batches?after=${after}`,
        { signal: AbortSignal.timeout(5000) },
      );
      if (!response.ok)
        throw Error("Recording storage unavailable. Try again.");
      const rows = await response.json();
      all.push(...rows);
      if (all.length > 5000)
        throw Error("This example viewer loads at most 5,000 batches");
      if (rows.length < 128) return JSON.stringify(all);
      const last = JSON.parse(rows.at(-1));
      after = last.entries.at(-1).sequence;
    }
    throw Error("This example viewer reached its page limit");
  })().then(
    (body) => callback(true, body),
    (error) => callback(false, error.message),
  );
}
export function device(callback) {
  if (globalThis.__TAURI_INTERNALS__) {
    import("@tauri-apps/api/core")
      .then(({ invoke }) => invoke("platform_info"))
      .then(
        (value) => callback(value),
        () => callback("Native device request failed"),
      );
  } else {
    // This is intentionally a browser result, never represented as native evidence.
    setTimeout(
      () => callback("Browser preview · native command available in Tauri"),
      300,
    );
  }
}
export const delay = (callback) => {
  setTimeout(callback, 300);
};
