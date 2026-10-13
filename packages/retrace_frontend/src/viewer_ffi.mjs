import { Result$Ok, Result$Error, toList } from "./gleam.mjs";
import { Some, None } from "../gleam_stdlib/gleam/option.mjs";
import { Session } from "../retrace/retrace/wire.mjs";
import {
  Source,
  Summary,
  Page,
  Artifact,
  EventLabel,
} from "./retrace_frontend/viewer.mjs";
import { css } from "./style.mjs";
import { createViewer } from "./viewer.mjs";
const message = (error) => error?.message || String(error);
const sessionFrom = (s) => {
  if (
    !s ||
    ![s.id, s.user_ref, s.build, s.contract, s.platform].every(
      (v) => typeof v === "string" && v.length,
    )
  )
    throw Error("Invalid session metadata");
  return new Session(s.id, s.user_ref, s.build, s.contract, s.platform);
};
// The application owns each task's resources. The viewer owns cancellation of
// those tasks, including callbacks that complete synchronously or arrive late.
function request(task, signal) {
  return new Promise((resolve, reject) => {
    let settled = false,
      cancel,
      cancelled = false;
    const abort = () => {
      if (settled) return;
      settled = true;
      cancelled = true;
      signal?.removeEventListener("abort", abort);
      try {
        cancel?.();
      } catch {
        /* Cancellation must still settle the request. */
      }
      reject(Error("Request cancelled"));
    };
    if (signal?.aborted) {
      reject(Error("Request cancelled"));
      return;
    }
    signal?.addEventListener("abort", abort, { once: true });
    try {
      cancel = task((result) => {
        if (settled) return;
        settled = true;
        signal?.removeEventListener("abort", abort);
        result.isOk() ? resolve(result[0]) : reject(Error(result[0]));
      });
      if (cancelled) cancel?.();
    } catch (error) {
      if (!settled) {
        settled = true;
        signal?.removeEventListener("abort", abort);
        reject(error);
      }
    }
  });
}
const task = (work) => (reply) => {
  const controller = new AbortController();
  work(AbortSignal.any([controller.signal, AbortSignal.timeout(10000)])).then(
    (value) => reply(Result$Ok(value)),
    (error) => reply(Result$Error(message(error))),
  );
  return () => controller.abort();
};
async function read(url, signal) {
  const response = await fetch(url, { signal });
  if (!response.ok)
    throw Error(
      "Recording or artifact unavailable. Check the source and retry.",
    );
  return response.json();
}
export function collector(endpoint) {
  const base = endpoint.replace(/\/$/, "");
  return new Source(
    (user) =>
      task(async (signal) => {
        const rows = await read(
          `${base}/sessions?user=${encodeURIComponent(user)}`,
          signal,
        );
        if (!Array.isArray(rows) || rows.length > 100)
          throw Error("Invalid session listing");
        return toList(
          rows.map((row) => {
            if (!Number.isSafeInteger(row.sequence) || row.sequence < 0)
              throw Error("Invalid session cursor");
            return new Summary(sessionFrom(row.session), row.sequence);
          }),
        );
      }),
    (id, after, limit) =>
      task(async (signal) => {
        if (!Number.isSafeInteger(limit) || limit < 1 || limit > 128)
          throw Error("Invalid page limit");
        const batches = await read(
          `${base}/sessions/${encodeURIComponent(id)}/batches?after=${after}`,
          signal,
        );
        if (
          !Array.isArray(batches) ||
          batches.length > 128 ||
          batches.some((b) => typeof b !== "string")
        )
          throw Error("Invalid range response");
        const selected = batches.slice(0, limit);
        const next =
          batches.length > limit || batches.length === 128
            ? new Some(JSON.parse(selected.at(-1)).entries.at(-1).sequence)
            : new None();
        return new Page(toList(selected), next);
      }),
  );
}
export function artifacts(directory) {
  return (session) =>
    task(async (signal) => {
      if (!/^[a-zA-Z0-9_-]{1,100}$/.test(session.build))
        throw Error("Invalid artifact identifier");
      let manifest;
      try {
        manifest = await read(
          `${directory.replace(/\/$/, "")}/${session.build}/manifest.json`,
          signal,
        );
      } catch {
        throw Error(
          "The replay artifact for this build is unavailable. Restore its artifact directory, then retry.",
        );
      }
      if (
        manifest.api !== 1 ||
        manifest.build !== session.build ||
        manifest.contract !== session.contract ||
        typeof manifest.url !== "string"
      )
        throw Error("Replay artifact manifest does not match the session.");
      return new Artifact(session.build, manifest.url, false);
    });
}
export function mount(config, selector) {
  try {
    const root = document.querySelector(selector);
    if (!root) throw Error(`Viewer element not found: ${selector}`);
    if (!Number.isSafeInteger(config.max_entries) || config.max_entries < 1)
      throw Error("Invalid retained-entry budget");
    const previousClass = root.classList.contains("retrace-viewer");
    root.classList.add("retrace-viewer");
    const style = document.createElement("style");
    style.textContent = css;
    document.head.prepend(style);
    let dispose;
    try {
      dispose = createViewer(root, {
        maxEntries: config.max_entries,
        labelEvent: (e) =>
          config.label_event(
            new EventLabel(e.sequence, e.elapsed, e.kind, e.label || e.kind),
          ),
        listSessions: async (user, { signal }) =>
          (await request(config.source.list_sessions(user), signal)).toArray(),
        readRange: async (id, { after, limit, signal }) => {
          const page = await request(
            config.source.read_range(id, after, limit),
            signal,
          );
          return {
            batches: page.batches.toArray(),
            next: page.next instanceof Some ? page.next[0] : null,
          };
        },
        resolveArtifact: async (session, { signal }) => ({
          api: 1,
          ...(await request(config.artifacts(sessionFrom(session)), signal)),
        }),
      });
    } catch (error) {
      style.remove();
      if (!previousClass) root.classList.remove("retrace-viewer");
      throw error;
    }
    let disposed = false;
    return Result$Ok(() => {
      if (disposed) return;
      disposed = true;
      dispose();
      style.remove();
      if (!previousClass) root.classList.remove("retrace-viewer");
    });
  } catch (error) {
    return Result$Error(message(error));
  }
}
