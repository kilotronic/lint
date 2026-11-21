#!/usr/bin/env bash
# Tests for the format and lint bundle's hooks (.pre-commit-hooks.yaml), through `prek try-repo` (or
# `pre-commit try-repo` with HOOK_RUNNER=pre-commit) on this checkout's HEAD: a clean sample of every file type
# passes every hook, and each hook refuses (or rewrites) its own planted defect. CSV files are never rewritten.
# Run: bash test/bundle.sh   (needs prek or pre-commit, Python and Node; installs each tool once, cached)
set -euo pipefail

HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${HOOK_RUNNER:-prek}"
fails=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@kilotronic.com GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@kilotronic.com
unset KILOTRONIC_VISIBILITY

run() { # run <hook id|""> : the hook (or every hook) on every file of the scratch repository
  # shellcheck disable=SC2086 # an empty id runs every hook
  "$RUNNER" try-repo "$HOOKS" ${1:-} --all-files >"$tmp/log" 2>&1
}
# A scratch repository holding a clean sample of every file type the bundle reads.
clean_repo() {
  rm -rf "$tmp/r" && mkdir -p "$tmp/r/.github/workflows" && cd "$tmp/r" && git init -q
  printf 'import os\n\nprint(os.sep)\n' >a.py
  printf '{ "a": [1, 2], "b": { "c": "d" } }\n' >a.json
  printf '// comments are fine here\n{ "compilerOptions": {} }\n' >tsconfig.json
  mkdir -p .vscode
  printf '// and here\n{ "editor.tabSize": 2 }\n' >.vscode/settings.json
  printf '// ASP.NET Core reads comments here\n{ "Logging": {} }\n' >appsettings.Development.json
  printf 'const a = { b: 1 };\nexport default a;\n' >a.js
  printf 'a {\n  color: red;\n}\n' >a.css
  cat >a.md <<'MD'
# Title

Some text with `code` and a [link to the example site](https://example.test).

- one
- two

| a   | b   |
| --- | --- |
| 1   | 2   |

```sh
echo hi
```
MD
  # shellcheck disable=SC2016 # literal workflow text
  printf '# A workflow as prettier writes it.\non:\n  pull_request:\n  push:\n    branches: [main]\npermissions:\n  contents: read # read only\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "$X"\n        env:\n          X: "y"\n' >.github/workflows/w.yml
  printf 'list:\n  - a\n  - b: { c: 1 }\nflag: true\n---\nsecond: doc\n' >a.yaml
  printf '#cloud-config\npackages:\n  - git\n' >user-data.yaml # cloud-init wants no space after the #
  printf '[tool]\na = 1\nb = ["x", "y"]\n' >a.toml
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nif [ -n "$1" ]; then\n  echo "$1"\nfi\n' >a.sh
  printf 'a,b,c\n1,"two, with a comma",3\n4,,6\n' >a.csv
  printf 'a\tb\n1\t2\n' >a.tsv
  printf 'notes\n' >a.txt
  git add -A
}

# --- every hook passes the clean sample, and leaves it as it was
clean_repo
if run ""; then pass "the clean sample passes every hook"; else
  fail "the clean sample passes every hook"
  sed 's/^/     /' "$tmp/log"
fi
if git diff --quiet; then pass "the clean sample is left unchanged"; else
  fail "the clean sample is left unchanged"

  git diff | sed 's/^/     /'
fi

# defect <hook> <file> <content> [<description>]: the hook alone must fail on the clean sample plus this file.
defect() {
  local hook=$1 file=$2 content=$3 what="${4:-$2}"
  clean_repo
  mkdir -p "$(dirname "$file")"
  printf '%b' "$content" >"$file"
  git add -A
  if run "$hook"; then
    fail "$hook refuses $what"
    sed 's/^/     /' "$tmp/log"
  else pass "$hook refuses $what"; fi
}

# --- format-all: each formatter rewrites what is not in its format (and so fails the commit)
defect ruff-format b.py 'x=1\n' "unformatted Python"
defect prettier b.json '{"a":1}\n' "unformatted JSON"
defect prettier b.ts 'const a:number=1\n' "unformatted TypeScript"
defect prettier b.css 'a{color:red}\n' "unformatted CSS"
defect prettier b.md '* one\n* two\n' "unformatted Markdown"
defect prettier b.yaml 'a:   1\n' "unformatted YAML"
defect shfmt b.sh '#!/bin/sh\nif true; then\necho hi\nfi\n' "an unindented shell script"
defect taplo-format b.toml 'a=1\n' "unformatted TOML"

# --- lint-all: each linter refuses its finding
defect ruff-check b.py 'import os\n' "an unused import"
defect markdownlint b.md '# A\n\n## B\n\n## B\n' "a repeated sibling heading"
# shellcheck disable=SC2016 # literal Markdown
defect markdownlint b.md '# A\n\n```\necho\n```\n' "a code fence with no language"
defect yamllint b.yaml 'a: yes\n' "a yes/no boolean"
defect yamllint b.yaml 'a: 1\na: 2\n' "a repeated key"
defect yamllint b.yaml '#comment\na: 1\n' "a first-line comment with no space that is not #cloud-config"
defect yamllint b.yaml '#cloud-config\na: yes\n' "a yes/no boolean in a #cloud-config file"
defect csv-lint b.csv 'a,b\n1,2,3\n' "a row with an extra column"
defect csv-lint b.csv 'a,b\n1\n' "a row with a missing column"
defect csv-lint b.csv 'a,b\n1,2' "a CSV with no final newline"
defect csv-lint b.csv 'a,b\n\xff,2\n' "a CSV that is not UTF-8"
defect csv-lint b.tsv 'a\tb\n1\t2\t3\n' "a TSV row with an extra column"
defect check-json b.json '{"a": }\n' "invalid JSON"
defect check-yaml b.yaml 'a: [\n' "invalid YAML"
defect check-toml b.toml 'a = \n' "invalid TOML"
defect end-of-file-fixer b.txt 'no newline' "a file with no final newline"
defect trailing-whitespace b.txt 'a  \n' "trailing whitespace"
defect mixed-line-ending b.txt 'a\r\nb\n' "mixed line endings"
defect check-merge-conflict b.txt 'a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n' "conflict markers"
# shellcheck disable=SC2016 # the $1 is meant literally: it is the finding
defect shellcheck b.sh '#!/bin/sh\necho $1\n' "an unquoted variable"
defect actionlint .github/workflows/b.yml 'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: no-such-label\n    steps:\n      - run: echo hi\n' "an unknown runner label"
defect pinned .github/workflows/b.yml 'on: push\npermissions: {}\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n' "an action by tag"
defect workflow-safety .github/workflows/b.yml 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' "a workflow with no top-level permissions"
defect non-root Dockerfile 'FROM scratch\n' "a Dockerfile that runs as root"

# --- CSV is data: no hook rewrites it, whatever it holds
clean_repo
printf 'a,b \n1,2' >b.csv
printf 'a,b\r\n1,2\n' >c.csv
cp b.csv "$tmp/b.csv" && cp c.csv "$tmp/c.csv"
git add -A
run "" || true
if cmp -s b.csv "$tmp/b.csv" && cmp -s c.csv "$tmp/c.csv"; then pass "no hook rewrites a CSV file"; else fail "no hook rewrites a CSV file"; fi

# --- a #cloud-config first line is allowed after a UTF-8 byte order mark too
clean_repo
printf '\xef\xbb\xbf#cloud-config\npackages:\n  - git\n' >bom-user-data.yaml
git add -A
if run yamllint; then pass "yamllint allows #cloud-config after a byte order mark"; else
  fail "yamllint allows #cloud-config after a byte order mark"
  sed 's/^/     /' "$tmp/log"
fi

# --- a file that is all CRLF (a VBA module, a .bat) keeps its line endings; only mixed files are fixed
clean_repo
printf 'Attribute VB_Name = "Module1"\r\nSub A()\r\nEnd Sub\r\n' >Module1.bas
printf 'one\r\ntwo\r\n' >windows.txt
cp Module1.bas windows.txt "$tmp/"
git add -A
if run "" && cmp -s Module1.bas "$tmp/Module1.bas" && cmp -s windows.txt "$tmp/windows.txt"; then
  pass "files that are all CRLF pass every hook, unchanged"
else
  fail "files that are all CRLF pass every hook, unchanged"
  sed 's/^/     /' "$tmp/log"
fi

# --- ruff honours the repository's own exclude (prek passes it file names; --force-exclude applies the config)
clean_repo
mkdir vendored && printf 'import os\nx=1\n' >vendored/third_party.py
printf 'extend-exclude = ["vendored"]\n' >ruff.toml
git add -A
if run ruff-format && run ruff-check; then pass "ruff skips what ruff.toml's extend-exclude names"; else
  fail "ruff skips what ruff.toml's extend-exclude names"
  sed 's/^/     /' "$tmp/log"
fi

# --- a repository's own exclude: adds to the bundle's skips instead of replacing them
clean_repo
printf 'a,b \r\n1,2' >other.csv                             # CSV: never rewritten
printf '{"lockfileVersion":3}\n' >package-lock.json         # a lockfile: prettier leaves it alone
printf '// comments\n{ "Logging": {} }\n' >appsettings.json # JSON with comments: check-json skips it
cp other.csv package-lock.json "$tmp/"
{
  echo "repos:"
  echo "  - repo: $HOOKS"
  echo "    rev: $(git -C "$HOOKS" rev-parse HEAD)"
  echo "    hooks:"
  for h in prettier check-json end-of-file-fixer trailing-whitespace mixed-line-ending; do
    printf '      - id: %s\n        exclude: ^other/\n' "$h"
  done
} >.pre-commit-config.yaml
git add -A
if "$RUNNER" run --all-files >"$tmp/log" 2>&1 && cmp -s other.csv "$tmp/other.csv" && cmp -s package-lock.json "$tmp/package-lock.json"; then
  pass "a repository's own exclude: keeps the bundle's skips"
else
  fail "a repository's own exclude: keeps the bundle's skips"
  sed 's/^/     /' "$tmp/log"
  git diff | sed 's/^/     /'
fi

# --- a repository's own configuration wins over the bundle's defaults
clean_repo
printf 'a: %s\n' "$(printf 'x%.0s' $(seq 100))" >long.yaml
printf 'extends: default\nrules:\n  line-length: {max: 80}\n  document-start: disable\n' >.yamllint
git add -A
if run yamllint; then fail "yamllint reads the repository's .yamllint"; else pass "yamllint reads the repository's .yamllint"; fi
# A repository's own .markdownlint.* adds to the bundle's defaults instead of replacing them.
for own in '.markdownlint.yaml|MD026: false\n' '.markdownlint.jsonc|// comment\n{ "MD026": false }\n'; do
  clean_repo
  printf '%b' "${own#*|}" >"${own%%|*}"
  printf '# A\n\nA line that is much longer than eighty characters, so markdownlint would object to it on its own.\n\n## Hello!\n\n<b>inline HTML</b>\n' >keep.md
  git add -A
  if run markdownlint; then pass "a repository's own ${own%%|*} adds to the bundle's defaults"; else
    fail "a repository's own ${own%%|*} adds to the bundle's defaults"
    sed 's/^/     /' "$tmp/log"
  fi
done
clean_repo
printf 'MD026: false\n' >.markdownlint.yaml
printf '# A\n\n# B\n' >two.md # MD025, which the bundle's defaults keep on
git add -A
if run markdownlint; then fail "the bundle's defaults still apply under a repository's own file"; else pass "the bundle's defaults still apply under a repository's own file"; fi
clean_repo
printf 'extends: null\ndefault: true\n' >.markdownlint.yaml
printf '# A\n\n<b>inline HTML</b>\n' >html.md
git add -A
if run markdownlint; then fail "a repository's own extends: replaces the bundle's defaults"; else pass "a repository's own extends: replaces the bundle's defaults"; fi
clean_repo
printf '{ "default": true, "MD013": { "line_length": 20 } }\n' >.markdownlint.json
printf '# A\n\nA line that is longer than twenty characters.\n' >long.md
git add -A
if run markdownlint; then fail "markdownlint reads the repository's own configuration"; else pass "markdownlint reads the repository's own configuration"; fi
clean_repo
rm a.sh # indented with spaces, which this .editorconfig does not ask for
printf 'root = true\n[*.sh]\nindent_style = tab\n' >.editorconfig
printf '#!/bin/sh\nif true; then\n\techo hi\nfi\n' >tabs.sh
git add -A
if run shfmt; then pass "shfmt reads the repository's .editorconfig"; else
  fail "shfmt reads the repository's .editorconfig"
  sed 's/^/     /' "$tmp/log"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
