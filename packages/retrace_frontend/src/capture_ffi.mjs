import { toList } from "./gleam.mjs";

export const randomId = () => crypto.randomUUID();
export function monotonicClock() {
  const started = performance.now();
  return () => Math.floor(performance.now() - started);
}

// One open batch per client runtime. The holder keeps the checkpoint, the
// entries and the window timer; the limits and the save are decided by callers.
const buffers = new WeakMap();
export function buffer(runtime) {
  let held = buffers.get(runtime);
  if (!held) buffers.set(runtime, (held = { open: null }));
  return held;
}
export function bufferFlush(held) {
  const open = held.open;
  if (!open) return;
  held.open = null;
  clearTimeout(open.timer);
  open.save(open.checkpoint, toList(open.entries));
}
export function bufferAdd(
  held,
  entry,
  bytes,
  checkpoint,
  windowMs,
  maxEntries,
  maxBytes,
  save,
) {
  // An entry that does not fit starts the next batch with its own checkpoint.
  if (held.open && held.open.bytes + bytes > maxBytes) bufferFlush(held);
  if (!held.open) {
    const [first, modelBytes] = checkpoint();
    held.open = {
      checkpoint: first,
      entries: [],
      bytes: modelBytes,
      save,
      timer: setTimeout(() => bufferFlush(held), windowMs),
    };
  }
  const open = held.open;
  open.entries.push(entry);
  open.bytes += bytes;
  // The newest observation's dispatcher reports the save.
  open.save = save;
  if (open.entries.length >= maxEntries) bufferFlush(held);
}
