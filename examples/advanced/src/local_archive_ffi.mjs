import { toList, Result$Ok, Result$Error } from "./gleam.mjs";
// Application-owned alternate adapters; no collector, Tauri imports, or secrets.
// Same-origin localStorage is a demonstration archive, not a hosted service.
const read = (key) => JSON.parse(localStorage.getItem(key) || "{}");
export const storage = () => async (name, maxItems, maxBytes) => {
  const key = `retrace:${name}`;
  return {
    all: async () =>
      Object.entries(read(key)).map(([key, body]) => ({ key, body })),
    put: async (id, body) => {
      const rows = read(key);
      if (rows[id] && rows[id] !== body) throw Error("Conflicting local batch");
      rows[id] = body;
      if (
        Object.keys(rows).length > maxItems ||
        Object.values(rows).reduce(
          (n, b) => n + new TextEncoder().encode(b).length,
          0,
        ) > maxBytes
      )
        throw Error("Recording queue is full");
      localStorage.setItem(key, JSON.stringify(rows));
    },
    remove: async (id) => {
      const rows = read(key);
      delete rows[id];
      localStorage.setItem(key, JSON.stringify(rows));
    },
  };
};
export const transport = () => async (body, signal) => {
  signal.throwIfAborted();
  const batch = JSON.parse(body),
    key = `retrace:advanced:archive:${batch.session.id}`,
    rows = read(key);
  const sequence = batch.checkpoint.sequence;
  if (rows[sequence] && rows[sequence] !== body)
    throw Error("Archive conflict");
  rows[sequence] = body;
  localStorage.setItem(key, JSON.stringify(rows));
  return JSON.stringify({
    session_id: batch.session.id,
    ack: sequence + batch.entries.length,
  });
};

export const archiveIds = () =>
  toList(
    Object.keys(localStorage)
      .filter((k) => k.startsWith("retrace:advanced:archive:"))
      .map((k) => k.slice("retrace:advanced:archive:".length)),
  );
export function archiveRows(id) {
  try {
    return Result$Ok(
      toList(
        Object.values(read(`retrace:advanced:archive:${id}`)).sort(
          (a, b) =>
            JSON.parse(a).checkpoint.sequence -
            JSON.parse(b).checkpoint.sequence,
        ),
      ),
    );
  } catch (error) {
    return Result$Error(error.message);
  }
}

export const selected = () =>
  new URL(location.href).searchParams.get("storage") === "local";
