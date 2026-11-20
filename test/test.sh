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
  SHELLCHECK_OUTCOME ACTIONLINT_OUTCOME PINNED_OUTCOME
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
expect "actionlint skips run scripts when shellcheck is off" 0 env SHELLCHECK=false bash "$LINT" actionlint
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
