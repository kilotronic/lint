#!/usr/bin/env node
// markdownlint-cli2 with the bundle's defaults (.markdownlint.jsonc here) underneath the repository's own
// configuration. Files are passed as literal paths, not globs.
//
// - No configuration of its own: the bundle's defaults.
// - A .markdownlint.{jsonc,json,yaml,yml} at the top: it extends the bundle's defaults, so it only has to
//   name what it changes. One that sets `extends` itself (even `extends: null`) is used as it is.
// - A .markdownlint-cli2.* or a .cjs/.mjs configuration: used whole, as markdownlint-cli2 reads it.
import { existsSync, promises } from "node:fs";
import * as fsNode from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { main } from "markdownlint-cli2";
import jsoncParse from "markdownlint-cli2/parsers/jsonc";
import yamlParse from "markdownlint-cli2/parsers/yaml";

const cli2Files = [
  ".markdownlint-cli2.jsonc",
  ".markdownlint-cli2.yaml",
  ".markdownlint-cli2.cjs",
  ".markdownlint-cli2.mjs",
];
// markdownlint-cli2's own order: the first of these that exists is the directory's configuration.
const configFiles = [
  ".markdownlint.jsonc",
  ".markdownlint.json",
  ".markdownlint.yaml",
  ".markdownlint.yml",
  ".markdownlint.cjs",
  ".markdownlint.mjs",
];
const here = path.dirname(fileURLToPath(import.meta.url));
const defaults = path.join(here, ".markdownlint.jsonc");
const argv = process.argv.slice(2).map((f) => `:${f}`);

const params = {
  argv,
  logMessage: console.log,
  logError: console.error,
};
// The repository's file as an object; {} when it holds nothing; null when it does not parse (then
// markdownlint-cli2 reads it itself and reports the error).
const readOwn = async (file) => {
  const text = await promises.readFile(file, "utf8");
  const parse = /\.ya?ml$/.test(file) ? yamlParse : jsoncParse;
  try {
    return parse(text) ?? {};
  } catch {
    return /^(\s|#.*|\/\/.*)*$/.test(text) ? {} : null;
  }
};
const own = configFiles.find((f) => existsSync(f));
if (cli2Files.some((f) => existsSync(f)) || /\.[cm]js$/.test(own ?? "")) {
  // used whole
} else if (!own) {
  params.argv = ["--config", defaults, ...argv];
} else {
  // Hand markdownlint-cli2 the repository's file with `extends` pointing at the bundle's defaults.
  const ownPath = path.resolve(own);
  const config = await readOwn(ownPath);
  if (
    config &&
    typeof config === "object" &&
    !Array.isArray(config) &&
    !("extends" in config)
  ) {
    const layeredText = JSON.stringify({ extends: defaults, ...config });
    const isOwn = (file) => path.resolve(String(file)) === ownPath;
    // markdownlint reads a .markdownlint.* file with the callback readFile, markdownlint-cli2 its own with
    // the promise one: answer both.
    params.fs = {
      ...fsNode,
      readFile: (file, ...rest) => {
        if (!isOwn(file)) return fsNode.readFile(file, ...rest);
        const callback = rest.at(-1);
        process.nextTick(() => callback(null, layeredText));
      },
      promises: {
        ...promises,
        readFile: (file, ...rest) =>
          isOwn(file)
            ? Promise.resolve(layeredText)
            : promises.readFile(file, ...rest),
      },
    };
  }
}
try {
  process.exitCode = await main(params);
} catch (error) {
  console.error(error);
  process.exitCode = 2;
}
