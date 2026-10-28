import { main } from "./build/dev/javascript/retrace_inventory/protected_example.mjs";
const dispose = main();
window.addEventListener("pagehide", dispose, { once: true });
if (import.meta.hot) import.meta.hot.dispose(dispose);
