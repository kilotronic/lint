#!/usr/bin/env bash
# Tests for src/lint.sh, run in throwaway git repositories: each check refuses what it is there to refuse
# and passes what it allows, the verdict fails when any check did, and the hooks honour --exclude.
# Run: bash test/test.sh   (downloads the pinned shellcheck and actionlint once, like the hooks do)
set -euo pipefail

LINT="$(cd "$(dirname "$0")/.." && pwd)/src/lint.sh"
fails=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
# expect <name> <0|1> <command...>: the command must succeed (0) or fail (1).
expect() {
  local name=$1 want=$2 got=0
  shift 2
  "$@" >"$tmp/log" 2>&1 || got=1
  if [ "$got" = "$want" ]; then pass "$name"; else
    fail "$name"
    sed 's/^/     /' "$tmp/log"
  fi
}
# refuses <name> <command...>: the command must fail with a finding (a "path:line: why" line), not a crash.
refuses() {
  local name=$1 got=0
  shift
  "$@" >"$tmp/log" 2>&1 || got=1
  if [ "$got" = 1 ] && grep -qE '^[^ ]+:[0-9]+: ' "$tmp/log" && ! grep -q Traceback "$tmp/log"; then pass "$name"; else
    fail "$name"
    sed 's/^/     /' "$tmp/log"
  fi
}
# A fresh repository with only the given files (path, content pairs), all staged.
repo() {
  rm -rf "$tmp/r" && mkdir -p "$tmp/r" && cd "$tmp/r" && git init -q
  while [ $# -gt 0 ]; do
    mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" >"$1"
    shift 2
  done
  git add -A
}
lint() { bash "$LINT" "$@"; }
workflow() { # workflow <uses-line or ""> [runs-on]
  printf 'on: push\njobs:\n  a:\n    runs-on: %s\n    steps:\n%s      - run: echo hi\n' "${2:-ubuntu-latest}" \
    "${1:+      - $1
}"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unset EXCLUDE SHELLCHECK_ARGS ACTIONLINT_ARGS SHELLCHECK RUNNER_TEMP GITHUB_OUTPUT LINT_BIN \
  SHELLCHECK_OUTCOME ACTIONLINT_OUTCOME PINNED_OUTCOME \
  WORKFLOW_SAFETY_OUTCOME NON_ROOT_OUTCOME KILOTRONIC_VISIBILITY SKIP_CHECKS
sha=$(printf 'a%.0s' $(seq 40))
digest=$(printf '0%.0s' $(seq 64))
# shellcheck disable=SC2016 # the $1 is meant literally: it is the finding
bad_sh='echo $1'
# shellcheck disable=SC2016
good_sh='#!/bin/sh
echo "$1"'

# --- install: pinned tools into the cache, and LINT_BIN for the other steps
export XDG_CACHE_HOME="$tmp/cache" GITHUB_OUTPUT="$tmp/out"
expect "install downloads both tools" 0 lint install
LINT_BIN=$(sed -n 's/^bin=//p' "$GITHUB_OUTPUT")
export LINT_BIN
unset GITHUB_OUTPUT

# --- shellcheck
repo a.sh "$good_sh" b.bash "$good_sh" tool "$good_sh" notes.txt "$bad_sh" lib/x.py "$bad_sh"
expect "shellcheck passes clean scripts and skips other extensions" 0 lint shellcheck
repo a.sh "$bad_sh"
expect "shellcheck refuses a .sh file" 1 lint shellcheck
repo a.bash "$bad_sh"
expect "shellcheck refuses a .bash file" 1 lint shellcheck
for shebang in '#!/bin/sh' '#!/bin/bash' '#!/usr/bin/env bash' '#!/bin/dash' '#!/bin/ksh'; do
  repo tool "$shebang
$bad_sh"
  expect "shellcheck refuses an extension-less file with $shebang" 1 lint shellcheck
done
repo dir/tool "#!/usr/bin/env bash
$bad_sh"
expect "shellcheck refuses an extension-less file in a directory" 1 lint shellcheck
repo tool "#!/usr/bin/env python3
$bad_sh"
expect "shellcheck skips a file with another shebang" 0 lint shellcheck
repo a.sh "$bad_sh"
rm a.sh && printf '%s\n' "$bad_sh" >untracked.sh
expect "shellcheck skips untracked files" 0 lint shellcheck
repo vendor/a.sh "$bad_sh" own.sh "$good_sh"
expect "shellcheck honours EXCLUDE" 0 env EXCLUDE="vendor/**" bash "$LINT" shellcheck
expect "shellcheck without EXCLUDE refuses the vendored script" 1 lint shellcheck
repo a.sh "$bad_sh"
expect "shellcheck passes SHELLCHECK_ARGS on" 0 env SHELLCHECK_ARGS="--exclude=SC2086 --exclude=SC2148" bash "$LINT" shellcheck
cd "$tmp" # outside any checkout; not a subshell, so a failure is counted
expect "shellcheck outside a checkout is refused" 1 lint shellcheck

# --- actionlint
repo .github/workflows/w.yml "$(workflow "uses: actions/checkout@$sha")"
expect "actionlint passes a clean workflow" 0 lint actionlint
repo .github/workflows/w.yml "$(workflow "" no-such-label)"
expect "actionlint refuses an unknown runner label" 1 lint actionlint
repo .github/workflows/w.yml "$(workflow "" no-such-label)" .github/actionlint.yaml "self-hosted-runner:
  labels: [no-such-label]"
expect "actionlint reads .github/actionlint.yaml" 0 lint actionlint
repo .github/workflows/w.yml "on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: $bad_sh"
expect "actionlint shellchecks run scripts" 1 lint actionlint
expect "actionlint shellchecks run scripts even with SHELLCHECK=false (a floor check)" 1 env SHELLCHECK=false bash "$LINT" actionlint
repo a.txt hi
expect "actionlint passes a repository without workflows" 0 lint actionlint

# --- pinned: workflows and actions
for uses in "uses: actions/checkout@$sha" "uses: ./local" "uses: ../other" "uses: docker://alpine@sha256:$digest" \
  "uses: actions/checkout@v4 # unpinned-ok: pinned by the caller" "uses: \"actions/checkout@$sha\""; do
  repo .github/workflows/w.yml "$(workflow "$uses")"
  expect "pinned allows $uses" 0 lint pinned
done
for uses in "uses: actions/checkout@v4" "uses: actions/checkout@main" "uses: actions/checkout@${sha:0:7}" \
  "uses: actions/checkout@${sha}0" "uses: docker://alpine:3" "uses: docker://alpine" \
  "uses: actions/checkout@v4 # a comment" "uses: 'actions/checkout@v4'" "uses: actions/checkout@ABCDEF${sha:6}"; do
  repo .github/workflows/w.yml "$(workflow "$uses")"
  expect "pinned refuses $uses" 1 lint pinned
done
repo .github/workflows/w.yaml "$(workflow "uses: actions/checkout@v4")"
expect "pinned refuses in a .yaml workflow" 1 lint pinned
for f in action.yml action.yaml sub/action.yml; do
  repo "$f" "runs:
  using: composite
  steps:
    - uses: actions/checkout@v4"
  expect "pinned refuses in $f" 1 lint pinned
done
repo vendor/action.yml "runs:
  steps:
    - uses: actions/checkout@v4"
expect "pinned honours EXCLUDE" 0 env EXCLUDE="vendor/**" bash "$LINT" pinned

# --- pinned: Dockerfiles
for from in "FROM python:3.13-slim@sha256:$digest" "FROM scratch" "FROM \$BASE" \
  "FROM python@sha256:$digest AS build
FROM build" "# unpinned-ok: the build command sets it
FROM ctx" "FROM --platform=linux/amd64 python@sha256:$digest"; do
  repo Dockerfile "$from"
  expect "pinned allows $(echo "$from" | tr '\n' ' ')" 0 lint pinned
done
for from in "FROM python:3.13-slim" "from python:3.13-slim" "FROM --platform=linux/amd64 python:3.13" \
  "FROM python@sha256:$digest AS build
FROM other" "# a comment
FROM ctx" "FROM python:3.13 # unpinned-ok: on the same line does not count"; do
  repo Dockerfile "$from"
  expect "pinned refuses $(echo "$from" | tr '\n' ' ')" 1 lint pinned
done
for f in Dockerfile.dev app/Dockerfile build.Dockerfile app/web.Dockerfile; do
  repo "$f" "FROM python:3.13"
  expect "pinned refuses in $f" 1 lint pinned
done

# --- pinned: pre-commit revs by commit SHA with a "# frozen: vX" comment
precommit() { # precommit <rev line>
  printf 'repos:\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    %s\n    hooks:\n      - id: check-json\n  - repo: local\n    hooks:\n      - id: x\n        name: x\n        entry: "true"\n        language: system\n' "$1"
}
for rev in "rev: $sha # frozen: v6.0.0" "rev: \"$sha\"  # frozen: v6.0.0" "rev: v6.0.0 # unpinned-ok: a fork we control"; do
  repo .pre-commit-config.yaml "$(precommit "$rev")"
  expect "pinned allows pre-commit $rev" 0 lint pinned
done
for rev in "rev: v6.0.0" "rev: $sha" "rev: $sha # v6.0.0" "rev: ${sha:0:7} # frozen: v6.0.0" "rev: main # frozen: v6.0.0" \
  "rev: $sha # frozen:"; do
  repo .pre-commit-config.yaml "$(precommit "$rev")"
  refuses "pinned refuses pre-commit $rev" lint pinned
done
repo sub/.pre-commit-config.yaml "$(precommit "rev: v6.0.0")"
refuses "pinned refuses a pre-commit config in a subdirectory" lint pinned
repo .pre-commit-config.yaml "repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    hooks:
      - id: check-json
    rev: v6.0.0"
refuses "pinned refuses a rev after the hooks list" lint pinned

# --- pinned: no download piped into a shell. The bad lines are built here, so this file holds none.
pipe='|'
for cmd in "curl -fsSL https://example.test/install.sh $pipe sh" "curl -sSL https://example.test/x $pipe bash" \
  "wget -qO- https://example.test/x $pipe sudo bash -s --" "curl https://example.test/x $pipe /bin/sh" \
  "sh -c \"\$(curl -fsSL https://example.test/x)\"" "curl -s https://example.test/x$pipe sh -s -- -y"; do
  repo install.sh "#!/bin/sh
$cmd"
  refuses "pinned refuses in a script: $cmd" lint pinned
  repo .github/workflows/w.yml "$(workflow "")
      - run: $cmd"
  refuses "pinned refuses in a workflow: $cmd" lint pinned
done
repo Dockerfile "FROM scratch
RUN curl -fsSL https://example.test/x $pipe sh"
refuses "pinned refuses a piped download in a Dockerfile" lint pinned
repo Makefile "install:
	curl -fsSL https://example.test/x $pipe bash"
refuses "pinned refuses a piped download in a Makefile" lint pinned
for ok in "curl -fsSL -o x.tar.gz https://example.test/x.tar.gz" "curl -s https://example.test/x $pipe jq .name" \
  "curl -s https://example.test/x $pipe shasum -a 256" "curl -fsSL https://example.test/x $pipe sh # unpinned-ok: vendor script, checksum above"; do
  repo install.sh "#!/bin/sh
$ok"
  expect "pinned allows $ok" 0 lint pinned
done
repo README.md "curl -fsSL https://example.test/x $pipe sh"
expect "pinned leaves documentation alone" 0 lint pinned

# --- workflow-safety
safe='on:
  pull_request:
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
ws() { bash "$LINT" workflow-safety; }
repo .github/workflows/w.yml "$safe"
expect "workflow-safety passes a safe workflow" 0 ws
repo .github/workflows/w.yml "$(printf '%s\n' "$safe" | sed '/^permissions:/,/contents: read/d')"
refuses "workflow-safety refuses a workflow with no top-level permissions" ws
repo .github/workflows/w.yml "$(printf '%s\n' "$safe" | sed '/^permissions:/,/contents: read/d' | sed 's/^  a:/  a:\n    permissions:\n      contents: read/')"
refuses "workflow-safety refuses job-only permissions" ws
repo .github/workflows/w.yaml "$(printf '%s\n' "$safe" | sed '/^permissions:/,/contents: read/d')"
refuses "workflow-safety reads .yaml workflows" ws
for perms in "permissions: write-all" "permissions:
  contents: write" "permissions:
  contents: read
  pull-requests: write"; do
  repo .github/workflows/w.yml "on: push
$perms
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
  refuses "workflow-safety refuses write access at the top: $(echo "$perms" | tr '\n' ' ')" ws
done
for perms in "permissions: {}" "permissions: read-all" "permissions:
  contents: read
  actions: read"; do
  repo .github/workflows/w.yml "on: push
$perms
jobs:
  a:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - run: echo hi"
  expect "workflow-safety allows read-only at the top and write in a job: $(echo "$perms" | tr '\n' ' ')" 0 ws
done
# shellcheck disable=SC2016 # the ${{ }} are meant literally: they are the findings
for run in '      - run: echo "${{ secrets.TOKEN }}"' '      - run: echo ${{secrets.TOKEN}}' \
  '      - run: echo "${{ github.event.pull_request.title }}"' '      - run: echo "${{ github.head_ref }}"' \
  '      - run: |
          echo start
          curl -H "token: ${{ secrets.TOKEN }}" https://example.test' \
  '      - name: x
        run: >
          echo ${{ format('"'"'{0}'"'"', github.event.issue.body) }}' \
  '      - run: echo "${{ secrets[format('"'"'{0}'"'"', inputs.name)] }}"'; do
  repo .github/workflows/w.yml "on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$run"
  refuses "workflow-safety refuses text in run: $(echo "$run" | tr '\n' ' ' | tr -s ' ')" ws
done
# shellcheck disable=SC2016
for step in '      - run: echo "$TOKEN"
        env:
          TOKEN: ${{ secrets.TOKEN }}
          TITLE: ${{ github.event.pull_request.title }}' \
  '      - run: echo "${{ github.sha }} ${{ inputs.x }} ${{ steps.a.outputs.b }}"' \
  '      - uses: actions/github-script@'"$sha"'
        with:
          github-token: ${{ secrets.TOKEN }}' \
  '      - run: |
          echo hi
        env:
          X: ${{ github.event.number }}' \
  '      - run: echo "${{ secrets.TOKEN }}" # workflow-safety-ok: the tool reads it only from argv'; do
  repo .github/workflows/w.yml "on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$step"
  expect "workflow-safety allows $(echo "$step" | tr '\n' ' ' | tr -s ' ')" 0 ws
done
# shellcheck disable=SC2016
repo .github/workflows/w.yml 'on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets.TOKEN }}" # workflow-safety-ok:'
refuses "workflow-safety refuses an exception with no reason" ws
# shellcheck disable=SC2016
repo action.yml 'runs:
  using: composite
  steps:
    - shell: bash
      run: echo "${{ github.event.pull_request.title }}"'
refuses "workflow-safety refuses event text in a composite action's run" ws
# pull_request_target and workflow_run never run the pull request's own code.
# shellcheck disable=SC2016
for trig in pull_request_target workflow_run; do
  for co in '      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ github.event.pull_request.head.sha }}' \
    '      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ github.event.workflow_run.head_sha }}' \
    '      - run: gh pr checkout "$PR"' \
    '      - uses: actions/checkout@'"$sha"'
        with:
          ref: refs/pull/${{ github.event.number }}/merge'; do
    repo .github/workflows/w.yml "on:
  $trig:
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$co"
    refuses "workflow-safety refuses $trig checking out the pull request: $(echo "$co" | tail -1 | tr -s ' ')" ws
  done
  repo .github/workflows/w.yml "on: [$trig]
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$sha"
  expect "workflow-safety allows $trig on the base branch's own code" 0 ws
  # shellcheck disable=SC2016
  repo .github/workflows/w.yml "on: [$trig]
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo \"\$COMMIT\"
        env:
          COMMIT: \${{ github.event.workflow_run.head_sha }}
          PR: \${{ github.event.pull_request.head.ref }}"
  expect "workflow-safety allows $trig naming the pull request's commit without checking it out" 0 ws
done
# shellcheck disable=SC2016
repo .github/workflows/w.yml 'on: pull_request
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ github.event.pull_request.head.sha }}'
expect "workflow-safety allows a plain pull_request checking out its head" 0 ws
# Public repositories: no self-hosted runner for pull requests.
for ro in "runs-on: self-hosted" "runs-on: [self-hosted, linux]" "runs-on: \${{ vars.RUNNER }}" "runs-on:
      - self-hosted
      - arm64" "runs-on:
      labels: [self-hosted]" "runs-on: \${{ fromJSON(vars.RUNNERS) }}"; do
  for trig in "pull_request" "[push, pull_request]" "
  pull_request_target:" "
  issue_comment:"; do
    repo .github/workflows/w.yml "on: $trig
permissions: {}
jobs:
  a:
    $ro
    steps:
      - run: echo hi"
    refuses "workflow-safety refuses on a public repo: $(echo "$trig $ro" | tr '\n' ' ' | tr -s ' ')" env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
  done
  expect "workflow-safety allows on a private repo: $(echo "$ro" | tr '\n' ' ' | tr -s ' ')" 0 env KILOTRONIC_VISIBILITY=PRIVATE bash "$LINT" workflow-safety
  repo .github/workflows/w.yml "on:
  push:
    branches: [main]
  schedule:
    - cron: '0 0 * * *'
permissions: {}
jobs:
  a:
    $ro
    steps:
      - run: echo hi"
  expect "workflow-safety allows on a public repo without pull request triggers: $(echo "$ro" | tr '\n' ' ' | tr -s ' ')" 0 env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
done
repo .github/workflows/w.yml "on: pull_request
permissions: {}
jobs:
  a:
    runs-on: ubuntu-24.04
    steps:
      - run: echo self-hosted vars.X"
expect "workflow-safety allows GitHub's runners on a public repo" 0 env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
# Visibility, when not given: asked of gh once and cached in the clone; unknown is not public.
repo .github/workflows/w.yml "on: pull_request
permissions: {}
jobs:
  a:
    runs-on: self-hosted
    steps:
      - run: echo hi"
mkdir -p "$tmp/gh-public" "$tmp/gh-down"
printf '#!/bin/sh\necho "$*" >>"%s/gh-calls"\necho PUBLIC\n' "$tmp" >"$tmp/gh-public/gh"
printf '#!/bin/sh\nexit 1\n' >"$tmp/gh-down/gh"
chmod +x "$tmp/gh-public/gh" "$tmp/gh-down/gh"
refuses "workflow-safety asks gh when the visibility is not given" env PATH="$tmp/gh-public:$PATH" bash "$LINT" workflow-safety
refuses "workflow-safety reads the cached visibility" env PATH="$tmp/gh-down:$PATH" bash "$LINT" workflow-safety
if [ "$(wc -l <"$tmp/gh-calls")" -eq 1 ]; then pass "gh was asked once"; else fail "gh was asked $(wc -l <"$tmp/gh-calls") times"; fi
rm -f "$(git rev-parse --git-common-dir)/kilotronic-visibility"
expect "workflow-safety treats an unknown visibility as not public" 0 env PATH="$tmp/gh-down:$PATH" bash "$LINT" workflow-safety
# workflow_dispatch inputs that skip or force the checks.
for name in skip-tests skip_tests force no-verify bypass-checks force_deploy; do
  repo .github/workflows/w.yml "on:
  workflow_dispatch:
    inputs:
      env:
        type: string
      $name:
        type: boolean
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
  refuses "workflow-safety refuses a dispatch input named $name" ws
done
repo .github/workflows/w.yml "on:
  workflow_dispatch:
    inputs:
      environment:
        description: skip nothing, force nothing
        type: string
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
expect "workflow-safety allows other dispatch inputs" 0 ws
repo a.txt hi
expect "workflow-safety passes a repository without workflows" 0 ws

# --- non-root: a Dockerfile's final stage runs as a user other than root
for df in "FROM scratch
USER app" "FROM python AS build
USER root
FROM scratch
USER 1000:1000" "FROM scratch
USER \${APP_USER}" "# non-root-ok: a build image; nothing runs from it
FROM scratch"; do
  repo Dockerfile "$df"
  expect "non-root allows $(echo "$df" | tr '\n' ' ')" 0 lint non-root
done
for df in "FROM scratch" "FROM scratch
USER root" "FROM scratch
USER 0" "FROM scratch
USER 0:0" "FROM python AS build
USER app
FROM scratch" "FROM scratch
USER app
USER root" "# non-root-ok:
FROM scratch"; do
  repo Dockerfile "$df"
  refuses "non-root refuses $(echo "$df" | tr '\n' ' ')" lint non-root
done
repo app/web.Dockerfile "FROM scratch"
refuses "non-root refuses in app/web.Dockerfile" lint non-root
repo a.txt hi
expect "non-root passes a repository without Dockerfiles" 0 lint non-root

# --- skip: a repository skips an overridable check (non-root) by the Action's skip input or the hook's --skip;
# a floor check refuses to be skipped, says so, and runs anyway
repo Dockerfile "FROM scratch"
expect "non-root is skipped by SKIP_CHECKS" 0 env SKIP_CHECKS="non-root" bash "$LINT" non-root
if grep -q 'skipped' "$tmp/log"; then pass "the skip is printed"; else fail "the skip is printed"; fi
expect "non-root is skipped from a list" 0 env SKIP_CHECKS="other-thing, non-root" bash "$LINT" non-root
expect "the non-root hook honours --skip" 0 lint hook non-root --skip=non-root
refuses "non-root still runs when another check is skipped" env SKIP_CHECKS="x" bash "$LINT" non-root
repo .github/workflows/w.yml "$(workflow "uses: actions/checkout@v4")" Dockerfile "FROM python:3.13"
for id in pinned lint-all format-all; do
  refuses "skipping $id is refused: pinned still runs" env SKIP_CHECKS="$id" bash "$LINT" pinned
  if grep -q "floor check" "$tmp/log"; then pass "skipping $id says it is a floor check"; else fail "skipping $id says it is a floor check"; fi
done
refuses "skipping workflow-safety is refused: it still runs" env SKIP_CHECKS="workflow-safety" bash "$LINT" workflow-safety
refuses "the pinned hook refuses --skip=pinned and runs" lint hook pinned --skip=pinned
repo a.sh "$bad_sh"
SKIP_CHECKS=lint-all bash "$LINT" shellcheck >"$tmp/log" 2>&1 || true
SKIP_CHECKS=lint-all bash "$LINT" pinned >>"$tmp/log" 2>&1 || true
if [ "$(grep -c 'floor check' "$tmp/log")" -le 2 ]; then pass "a floor id warns once per step"; else fail "a floor id warns once per step"; fi
expect "a wildcard in skip is not expanded" 1 env SKIP_CHECKS='*' bash "$LINT" install
if grep -q "unknown check id in skip: \*" "$tmp/log"; then pass "the wildcard is named as given"; else fail "the wildcard is named as given"; fi
repo a.sh "$bad_sh"
for id in shellcheck lint-all; do
  refuses "skipping $id is refused: shellcheck still runs" env SKIP_CHECKS="$id" bash "$LINT" shellcheck
done
repo a.txt hi
expect "an unknown id in SKIP_CHECKS fails the install step" 1 env SKIP_CHECKS="non-rooot" bash "$LINT" install
expect "a known id passes the install step" 0 env SKIP_CHECKS="non-root" bash "$LINT" install
expect "a hook refuses an unknown --skip id" 1 lint hook non-root --skip=nope
# The skippable ids come from skippable.txt (also read by the owner's settings sweep), not a copy in lint.sh.
ROOT="$(dirname "$(dirname "$LINT")")"
if [ "$(grep -v '^#' "$ROOT/skippable.txt" | awk 'NF { print $1 }')" = "non-root" ]; then
  pass "skippable.txt lists non-root"
else fail "skippable.txt lists non-root"; fi
mkdir -p "$tmp/copy/src" && cp "$LINT" "$tmp/copy/src/" && printf '# nothing\n' >"$tmp/copy/skippable.txt"
repo Dockerfile "FROM scratch"
refuses "with non-root not in skippable.txt, skipping it is refused" env SKIP_CHECKS="non-root" bash "$tmp/copy/src/lint.sh" non-root
rm -f "$tmp/copy/skippable.txt"
refuses "with no skippable.txt, nothing can be skipped" env SKIP_CHECKS="non-root" bash "$tmp/copy/src/lint.sh" non-root

# --- review findings: evasions that must be refused, and false alarms that must pass
# shellcheck disable=SC2016 # the ${{ }} are meant literally: they are the findings
for run in '      - run: echo ${{ GITHUB.EVENT.issue.title }}' '      - run: echo ${{ Secrets.TOKEN }}' \
  '      - run: |
          # ${{ github.event.comment.body }}
          echo hi' \
  '      - {name: x, run: "echo ${{ github.event.issue.title }}"}' \
  '      - uses: actions/github-script@'"$sha"'
        with:
          script: console.log("${{ github.event.issue.title }}")'; do
  repo .github/workflows/w.yml "on: push
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$run"
  refuses "workflow-safety refuses $(echo "$run" | tr '\n' ' ' | tr -s ' ')" ws
done
repo .github/workflows/w.yml "on:
  workflow_dispatch:
    inputs: {skip_tests: {type: boolean}}
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
refuses "workflow-safety refuses a skip input in a one-line mapping" ws
repo .github/workflows/w.yml "on:
  workflow_dispatch:
    inputs:
      enforce_strict:
        type: boolean
      forced-colors:
        type: boolean
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi"
# forced-colors: a word that only contains "force"; enforce_strict likewise
expect "workflow-safety allows inputs that only contain skip/force inside a word" 0 ws
# shellcheck disable=SC2016
for co in '      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}' \
  '      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ env.PR_SHA }}' \
  '      - run: git fetch origin pull/1/head && git checkout FETCH_HEAD' \
  '      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ GITHUB.EVENT.PULL_REQUEST.HEAD.SHA }}'; do
  repo .github/workflows/w.yml "on: pull_request_target
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$co"
  refuses "workflow-safety refuses pull_request_target with $(echo "$co" | tail -1 | tr -s ' ')" ws
done
# shellcheck disable=SC2016
repo .github/workflows/w.yml 'on: pull_request_target
permissions: {}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$sha"'
        with:
          ref: ${{ github.event.pull_request.base.sha }}'
expect "workflow-safety allows pull_request_target checking out its base" 0 ws
# shellcheck disable=SC2016
for wf in 'on: pull_request
permissions: {}
jobs:
  a:
    strategy:
      matrix:
        os: [ubuntu-latest, self-hosted]
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo hi' 'on: pull_request
permissions: {}
jobs:
  a:
    runs-on: {group: my-runners}
    steps:
      - run: echo hi' 'on: pull_request
permissions: {}
jobs:
  a:
    runs-on:
      group: my-runners
    steps:
      - run: echo hi'; do
  repo .github/workflows/w.yml "$wf"
  refuses "workflow-safety refuses on a public repo: $(echo "$wf" | grep -E 'self-hosted|group' | head -1 | tr -s ' ')" env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
done
repo .github/workflows/w.yml 'on: pull_request
permissions: {}
jobs:
  a:
    uses: ./.github/workflows/d.yml' .github/workflows/d.yml 'on: workflow_call
permissions: {}
jobs:
  b:
    runs-on: [self-hosted]
    steps:
      - run: echo hi'
refuses "workflow-safety refuses a public repo's reusable workflow on a self-hosted runner" env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
repo .github/workflows/w.yml "on: pull_request
permissions: {}
jobs:
  a:
    runs-on: self-hosted
    steps:
      - run: echo hi"
expect "workflow-safety warns when an Action run can't tell the visibility" 0 env GITHUB_ACTIONS=true PATH="$tmp/gh-down:$PATH" bash "$LINT" workflow-safety
if grep -q '::warning::' "$tmp/log"; then pass "the unknown visibility is a warning in Actions"; else fail "the unknown visibility is a warning in Actions"; fi

# piped downloads in other shapes
pipe='|'
for cmd in "bash <(curl -fsSL https://example.test/x)" "source <(curl -fsSL https://example.test/x)" \
  ". <(wget -qO- https://example.test/x)" "curl -fsSL https://example.test/x $pipe tee x.sh $pipe sh"; do
  repo install.sh "#!/bin/sh
$cmd"
  refuses "pinned refuses in a script: $cmd" lint pinned
done
repo Dockerfile "FROM scratch
RUN curl -fsSL https://example.test/x \\
  $pipe sh"
refuses "pinned refuses a piped download split over two lines" lint pinned
repo .pre-commit-config.yaml "repos:
  - {repo: https://github.com/pre-commit/pre-commit-hooks, rev: v6.0.0, hooks: [{id: check-json}]}"
refuses "pinned refuses a tag rev in a one-line mapping" lint pinned

# non-root: what a stage inherits
for df in "FROM python@sha256:$digest AS build
USER app
FROM build" "FROM gcr.io/distroless/static:nonroot" "FROM gcr.io/distroless/static@sha256:$digest AS x
USER nonroot:nonroot"; do
  repo Dockerfile "$df"
  expect "non-root allows $(echo "$df" | tr '\n' ' ')" 0 lint non-root
done
repo Dockerfile "FROM python AS build
USER app
FROM build
USER root"
refuses "non-root refuses a stage that switches back to root" lint non-root

# second review: false alarms that must pass
# shellcheck disable=SC2016
repo .github/workflows/w.yml 'on: pull_request_target
permissions: {}
jobs:
  a:
    name: Not on self-hosted runners
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@'"$sha"'
        with:
          repository: ${{ github.repository }}
          ref: ${{ github.event.repository.default_branch }}'
expect "workflow-safety allows the base repository and a name that mentions self-hosted" 0 env KILOTRONIC_VISIBILITY=PUBLIC bash "$LINT" workflow-safety
for ok in "command -v curl >/dev/null || sh ./install-curl.sh" "curl -s https://example.test/x | jq . || sh ./fallback.sh"; do
  repo install.sh "#!/bin/sh
$ok"
  expect "pinned allows $ok" 0 lint pinned
done
repo Dockerfile "FROM alpine@sha256:$digest AS Build
USER app
FROM build"
expect "non-root matches stage names in any case" 0 lint non-root
# --- verdict
expect "verdict passes when every check passed" 0 env SHELLCHECK_OUTCOME=success ACTIONLINT_OUTCOME=success PINNED_OUTCOME=success bash "$LINT" verdict
expect "verdict passes when every check was off" 0 lint verdict
for check in SHELLCHECK ACTIONLINT PINNED; do
  expect "verdict fails when $check found something" 1 env SHELLCHECK_OUTCOME=success ACTIONLINT_OUTCOME=success \
    PINNED_OUTCOME=success "${check}_OUTCOME=failure" bash "$LINT" verdict
done

# --- hooks
repo vendor/a.sh "$bad_sh" .github/workflows/w.yml "$(workflow "uses: actions/checkout@v4")"
expect "shellcheck hook refuses" 1 lint hook shellcheck
expect "shellcheck hook honours --exclude" 0 lint hook shellcheck --exclude='vendor/**'
expect "pinned hook refuses" 1 lint hook pinned
expect "pinned hook honours --exclude" 0 lint hook pinned --exclude='.github/**'
repo a.txt hi
expect "a hook passes a clean repository" 0 lint hook pinned
expect "a hook refuses an unknown argument" 1 lint hook pinned --nope
expect "an unknown hook is refused" 1 lint hook nope

# --- downloads: a tool whose checksum does not match is never installed or run. The fake downloads are
# well-formed archives of a "tool" that always passes, so only the checksum can stop them.
mkdir -p "$tmp/fakebin" "$tmp/fake/shellcheck-v0" && cd "$tmp/fake"
printf '#!/bin/sh\nexit 0\n' >shellcheck-v0/shellcheck && cp shellcheck-v0/shellcheck actionlint && chmod +x shellcheck-v0/shellcheck actionlint
sc_dir=$(sed -n 's/^SHELLCHECK_VERSION=//p' "$LINT")
mv shellcheck-v0 "shellcheck-v$sc_dir" && tar -cJf sc.tar.xz "shellcheck-v$sc_dir" && tar -czf al.tar.gz actionlint
real_curl=$(command -v curl)
# FAKE names the tool whose download is faked; the other comes from the real curl.
cat >"$tmp/fakebin/curl" <<CURL
#!/bin/sh
url=\$(eval echo "\\\${\$#}")
case "\$url" in
  *shellcheck*) [ "\$FAKE" = shellcheck ] || exec "$real_curl" "\$@" ;;
  *) [ "\$FAKE" = actionlint ] || exec "$real_curl" "\$@" ;;
esac
while [ "\$1" != -o ]; do shift; done
case "\$url" in *shellcheck*) cp "$tmp/fake/sc.tar.xz" "\$2" ;; *) cp "$tmp/fake/al.tar.gz" "\$2" ;; esac
CURL
chmod +x "$tmp/fakebin/curl"
for tool in shellcheck actionlint; do
  expect "a $tool download with the wrong checksum is refused" 1 \
    env FAKE="$tool" PATH="$tmp/fakebin:$PATH" XDG_CACHE_HOME="$tmp/cache-$tool" bash "$LINT" install
  if [ -n "$(find "$tmp/cache-$tool" -maxdepth 2 -type f \( -name shellcheck -o -name actionlint \) 2>/dev/null)" ]; then
    fail "the bad $tool download left a tool installed"
  else
    pass "the bad $tool download left no tool installed"
  fi
done

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
