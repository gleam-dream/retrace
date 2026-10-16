import { Result$Ok, Result$Error } from "./gleam.mjs";
import { Error$ElementNotFound } from "../lustre/lustre.mjs";
import { acceptsMessage, frameToken, trustedOrigin } from "./channel.mjs";
let connection;
export function ownOrigin() {
  return location.origin;
}
export function validateParentOrigin(value) {
  try {
    return Result$Ok(trustedOrigin(value));
  } catch (error) {
    return Result$Error(error.message);
  }
}
export function listen(
  build,
  load,
  seek,
  parentOrigin = location.origin,
  isolated = false,
) {
  trustedOrigin(parentOrigin);
  const token = frameToken(location.href, window.name || "", isolated);
  const current = { token, parentOrigin };
  connection = current;
  const receive = (event) => {
    if (!acceptsMessage(event, parent, parentOrigin, token)) return;
    const data = event.data;
    if (data.type === "load" && typeof data.body === "string") load(data.body);
    if (data.type === "seek" && Number.isSafeInteger(data.sequence))
      seek(data.sequence);
  };
  window.addEventListener("message", receive);
  if (token)
    parent.postMessage({ api: 1, token, type: "ready", build }, parentOrigin);
  return () => {
    if (connection === current) connection = undefined;
    window.removeEventListener("message", receive);
  };
}
export function report(type, body) {
  if (!connection?.token) return;
  const { token, parentOrigin } = connection;
  parent.postMessage({ api: 1, token, type, body }, parentOrigin);
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
