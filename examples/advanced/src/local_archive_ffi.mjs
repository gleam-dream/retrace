import { toList, Result$Ok, Result$Error } from "./gleam.mjs";
// Browser IO only. Queue rules, archive receipts and viewer reads live in Gleam.
function attempt(work) {
  try {
    return Result$Ok(work());
  } catch (error) {
    return Result$Error(error.message || "Browser storage unavailable");
  }
}
export const read = (key) => attempt(() => localStorage.getItem(key) ?? "{}");
export const write = (key, value) =>
  attempt(() => localStorage.setItem(key, value));
export const keys = () => attempt(() => toList(Object.keys(localStorage)));
export const selected = () =>
  new URL(location.href).searchParams.get("storage") === "local";
