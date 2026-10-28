import { mount } from "./build/dev/javascript/retrace_inventory/protected_example/frame.mjs";
const dispose = mount();
window.addEventListener("pagehide", dispose, { once: true });
if (import.meta.hot) import.meta.hot.dispose(dispose);
