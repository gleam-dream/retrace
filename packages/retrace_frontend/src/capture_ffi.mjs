export const randomId = () => crypto.randomUUID();
export function monotonicClock() {
  const started = performance.now();
  return () => Math.floor(performance.now() - started);
}
