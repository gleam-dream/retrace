// Public package boundary checks in a real browser; no production services needed.
import {
  chromium,
  expect,
} from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage(),
    errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("http://127.0.0.1:5193/");
  await expect(
    page.getByRole("status", { name: "Recording delivery" }),
  ).toHaveText("All saved entries delivered");
  await page.getByRole("button", { name: "Receive one", exact: true }).click();
  await expect(
    page.getByRole("status", { name: "Recording delivery" }),
  ).toHaveText("All saved entries delivered");
  await page.getByRole("link", { name: "Inspect this recording" }).click();
  await expect(
    page.getByRole("button", { name: /Received a notebook.*#1/ }),
  ).toBeVisible();
  const result = await page.evaluate(async () => {
    const v =
      await import("/build/dev/javascript/retrace_frontend/retrace_frontend/viewer.mjs");
    const { Result$Ok, toList } =
      await import("/build/dev/javascript/retrace_frontend/gleam.mjs");
    const { None } =
      await import("/build/dev/javascript/gleam_stdlib/gleam/option.mjs");
    const vp =
      await import("/build/dev/javascript/retrace_frontend/retrace_frontend/viewport.mjs");
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    window.disposeViewer();
    const root = document.querySelector("#viewer"),
      initialStyles = document.head.querySelectorAll("style").length;
    const sessionId = new URL(location.href).searchParams.get("session");
    const bodies = await fetch(
      `http://127.0.0.1:4417/sessions/${sessionId}/batches?after=0`,
    ).then((r) => r.json());
    const body = bodies[0],
      batch = JSON.parse(body);
    let searches = [],
      resolverReply,
      searchCancelled = 0,
      resolverCancelled = 0;
    const source = new v.Source(
      () => (reply) => {
        searches.push(reply);
        return () => searchCancelled++;
      },
      () => (reply) => {
        reply(Result$Ok(new v.Page(toList([body]), new None())));
        return () => {};
      },
    );
    const config = v.new$(source, () => (reply) => {
      resolverReply = reply;
      return () => resolverCancelled++;
    });
    if (v.mount(config, "#absent").isOk())
      throw Error("Missing host should fail");
    const mounted = v.mount(config, "#viewer");
    if (!mounted.isOk()) throw Error(mounted[0]);
    await wait(50);
    root.querySelector("form").requestSubmit();
    await wait(10);
    if (searchCancelled !== 1 || searches.length !== 2)
      throw Error("Repeated search did not cancel");
    searches[0](Result$Ok(toList([new v.Summary(batch.session, 777)])));
    if (root.textContent.includes("777 events"))
      throw Error("Stale search updated UI");
    mounted[0]();
    mounted[0]();
    resolverReply(
      Result$Ok(new v.Artifact(batch.session.build, "/frame.html", true)),
    );
    searches[1](Result$Ok(toList([])));
    await wait(10);
    if (
      searchCancelled !== 2 ||
      resolverCancelled !== 1 ||
      root.children.length !== 0
    )
      throw Error("Pending work survived dispose");
    if (document.head.querySelectorAll("style").length !== initialStyles)
      throw Error("Styles leaked");
    const again = v.mount(config, "#viewer");
    if (!again.isOk()) throw Error(again[0]);
    mounted[0]();
    if (!root.classList.contains("retrace-viewer"))
      throw Error("Old disposal damaged new mount");
    again[0]();
    let observations = 0;
    const value = vp.read();
    if (value.width !== innerWidth || value.height !== innerHeight)
      throw Error("Typed viewport invalid");
    const unobserve = vp.observe(() => observations++);
    dispatchEvent(new Event("resize"));
    await wait(150);
    unobserve();
    unobserve();
    dispatchEvent(new Event("resize"));
    await wait(150);
    if (observations !== 1) throw Error("Viewport observer survived disposal");
    return { searchCancelled, resolverCancelled, observations };
  });
  if (errors.length) throw Error(errors.join("\n"));
  console.log(
    "PASS public viewer cancellation, stale replies, remount, styles, typed viewport cleanup",
    result,
  );
} finally {
  await browser.close();
}
