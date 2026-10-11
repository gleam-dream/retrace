// Opt-in native-smoke feature: only the live app belongs in the native shell.
void (async () => {
  const invoke = (command, args) =>
    window.__TAURI_INTERNALS__.invoke(command, args);
  const wait = async (predicate) => {
    for (let i = 0; i < 150; i++) {
      if (predicate()) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw Error("Native check timed out");
  };
  const click = (name) =>
    [...document.querySelectorAll("button")]
      .find((e) => e.textContent === name)
      .click();
  try {
    await wait(
      () =>
        document.querySelector(".delivery")?.textContent ===
        "All saved entries delivered",
    );
    click("Add a point");
    click("Record an unchanged state");
    click("Read device information");
    await wait(
      () =>
        document.querySelector("[data-saved]")?.dataset.saved === "4" &&
        document.querySelector("[data-queued]")?.dataset.queued === "0",
    );
    const device = document.querySelector(
      '[aria-label="Device result"]',
    ).textContent;
    if (!device.includes("macos / aarch64"))
      throw Error(`Unexpected native result: ${device}`);
    await invoke("smoke_report", {
      result: `PASS native capture, store queue, Rust command and durable upload: ${document.querySelector(".session-id").textContent}`,
    });
  } catch (e) {
    await invoke("smoke_report", { result: `FAIL ${e.message}` });
  }
})();
