export const endpoint = () =>
  import.meta.env.VITE_RETRACE_ENDPOINT || "http://127.0.0.1:4417";
export const userRef = () =>
  new URL(location.href).searchParams.get("user") || "Ada";
export const platform = () =>
  globalThis.__TAURI_INTERNALS__ ? "tauri" : "web";
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
export const buildId = () => __RETRACE_BUILD__;
