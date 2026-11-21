#!/usr/bin/env node
// markdownlint-cli2 with the repository's own configuration when it has one, and the bundle's defaults
// (default.markdownlint.jsonc) when it has none. Files are passed as literal paths, not globs.
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const own = [
  ".markdownlint-cli2.jsonc",
  ".markdownlint-cli2.yaml",
  ".markdownlint-cli2.cjs",
  ".markdownlint-cli2.mjs",
  ".markdownlint.jsonc",
  ".markdownlint.json",
  ".markdownlint.yaml",
  ".markdownlint.yml",
  ".markdownlint.cjs",
  ".markdownlint.mjs",
];
const here = path.dirname(fileURLToPath(import.meta.url));
const config = own.some((f) => existsSync(f))
  ? []
  : ["--config", path.join(here, ".markdownlint.jsonc")];
const files = process.argv.slice(2).map((f) => `:${f}`);
const run = spawnSync("markdownlint-cli2", [...config, ...files], {
  stdio: "inherit",
});
process.exit(run.status ?? 1);
