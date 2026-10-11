import { checkCapacity } from "../retrace_client_ffi.mjs";
export async function openTauri(name, maxItems, maxBytes) {
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
        checkCapacity(await all(), key, body, maxItems, maxBytes);
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
export const tauriStorage = () => openTauri;
