// Loaded only by the opt-in native-smoke Cargo feature and environment flag.
void (async () => {
  const invoke = (command, args) =>
    window.__TAURI_INTERNALS__.invoke(command, args);
  const wait = async (predicate) => {
    for (let i = 0; i < 150; i++) {
      if (predicate()) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error("Native check timed out: " + document.body.innerText);
  };
  const fact = (name) =>
    [...document.querySelectorAll(".fact")]
      .find((e) => e.querySelector("span").textContent === name)
      ?.querySelector("strong").textContent;
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
    if (fact("Platform") !== "tauri") throw new Error("Not the native runtime");
    click("Add a point");
    click("Record an unchanged state");
    click("Read device information");
    await wait(
      () => fact("Saved locally") === "4" && fact("Queued batches") === "0",
    );
    const device = document.querySelector(
      '[aria-label="Device result"]',
    ).textContent;
    if (!device.includes("macos / aarch64"))
      throw new Error(`Unexpected native result: ${device}`);
    const id = document.querySelector(".session-id").textContent;
    click("Browse sessions");
    await wait(() =>
      [...document.querySelectorAll(".session-row")].some((e) =>
        e.textContent.includes(id),
      ),
    );
    [...document.querySelectorAll(".session-row")]
      .find((e) => e.textContent.includes(id))
      .click();
    await wait(
      () =>
        document.querySelector('[aria-label="Recorded device result"]')
          ?.textContent === device,
    );
    click("First");
    await wait(
      () => document.querySelector("[data-points]")?.textContent === "0",
    );
    click("Latest");
    await wait(
      () => document.querySelector("[data-points]")?.textContent === "1",
    );
    await invoke("smoke_report", {
      result: `PASS native WebView, store-plugin persistence, Rust command, durable upload and inert replay: ${id}`,
    });
  } catch (e) {
    await invoke("smoke_report", { result: `FAIL ${e.message}` });
  }
})();
