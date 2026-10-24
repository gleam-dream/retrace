// Build identity, executed: the application-owned recipe in build.mjs gives the live
// bundle and the preserved replay artifact one build ID, records source provenance in
// the manifest, and refuses to overwrite a published build. Run after `gleam build`:
//   node --test dev/build.test.mjs
// The recipe builds into scratch locations under .artifacts/, never into dist/ or the
// published artifacts.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile, readdir, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  artifactManifest,
  developmentBuild,
  refuseExisting,
  releaseBuildId,
} from "./identity.mjs";

const app = fileURLToPath(new URL("../", import.meta.url));
const root = resolve(app, "../..");
const scratch = resolve(root, `.artifacts/identity-check-${randomUUID()}`);
after(() => rm(scratch, { recursive: true, force: true }));

const build = (id, extra = {}) =>
  promisify(execFile)("node", ["dev/build.mjs"], {
    cwd: app,
    env: {
      ...process.env,
      RETRACE_BUILD_ID: id,
      RETRACE_ARTIFACT_ROOT: resolve(scratch, "artifacts"),
      RETRACE_LIVE_OUT: resolve(scratch, "live"),
      ...extra,
    },
  });

async function bundleText(directory) {
  const files = (await readdir(directory, { recursive: true })).filter((name) =>
    name.endsWith(".js"),
  );
  return (
    await Promise.all(
      files.map((name) => readFile(resolve(directory, name), "utf8")),
    )
  ).join("\n");
}

test("a release build ID is supplied or allocated, and never the mutable development ID", () => {
  assert.equal(
    releaseBuildId("membership-ios-482", () => "unused"),
    "membership-ios-482",
  );
  assert.equal(
    releaseBuildId(undefined, () => "local-1"),
    "local-1",
  );
  assert.throws(
    () => releaseBuildId(developmentBuild, () => "unused"),
    /unique release build ID/,
  );
  assert.throws(
    () => releaseBuildId("has space", () => "unused"),
    /unique release build ID/,
  );
  assert.throws(
    () => releaseBuildId("x".repeat(101), () => "unused"),
    /unique release build ID/,
  );
});

test("the manifest keeps build, contract and source provenance as separate values", () => {
  assert.deepEqual(
    artifactManifest({
      id: "membership-ios-482",
      revision: "a".repeat(40),
      dirty: false,
    }),
    {
      api: 1,
      build: "membership-ios-482",
      contract: "membership-screen-v2",
      source_revision: "a".repeat(40),
      source_dirty: false,
      url: "/artifacts/membership-ios-482/frame.html",
    },
  );
});

test("the recipe preserves one build ID in both bundles and refuses to overwrite it", async () => {
  const id = `identity-check-${randomUUID()}`;
  await build(id);

  const artifact = resolve(scratch, "artifacts", id);
  const manifest = JSON.parse(
    await readFile(resolve(artifact, "manifest.json"), "utf8"),
  );
  assert.equal(manifest.build, id);
  assert.equal(manifest.url, `/artifacts/${id}/frame.html`);
  assert.match(manifest.source_revision, /^[0-9a-f]{40}$/);
  assert.equal(typeof manifest.source_dirty, "boolean");

  // The live application and the replay artifact embed the same identity.
  assert.ok((await bundleText(resolve(scratch, "live"))).includes(id));
  assert.ok((await bundleText(artifact)).includes(id));

  // A later build with the same ID cannot replace the recording's renderer.
  await assert.rejects(build(id), (error) =>
    /already published/.test(error.stderr),
  );
  await assert.rejects(refuseExisting(artifact), /already published/);
});

test("the mutable development ID is refused as a release ID before any bundling", async () => {
  await assert.rejects(build(developmentBuild), (error) =>
    /unique release build ID/.test(error.stderr),
  );
});
