// Independent clock arithmetic; the host owns animation frames and visibility.
export function positionAt(events, time) {
  let low = 0,
    high = events.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (events[middle].elapsed <= time) low = middle + 1;
    else high = middle;
  }
  return Math.max(0, low - 1);
}
export const advance = (position, delta, speed, duration) =>
  Math.min(duration, Math.max(0, position + Math.max(0, delta) * speed));
export function clusters(events, duration, width, start = 0) {
  const groups = [];
  for (const event of events) {
    const last = groups.at(-1);
    if (
      last &&
      ((event.elapsed - last[0].elapsed) / Math.max(1, duration - start)) *
        width <
        12
    )
      last.push(event);
    else groups.push([event]);
  }
  return groups;
}

// Equal-time events form one observable point on the time axis.
export function previousTime(events, time) {
  return events.findLast((event) => event.elapsed < time)?.elapsed ?? 0;
}
