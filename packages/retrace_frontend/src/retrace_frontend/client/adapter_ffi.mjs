import { Row } from "./adapter.mjs";

// The client owns request deadlines. Storage has no cancellation signal because
// admitted writes/deletions must settle, even after client shutdown.
function request(task, explain, signal) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let cancel;
    let cancellationPending = false;
    const cleanup = () => signal?.removeEventListener("abort", abort);
    const cancelWork = () => {
      if (!cancellationPending || !cancel) return;
      cancellationPending = false;
      try {
        cancel();
      } catch {
        // Cancellation must settle even when provider cleanup throws.
      }
    };
    const abort = () => {
      if (settled) return;
      settled = true;
      cancellationPending = true;
      cleanup();
      cancelWork();
      reject(Error("Upload cancelled"));
    };
    if (signal?.aborted) {
      reject(Error("Upload cancelled"));
      return;
    }
    signal?.addEventListener("abort", abort, { once: true });
    try {
      cancel = task((result) => {
        if (settled) return;
        settled = true;
        cleanup();
        try {
          if (result.isOk()) resolve(result[0]);
          else reject(Error(explain(result[0])));
        } catch (error) {
          reject(error);
        }
      });
      // Abort can occur synchronously inside task, before it returns cleanup.
      cancelWork();
    } catch (error) {
      if (!settled) {
        settled = true;
        cleanup();
        reject(error);
      }
    }
  });
}

export const storage = (open, explain) => async (name, items, bytes) => {
  const store = await request(open(name, items, bytes), explain);
  return {
    all: async () => Array.from(await request(store.all(), explain)),
    put: (key, body) => request(store.put(new Row(key, body)), explain),
    remove: (key) => request(store.remove(key), explain),
  };
};

export const transport = (send, explain) => async (body, signal) => {
  // Do not even ask the provider to construct work after a prior abort.
  if (signal.aborted) throw Error("Upload cancelled");
  return request(send(body), explain, signal);
};
