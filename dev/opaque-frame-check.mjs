// Explicit real-browser gate: npm ci in examples/advanced first, then
// CHROME_BIN=/path/to/chrome npm --prefix examples/advanced test -- opaque-frame-check
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { test } from "../examples/advanced/node_modules/@playwright/test/index.mjs";
const modules = new Set([
  "viewer.mjs",
  "channel.mjs",
  "range.mjs",
  "timeline.mjs",
]);
let origin;
const server = createServer(async (request, response) => {
  const path = new URL(request.url, origin).pathname;
  if (modules.has(path.slice(1))) {
    response.setHeader("content-type", "text/javascript");
    response.end(
      await readFile(
        new URL(`../packages/retrace_frontend/src${path}`, import.meta.url),
      ),
    );
    return;
  }
  if (path !== "/") {
    response.writeHead(404);
    response.end();
    return;
  }
  const frame = `<html><body>Waiting<script>
    const token=window.name.startsWith('retrace:')?window.name.slice(8):'';
    const trusted=${JSON.stringify(origin)};
    window.addEventListener('message',event=>{
      if(event.source!==parent||event.origin!==trusted||event.data?.token!==token||event.data?.api!==1||!token)return;
      if(event.data.type==='load'){
        document.body.dataset.loaded='yes';
        parent.postMessage({api:1,token,type:'loaded',body:JSON.stringify([
          {sequence:0,elapsed:0,viewport:{width:390,height:844}},
          {sequence:1,elapsed:1000,kind:'change',viewport:{width:390,height:844}}
        ])},trusted);
      }
      if(event.data.type==='seek')document.body.dataset.sequence=String(event.data.sequence);
    });
    if(token)parent.postMessage({api:1,token,type:'ready',build:'fixture'},trusted);
  </script></body></html>`;
  response.setHeader("content-type", "text/html");
  response.end(`<html><body><div id="viewer"></div><script type="module">
    import {createViewer} from '/viewer.mjs';
    const batch=JSON.stringify({session:{id:'one',build:'fixture',user_ref:'synthetic',platform:'web'},checkpoint:{sequence:0},entries:[{sequence:1}]});
    window.dispose=createViewer(document.getElementById('viewer'),{
      frameMode:'opaque',listSessions:async()=>[],readRange:async()=>({batches:[batch],next:null}),
      resolveArtifact:async()=>({api:1,build:'fixture',isolated_html:${JSON.stringify(frame).replaceAll("<", "\\u003c")}})
    });
  </script></body></html>`);
});
test.beforeAll(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});
test("opaque frame reload and disposal", async ({ page }) => {
  await page.goto(origin + "/?session=one");
  const frame = page.frameLocator("iframe");
  await frame.locator('body[data-loaded="yes"]').waitFor({ timeout: 3000 });
  const first = await page.locator("iframe").getAttribute("name");
  assert.ok(first.startsWith("retrace:"));
  await page.evaluate(() => {
    window.firstFrame = document.querySelector("iframe");
  });
  await page.locator(".next").click();
  await frame.locator('body[data-sequence="1"]').waitFor({ timeout: 3000 });
  await page.locator(".reload").click();
  await frame.locator('body[data-loaded="yes"]').waitFor({ timeout: 3000 });
  assert.notEqual(await page.locator("iframe").getAttribute("name"), first);
  assert.equal(
    await page.evaluate(
      () => window.firstFrame === document.querySelector("iframe"),
    ),
    false,
  );
  assert.equal(
    await page.locator("iframe").getAttribute("sandbox"),
    "allow-scripts",
  );
  await page.evaluate(() => window.dispose());
  assert.equal(await page.locator("iframe").count(), 0);
  console.log(
    "PASS real opaque iframe load, seek, fresh nonce/window on reload and disposal",
  );
});
