#!/usr/bin/env bash
# Steps of the Lint action (action.yml). Inputs arrive as env vars.
#   (step) install: install the pinned shellcheck and actionlint (checksums checked) into $LINT_BIN
#   (step) shellcheck: check every tracked shell script (*.sh, *.bash, or a sh/bash shebang), minus EXCLUDE
#   (step) actionlint: check the workflows in .github/workflows (their run: scripts through shellcheck too)
#   (step) pinned: every action used is pinned to a commit SHA, every Docker base image to a digest
#   (step) verdict: fail if any check failed, so both always run and every finding shows in one run
set -euo pipefail

SHELLCHECK_VERSION=0.11.0
ACTIONLINT_VERSION=1.7.12

out() { echo "$1=$2" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }

check_sum() { # sum file
  if command -v sha256sum >/dev/null; then
    echo "$1  $2" | sha256sum -c - >/dev/null
  else
    echo "$1  $2" | shasum -a 256 -c - >/dev/null
  fi
}

cmd_install() {
  local sc_os sc_arch sc_sum al_os al_arch al_sum
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
      sc_os=linux sc_arch=x86_64 sc_sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
      al_os=linux al_arch=amd64 al_sum=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    Linux-aarch64 | Linux-arm64)
      sc_os=linux sc_arch=aarch64 sc_sum=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
      al_os=linux al_arch=arm64 al_sum=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
    Darwin-arm64)
      sc_os=darwin sc_arch=aarch64 sc_sum=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
      al_os=darwin al_arch=arm64 al_sum=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
    Darwin-x86_64)
      sc_os=darwin sc_arch=x86_64 sc_sum=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
      al_os=darwin al_arch=amd64 al_sum=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
    *) echo "::error::lint: no shellcheck/actionlint build for $(uname -s) $(uname -m)"; exit 1 ;;
  esac
  local dir="${RUNNER_TEMP:-/tmp}/kilotronic-lint-sc$SHELLCHECK_VERSION-al$ACTIONLINT_VERSION"
  if [ ! -x "$dir/shellcheck" ] || [ ! -x "$dir/actionlint" ]; then
    mkdir -p "$dir"
    local txz="$dir/shellcheck.tar.xz" tgz="$dir/actionlint.tar.gz"
    curl -sSfL -o "$txz" \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${sc_os}.${sc_arch}.tar.xz"
    check_sum "$sc_sum" "$txz"
    tar -xJf "$txz" -C "$dir" --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
    curl -sSfL -o "$tgz" \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${al_os}_${al_arch}.tar.gz"
    check_sum "$al_sum" "$tgz"
    tar -xzf "$tgz" -C "$dir" actionlint
    rm "$txz" "$tgz"
  fi
  "$dir/shellcheck" --version | sed -n 2p
  echo "actionlint $("$dir/actionlint" --version | head -1)"
  out bin "$dir"
}

EXCLUDE_GLOBS=()
for pattern in ${EXCLUDE:-}; do EXCLUDE_GLOBS+=(":(exclude,glob)$pattern"); done

# Tracked shell scripts: *.sh, *.bash, or an extension-less file whose first line is a sh/bash shebang.
shell_files() {
  git ls-files -z -- . ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"} | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sh | *.bash) printf '%s\0' "$f" ;;
      */*.* | *.*) ;; # another extension: not a shell script
      *) head -n1 "$f" 2>/dev/null | grep -qE '^#!.*[/ ](ba|da|k)?sh( |$)' && printf '%s\0' "$f" ;;
    esac
  done
}

cmd_shellcheck() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "::error::lint needs a checkout (run actions/checkout first)"
    exit 1
  fi
  local files=() # (no mapfile: macOS runners ship bash 3.2)
  while IFS= read -r -d '' f; do files+=("$f"); done < <(shell_files)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "shellcheck: no shell scripts"
    return 0
  fi
  echo "shellcheck: ${#files[@]} files"
  # gcc format: one line per finding, file:line:column, easy to read in the log.
  local extra=()
  read -r -a extra <<<"${SHELLCHECK_ARGS:-}" # split on spaces; no quoting
  "${LINT_BIN:?}/shellcheck" -f gcc ${extra[@]+"${extra[@]}"} "${files[@]}"
}

cmd_actionlint() {
  if [ ! -d .github/workflows ]; then
    echo "actionlint: no .github/workflows"
    return 0
  fi
  # .github/actionlint.yaml (e.g. self-hosted runner labels) is read by actionlint itself.
  local sc="${LINT_BIN:?}/shellcheck"
  [ "${SHELLCHECK:-true}" = true ] || sc=""
  local extra=()
  read -r -a extra <<<"${ACTIONLINT_ARGS:-}" # split on spaces; no quoting
  "$LINT_BIN/actionlint" -shellcheck="$sc" -pyflakes= ${extra[@]+"${extra[@]}"}
}

# Every action a workflow uses is pinned to a full commit SHA (a tag or branch can be moved to other code),
# and every Docker base image to a digest. Local actions (./...) and earlier build stages are fine. A line that
# can't carry the pin itself (e.g. a build context whose digest the build command supplies) says why:
# "# unpinned-ok: <reason>".
cmd_pinned() {
  local bad=0 f line n
  while IFS= read -r -d '' f; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"\']?([^\"\'[:space:]#]+) ]] || continue
      local ref="${BASH_REMATCH[2]}"
      case "$ref" in
        ./* | ../*) continue ;;                          # an action in this repo
        docker://*@sha256:*) continue ;;                 # an image by digest
      esac
      [[ "$ref" =~ @[0-9a-f]{40}$ ]] && continue
      [[ "$line" == *"# unpinned-ok:"* ]] && continue # pinned elsewhere, with the reason on the line
      echo "$f:$n: not pinned to a commit SHA: $ref"
      bad=1
    done <"$f"
  done < <(git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' 'action.yml' 'action.yaml' \
    '**/action.yml' '**/action.yaml' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"})
  while IFS= read -r -d '' f; do
    local stages=" " n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      shopt -s nocasematch
      if [[ "$line" =~ ^[[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([^[:space:]]+)([[:space:]]+AS[[:space:]]+([^[:space:]]+))? ]]; then
        local image="${BASH_REMATCH[2]}" alias="${BASH_REMATCH[4]}"
        shopt -u nocasematch
        if [[ "$image" != *@sha256:* && "$image" != scratch && "$stages" != *" $image "* && "$image" != *'$'* \
          && "$line" != *"# unpinned-ok:"* ]]; then
          echo "$f:$n: base image not pinned to a digest (image@sha256:...): $image"
          bad=1
        fi
        [ -n "$alias" ] && stages="$stages$alias "
      fi
      shopt -u nocasematch
    done <"$f"
  done < <(git ls-files -z -- '**Dockerfile*' '*.Dockerfile' '**/*.Dockerfile' 'Dockerfile*' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"})
  [ "$bad" = 0 ] && echo "pinned: every action is pinned to a commit SHA and every base image to a digest"
  return "$bad"
}

cmd_verdict() {
  local failed=()
  [ "${SHELLCHECK_OUTCOME:-}" = failure ] && failed+=(shellcheck)
  [ "${ACTIONLINT_OUTCOME:-}" = failure ] && failed+=(actionlint)
  [ "${PINNED_OUTCOME:-}" = failure ] && failed+=(pinned)
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "::error::lint: ${failed[*]} found something (see the steps above)"
    exit 1
  fi
  echo "lint: nothing found (shellcheck: ${SHELLCHECK_OUTCOME:-off}, actionlint: ${ACTIONLINT_OUTCOME:-off}, pinned: ${PINNED_OUTCOME:-off})"
}

"cmd_${1:?usage: lint.sh install|shellcheck|actionlint|pinned|verdict}"
