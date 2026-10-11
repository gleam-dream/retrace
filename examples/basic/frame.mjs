import { mount } from "./build/dev/javascript/retrace_inventory/retrace_inventory/frame.mjs";
const dispose = mount();
window.addEventListener("pagehide", dispose, { once: true });
// Exposed only by this consumer harness to exercise lifecycle explicitly.
window.disposeReplay = dispose;
