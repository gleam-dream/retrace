import { build } from "vite";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, writeFile, access, rm, rename } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
const app = fileURLToPath(new URL("../", import.meta.url));
const id = process.env.RETRACE_BUILD_ID || `local-${randomUUID()}`;
if (!/^[a-zA-Z0-9_-]{1,100}$/.test(id) || id === "membership-screen-v2-dev")
  throw Error(
    "Use a unique release build ID (letters, digits, underscore, hyphen)",
  );
const root = resolve(app, "../.."),
  artifact = resolve(app, `viewer/public/artifacts/${id}`),
  staging = resolve(root, `.artifacts/replay-${randomUUID()}`);
await mkdir(resolve(app, "viewer/public/artifacts"), { recursive: true });
try {
  await access(artifact);
  throw Error("Build ID already published locally; choose a new ID");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const define = { __RETRACE_BUILD__: JSON.stringify(id) };
try {
  await build({
    root: app,
    configFile: resolve(app, "vite.config.mjs"),
    define,
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
  const manifest = {
    api: 1,
    build: id,
    contract: "membership-screen-v2",
    source_revision: execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: root,
      encoding: "utf8",
    }).trim(),
    source_dirty: Boolean(
      execFileSync(
        "git",
        ["status", "--porcelain", "--untracked-files=normal"],
        { cwd: root, encoding: "utf8" },
      ).trim(),
    ),
    url: `/artifacts/${id}/frame.html`,
  };
  await writeFile(
    resolve(staging, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  await rename(staging, artifact);
  console.log(`Replay artifact: ${manifest.url}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
