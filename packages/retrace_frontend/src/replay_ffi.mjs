import { Result$Ok, Result$Error } from "./gleam.mjs";
import { Error$ElementNotFound } from "../lustre/lustre.mjs";
let connected = false;
// Artifacts and host are served together. This is a trusted-code boundary.
const token = () => new URL(location.href).searchParams.get("token");
export function listen(build, load, seek) {
  connected = true;
  const receive = ({ source, origin, data }) => {
    if (
      source !== parent ||
      origin !== location.origin ||
      data?.token !== token() ||
      data.api !== 1
    )
      return;
    if (data.type === "load" && typeof data.body === "string") load(data.body);
    if (data.type === "seek" && Number.isSafeInteger(data.sequence))
      seek(data.sequence);
  };
  window.addEventListener("message", receive);
  parent.postMessage(
    { api: 1, token: token(), type: "ready", build },
    location.origin,
  );
  return () => {
    connected = false;
    window.removeEventListener("message", receive);
  };
}
export function report(type, body) {
  if (!connected) return;
  parent.postMessage({ api: 1, token: token(), type, body }, location.origin);
}

export function prepareTarget(selector) {
  let host;
  try {
    host = document.querySelector(selector);
  } catch {
    return Result$Error(Error$ElementNotFound(selector));
  }
  if (!host) return Result$Error(Error$ElementNotFound(selector));
  // Lustre 5.7.1's SPA shutdown branch is a TODO. Own a disposable child so
  // removing it also releases its root event handlers without replacing the host.
  const root = document.createElement("div");
  root.id = `retrace-${crypto.randomUUID()}`;
  host.append(root);
  return Result$Ok([`#${root.id}`, () => root.remove()]);
}
export function once(callback) {
  let dispose = callback;
  return () => {
    const run = dispose;
    dispose = null;
    run?.();
  };
}
