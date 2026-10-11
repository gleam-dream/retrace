// Host policy returns { batches: encodedStrings, next: absoluteSequence | null }.
// This bounded collector is replaceable by a windowed controller in a future UI.
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
