// README snippets are excerpts of code that compiles and runs elsewhere in this
// repository, so they cannot drift from the library. Run from the repository root:
//   node --test dev/readme.test.mjs
// A Gleam snippet may be several excerpts joined by a line holding only `// ...`.
// Every excerpt must appear verbatim (ignoring indentation and blank lines) in
// compiled example, consumer or test source, in order within one file. Git dependency
// snippets must match the real package names, paths and repository.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir, access } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const readmes = [
  "README.md",
  "packages/retrace_frontend/README.md",
  "packages/retrace_server/README.md",
];
const skipped = new Set([
  "node_modules",
  "build",
  "dist",
  ".git",
  ".artifacts",
  "target",
]);

async function files(directory, accept) {
  const found = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (skipped.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...(await files(path, accept)));
    else if (accept(path)) found.push(path);
  }
  return found;
}

const lines = (text) =>
  text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "");

// Source of truth: compiled Gleam in examples, consumers and tests, plus the
// consumer programs that dev/git-consumer-check.sh writes and runs.
async function corpus() {
  const roots = ["examples", "support", "test", "packages"];
  const sources = [];
  for (const directory of roots)
    for (const path of await files(resolve(root, directory), (p) =>
      p.endsWith(".gleam"),
    ))
      sources.push(lines(await readFile(path, "utf8")));
  sources.push(
    lines(await readFile(resolve(root, "dev/git-consumer-check.sh"), "utf8")),
  );
  return sources;
}

function contains(haystack, needle, from = 0) {
  for (let start = from; start + needle.length <= haystack.length; start++)
    if (needle.every((line, offset) => haystack[start + offset] === line))
      return start + needle.length;
  return -1;
}

function blocks(markdown, language) {
  const found = [];
  const pattern = new RegExp("```" + language + "\\n([\\s\\S]*?)```", "g");
  for (const match of markdown.matchAll(pattern)) found.push(match[1]);
  return found;
}

test("every README Gleam snippet is a verbatim excerpt of compiled source", async () => {
  const sources = await corpus();
  let checked = 0;
  for (const readme of readmes) {
    const text = await readFile(resolve(root, readme), "utf8");
    for (const block of blocks(text, "gleam")) {
      const segments = block
        .split(/^\s*\/\/ \.\.\.\s*$/m)
        .map(lines)
        .filter((segment) => segment.length > 0);
      const located = sources.some((source) => {
        let position = 0;
        for (const segment of segments) {
          position = contains(source, segment, position);
          if (position < 0) return false;
        }
        return true;
      });
      assert.ok(
        located,
        `${readme}: snippet is not an excerpt of compiled source:\n${block}`,
      );
      checked++;
    }
  }
  assert.ok(checked >= 3, "expected README Gleam snippets to check");
});

test("Git dependency snippets name real packages, paths and the repository", async () => {
  const frontend = await readFile(
    resolve(root, "packages/retrace_frontend/gleam.toml"),
    "utf8",
  );
  const user = /^user = "(.+)"$/m.exec(frontend)[1];
  const repo = /^repo = "(.+)"$/m.exec(frontend)[1];
  const url = `https://github.com/${user}/${repo}.git`;
  const refs = new Set();
  let checked = 0;
  for (const readme of readmes) {
    const text = await readFile(resolve(root, readme), "utf8");
    for (const block of blocks(text, "toml"))
      for (const line of block.split("\n").filter((l) => l.includes("git ="))) {
        const [, name, fields] = /^(\w+) = \{ (.*) \}$/.exec(line.trim());
        const field = (key) =>
          new RegExp(`${key} = "([^"]*)"`).exec(fields)?.[1];
        assert.equal(field("git"), url, `${readme}: ${name} repository`);
        refs.add(field("ref"));
        const path = field("path");
        const manifest = path ? `${path}/gleam.toml` : "gleam.toml";
        await access(resolve(root, manifest));
        const declared = /^name = "(.+)"$/m.exec(
          await readFile(resolve(root, manifest), "utf8"),
        )[1];
        assert.equal(
          declared,
          name,
          `${readme}: ${name} must be the package at ${path ?? "."}`,
        );
        checked++;
      }
  }
  assert.ok(checked >= 4, "expected Git dependency snippets to check");
  assert.equal(refs.size, 1, "all Retrace dependencies share one ref");
});
