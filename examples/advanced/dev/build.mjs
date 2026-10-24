import { build } from "vite";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile, rm, rename } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  artifactManifest,
  refuseExisting,
  releaseBuildId,
} from "./identity.mjs";
const app = fileURLToPath(new URL("../", import.meta.url));
const id = releaseBuildId(
  process.env.RETRACE_BUILD_ID,
  () => `local-${randomUUID()}`,
);
const root = resolve(app, "../.."),
  // The overrides let a check build into a scratch location without touching the
  // application's own dist/ or published artifacts.
  artifactRoot = process.env.RETRACE_ARTIFACT_ROOT
    ? resolve(process.env.RETRACE_ARTIFACT_ROOT)
    : resolve(app, "viewer/public/artifacts"),
  liveOut = process.env.RETRACE_LIVE_OUT
    ? resolve(process.env.RETRACE_LIVE_OUT)
    : undefined,
  artifact = resolve(artifactRoot, id),
  staging = resolve(root, `.artifacts/replay-${randomUUID()}`);
await mkdir(artifactRoot, { recursive: true });
await refuseExisting(artifact);
const define = { __RETRACE_BUILD__: JSON.stringify(id) };
const git = (...args) =>
  execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
try {
  await build({
    root: app,
    configFile: resolve(app, "vite.config.mjs"),
    define,
    ...(liveOut && { build: { outDir: liveOut, emptyOutDir: true } }),
  });
  await build({
    root: app,
    configFile: resolve(app, "vite.config.mjs"),
    define,
    base: "./",
    build: {
      outDir: staging,
      emptyOutDir: true,
      rollupOptions: { input: resolve(app, "frame.html") },
    },
  });
  const manifest = artifactManifest({
    id,
    revision: git("rev-parse", "HEAD"),
    dirty: Boolean(git("status", "--porcelain", "--untracked-files=normal")),
  });
  await writeFile(
    resolve(staging, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  await rename(staging, artifact);
  console.log(`Replay artifact: ${manifest.url}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
