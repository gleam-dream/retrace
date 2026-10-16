// Host policy returns { batches: encodedStrings, next: absoluteSequence | null }.
// Existing callers retain complete bounded-range loading by default.
export async function loadRange(
  readRange,
  id,
  { after = 0, maxEntries = 5000, pageSize = 128, signal } = {},
) {
  if (
    !Number.isSafeInteger(after) ||
    after < 0 ||
    !Number.isSafeInteger(maxEntries) ||
    maxEntries < 1 ||
    !Number.isSafeInteger(pageSize) ||
    pageSize < 1 ||
    pageSize > 128
  )
    throw Error("Invalid range bounds");
  const all = [];
  let cursor = after,
    count = 0;
  while (true) {
    signal?.throwIfAborted();
    const page = await readRange(id, {
      after: cursor,
      limit: pageSize,
      signal,
    });
    signal?.throwIfAborted();
    if (!Array.isArray(page.batches) || page.batches.length > pageSize)
      throw Error("Invalid range page");
    for (const encoded of page.batches) {
      const batch = JSON.parse(encoded);
      if (
        batch.session?.id !== id ||
        batch.checkpoint?.sequence !== cursor ||
        !Array.isArray(batch.entries) ||
        !batch.entries.length ||
        batch.entries.length > 128
      )
        throw Error("Missing or invalid recording range");
      for (const entry of batch.entries) {
        if (entry.sequence !== cursor + 1)
          throw Error("Missing recorded entry");
        cursor = entry.sequence;
      }
      count += batch.entries.length;
      if (count > maxEntries)
        throw Error(
          `This viewer retains at most ${maxEntries.toLocaleString("en-US")} entries; request a smaller range.`,
        );
      all.push(encoded);
    }
    if (page.next === null) return all;
    if (!page.batches.length || page.next !== cursor)
      throw Error("Range cursor did not advance");
  }
}

// A selected recording owns one reader. next() commits a fully checked page
// before exposing whole-batch windows, and failures leave its cursor retryable.
// Pages and the retained recording have separate byte/entry bounds. No prefetch
// occurs here: the viewer starts the next read only after frame acknowledgement.
export function createRangeReader(
  readRange,
  id,
  {
    after = 0,
    maxEntries = 5000,
    maxBytes = 32 * 1024 * 1024,
    pageSize = 128,
    windowMs = 300000,
    windowEntries = 256,
    windowBytes = 1024 * 1024,
    signal,
  } = {},
) {
  if (
    !Number.isSafeInteger(after) ||
    after < 0 ||
    ![
      maxEntries,
      maxBytes,
      pageSize,
      windowMs,
      windowEntries,
      windowBytes,
    ].every((n) => Number.isSafeInteger(n) && n > 0) ||
    pageSize > 128
  )
    throw Error("Invalid progressive range bounds");
  let cursor = after,
    count = 0,
    bytes = 0,
    identity,
    elapsed,
    pending = [],
    complete = false,
    busy = false;
  const encoder = new TextEncoder();
  const sessionIdentity = (s) => [
    s?.id,
    s?.build,
    s?.contract,
    s?.user_ref,
    s?.platform,
  ];
  async function readPage() {
    signal?.throwIfAborted();
    const page = await readRange(id, {
      after: cursor,
      limit: pageSize,
      signal,
    });
    signal?.throwIfAborted();
    if (!page || !Array.isArray(page.batches) || page.batches.length > pageSize)
      throw Error("Invalid range page");
    let next = cursor,
      nextCount = count,
      nextBytes = bytes,
      nextIdentity = identity,
      nextElapsed = elapsed;
    const checked = [];
    for (const encoded of page.batches) {
      if (typeof encoded !== "string")
        throw Error("Invalid encoded recording batch");
      const size = encoder.encode(encoded).byteLength;
      nextBytes += size;
      if (size > 1024 * 1024 || nextBytes > maxBytes)
        throw Error(
          "Recording exceeds the retained byte budget; request a smaller range.",
        );
      const batch = JSON.parse(encoded),
        currentIdentity = sessionIdentity(batch.session);
      if (
        currentIdentity.some((v) => typeof v !== "string" || !v.length) ||
        batch.session.id !== id ||
        (nextIdentity &&
          currentIdentity.some((v, i) => v !== nextIdentity[i])) ||
        batch.checkpoint?.sequence !== next ||
        !Number.isSafeInteger(batch.checkpoint?.elapsed_ms) ||
        batch.checkpoint.elapsed_ms < 0 ||
        (nextElapsed !== undefined &&
          batch.checkpoint.elapsed_ms !== nextElapsed) ||
        !Array.isArray(batch.entries) ||
        !batch.entries.length ||
        batch.entries.length > 128
      )
        throw Error("Missing or invalid recording range");
      nextIdentity = currentIdentity;
      nextElapsed = batch.checkpoint.elapsed_ms;
      for (const entry of batch.entries) {
        if (
          !Number.isSafeInteger(entry.sequence) ||
          entry.sequence !== next + 1 ||
          !Number.isSafeInteger(entry.elapsed_ms) ||
          entry.elapsed_ms < nextElapsed
        )
          throw Error("Missing or invalid recorded entry");
        next = entry.sequence;
        nextElapsed = entry.elapsed_ms;
      }
      nextCount += batch.entries.length;
      if (nextCount > maxEntries)
        throw Error(
          `This viewer retains at most ${maxEntries.toLocaleString("en-US")} entries; request a smaller range.`,
        );
      checked.push({
        encoded,
        size,
        count: batch.entries.length,
        start: batch.checkpoint.elapsed_ms,
        end: nextElapsed,
        after: next,
      });
    }
    if (page.next !== null && (!page.batches.length || page.next !== next))
      throw Error("Range cursor did not advance");
    // Commit only after the entire page, cursor and budgets are valid.
    cursor = next;
    count = nextCount;
    bytes = nextBytes;
    identity = nextIdentity;
    elapsed = nextElapsed;
    pending = checked;
    complete = page.next === null;
  }
  return {
    async next() {
      if (busy) throw Error("A progressive range read is already pending");
      busy = true;
      try {
        signal?.throwIfAborted();
        if (!pending.length && !complete) await readPage();
        const batches = [];
        let size = 0,
          entries = 0,
          start = pending[0]?.start,
          end = start,
          last = pending[0]
            ? JSON.parse(pending[0].encoded).checkpoint.sequence
            : cursor;
        while (pending.length) {
          const item = pending[0];
          // A batch is the smallest independently replayable range. Never split
          // it or synthesize checkpoints; one long batch may exceed time target.
          if (
            batches.length &&
            (item.end - start > windowMs ||
              entries + item.count > windowEntries ||
              size + item.size > windowBytes)
          )
            break;
          pending.shift();
          batches.push(item.encoded);
          size += item.size;
          entries += item.count;
          end = item.end;
          last = item.after;
        }
        return {
          batches,
          after: last,
          complete: complete && !pending.length,
          start,
          end,
          entries,
          bytes: size,
        };
      } finally {
        busy = false;
      }
    },
  };
}
