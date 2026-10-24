import { main } from "./build/dev/javascript/retrace_viewer_example/retrace_viewer_example.mjs";
const dispose = main();
window.addEventListener("pagehide", dispose, { once: true });
if (import.meta.hot) import.meta.hot.dispose(dispose);

window.addEventListener("pageshow", (event) => {
  if (event.persisted) location.reload();
});
