// Explicit channel trust: never infer an authenticated parent from a message,
// referrer or recording. Opaque frames need wildcard delivery, not wildcard trust.
export function trustedOrigin(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw Error("Invalid trusted parent origin");
  }
  if (!["https:", "http:"].includes(parsed.protocol) || parsed.origin !== value)
    throw Error("Expected a canonical HTTP(S) parent origin");
  return value;
}
export function channelPolicy(mode, ownOrigin) {
  if (mode === "same-origin")
    return { receiveOrigin: trustedOrigin(ownOrigin), targetOrigin: ownOrigin };
  if (mode === "opaque") return { receiveOrigin: "null", targetOrigin: "*" };
  throw Error("Unsupported replay frame mode");
}
export function acceptsMessage(event, source, origin, token) {
  return (
    Boolean(token) &&
    event.source === source &&
    event.origin === origin &&
    event.data?.token === token &&
    event.data?.api === 1
  );
}
export function frameToken(href, name, isolated) {
  // The viewer owns the iframe's name before assigning srcdoc. No name fallback
  // in the default local mode; a missing nonce always fails closed.
  return isolated
    ? name.startsWith("retrace:")
      ? name.slice(8)
      : ""
    : new URL(href).searchParams.get("token") || "";
}
