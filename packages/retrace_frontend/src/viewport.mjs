// Optional browser/Tauri observation. Applications choose their own event schema.
export function viewport() {
  const probe = document.createElement("div");
  probe.style.cssText =
    "position:fixed;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)";
  document.body.append(probe);
  const css = getComputedStyle(probe);
  const value = {
    width: innerWidth,
    height: innerHeight,
    top: Math.round(parseFloat(css.paddingTop) || 0),
    bottom: Math.round(parseFloat(css.paddingBottom) || 0),
  };
  probe.remove();
  return value;
}
export function observeViewport(callback) {
  let pending;
  const resize = () => {
    clearTimeout(pending);
    pending = setTimeout(() => callback(viewport()), 100);
  };
  window.addEventListener("resize", resize);
  return () => {
    clearTimeout(pending);
    window.removeEventListener("resize", resize);
  };
}

const typed = (make, v) => make(v.width, v.height, v.top, v.bottom);
export const readTyped = (make) => typed(make, viewport());
export const observeTyped = (make, callback) =>
  observeViewport((value) => callback(typed(make, value)));
