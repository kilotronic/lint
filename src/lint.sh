#!/usr/bin/env bash
# Steps of the Lint action (action.yml). Inputs arrive as env vars.
#   (step) install: install the pinned shellcheck and actionlint (checksums checked) into $LINT_BIN
#   (step) shellcheck: check every tracked shell script (*.sh, *.bash, or a sh/bash shebang), minus EXCLUDE
#   (step) actionlint: check the workflows in .github/workflows (their run: scripts through shellcheck too)
#   (step) pinned: every action used is pinned to a commit SHA, every Docker base image to a digest, every
#          pre-commit rev to a commit SHA with a "# frozen: <tag>" comment, and no download is piped into a shell
#   (step) workflow-safety: read-only top-level permissions, no pull request code beside secrets, no secret or
#          event text in run: scripts, GitHub's runners for a public repo's pull requests, no skip/force inputs
#   (step) non-root: every Dockerfile's final stage runs as a user other than root
#   (step) verdict: fail if any check failed, so all always run and every finding shows in one run
#   hook <check>: for .pre-commit-hooks.yaml: install into a cache directory, then run that check
# The Action's skip input (or a hook's --skip=<id>) may skip the ids in skippable.txt; the floor checks refuse
# to be skipped.
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

# Install the pinned shellcheck and actionlint once (checksums checked) and set LINT_BIN to their directory.
install_tools() {
  local sc_os sc_arch sc_sum al_os al_arch al_sum
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
      sc_os=linux sc_arch=x86_64 sc_sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
      al_os=linux al_arch=amd64 al_sum=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
      ;;
    Linux-aarch64 | Linux-arm64)
      sc_os=linux sc_arch=aarch64 sc_sum=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
      al_os=linux al_arch=arm64 al_sum=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
      ;;
    Darwin-arm64)
      sc_os=darwin sc_arch=aarch64 sc_sum=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
      al_os=darwin al_arch=arm64 al_sum=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
      ;;
    Darwin-x86_64)
      sc_os=darwin sc_arch=x86_64 sc_sum=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
      al_os=darwin al_arch=amd64 al_sum=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
      ;;
    *)
      echo "::error::lint: no shellcheck/actionlint build for $(uname -s) $(uname -m)"
      exit 1
      ;;
  esac
  local dir="kilotronic-lint-sc$SHELLCHECK_VERSION-al$ACTIONLINT_VERSION"
  if [ -n "${RUNNER_TEMP:-}" ]; then
    dir="$RUNNER_TEMP/$dir"
  else
    dir="${XDG_CACHE_HOME:-$HOME/.cache}/$dir"
  fi
  if [ ! -x "$dir/shellcheck" ] || [ ! -x "$dir/actionlint" ]; then
    mkdir -p "$dir"
    local tmp
    tmp=$(mktemp -d "$dir/download.XXXXXX")
    local txz="$tmp/shellcheck.tar.xz" tgz="$tmp/actionlint.tar.gz"
    curl -sSfL -o "$txz" \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.${sc_os}.${sc_arch}.tar.xz"
    check_sum "$sc_sum" "$txz"
    tar -xJf "$txz" -C "$tmp" --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
    curl -sSfL -o "$tgz" \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${al_os}_${al_arch}.tar.gz"
    check_sum "$al_sum" "$tgz"
    tar -xzf "$tgz" -C "$tmp" actionlint
    # Moved into place whole, so two hooks running at once never see half a file.
    mv -f "$tmp/shellcheck" "$dir/shellcheck"
    mv -f "$tmp/actionlint" "$dir/actionlint"
    rm -rf "$tmp"
  fi
  LINT_BIN="$dir"
}

cmd_install() {
  check_skip_ids
  install_tools
  "$LINT_BIN/shellcheck" --version | sed -n 2p
  echo "actionlint $("$LINT_BIN/actionlint" --version | head -1)"
  out bin "$LINT_BIN"
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
  skipped shellcheck lint-all || true
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
  skipped actionlint lint-all || true
  if [ ! -d .github/workflows ]; then
    echo "actionlint: no .github/workflows"
    return 0
  fi
  # .github/actionlint.yaml (e.g. self-hosted runner labels) is read by actionlint itself.
  local sc="${LINT_BIN:?}/shellcheck" # always: shellcheck on run: scripts is part of the floor
  local extra=()
  read -r -a extra <<<"${ACTIONLINT_ARGS:-}" # split on spaces; no quoting
  "$LINT_BIN/actionlint" -shellcheck="$sc" -pyflakes= ${extra[@]+"${extra[@]}"}
}

# Skipping a check: the Action's skip input (SKIP_CHECKS) or a hook's --skip=<id>, a list of check ids. Only
# the ids in skippable.txt may be skipped (the repository's reason lives in the owner's settings, which the
# nightly sweep matches against each skip, reading the same file). The floor checks refuse: skipping one says
# so and the check runs anyway.
FLOOR="shellcheck actionlint pinned workflow-safety lint-all format-all"
SKIPPABLE_FILE="$(dirname "${BASH_SOURCE[0]}")/../skippable.txt"
# load_skippable: SKIPPABLE from skippable.txt (an id per line, optionally `opt-in` after it; # comments), and
# SKIPPABLE_ERRORS for what can't be used: a missing file (nothing is skippable), a floor id, or a bad line.
load_skippable() {
  local line id word extra
  SKIPPABLE="" SKIPPABLE_ERRORS=""
  if [ ! -r "$SKIPPABLE_FILE" ]; then
    SKIPPABLE_ERRORS="lint: can't read $SKIPPABLE_FILE, so nothing can be skipped"
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    read -r id word extra <<<"$line" || true
    case "$id" in "" | "#"*) continue ;; esac
    if ! [[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] || { [ -n "$word" ] && [ "$word" != opt-in ]; } || [ -n "$extra" ]; then
      SKIPPABLE_ERRORS+="${SKIPPABLE_ERRORS:+$'\n'}lint: skippable.txt: bad line (want <id> [opt-in]): $line"
    elif [[ " $FLOOR " == *" $id "* ]]; then
      SKIPPABLE_ERRORS+="${SKIPPABLE_ERRORS:+$'\n'}lint: skippable.txt lists $id, a floor check; it can't be skipped"
    else
      SKIPPABLE+="${SKIPPABLE:+ }$id"
    fi
  done <"$SKIPPABLE_FILE"
}
load_skippable
# The ids, one per line, never glob-expanded.
skip_ids() { printf '%s\n' "${SKIP_CHECKS:-}" | awk '{ gsub(/[,[:space:]]+/, "\n"); print }' | grep -v '^$' || true; }
# check_skip_ids: every id is a known check (a typo must not quietly leave a check on, or look like a skip).
check_skip_ids() {
  local id bad=0 err
  if [ -n "$(skip_ids)" ] && [ -n "$SKIPPABLE_ERRORS" ]; then
    while IFS= read -r err; do echo "::error::$err"; done <<<"$SKIPPABLE_ERRORS"
    bad=1
  fi
  while IFS= read -r id; do
    case " $SKIPPABLE $FLOOR " in
      *" $id "*) ;;
      *)
        echo "::error::lint: unknown check id in skip: $id (known, in lower case: $SKIPPABLE $FLOOR)"
        bad=1
        ;;
    esac
  done < <(skip_ids)
  return "$bad"
}
# skipped <id> [<floor id>...]: true when the check is skipped. A floor check named in skip says it can't be
# skipped (once per check) and runs.
skipped() {
  local id want warned=false err
  if [ -n "$(skip_ids)" ] && [ -n "$SKIPPABLE_ERRORS" ]; then
    while IFS= read -r err; do echo "::warning::$err"; done <<<"$SKIPPABLE_ERRORS"
  fi
  while IFS= read -r id; do
    for want in "$@"; do
      [ "$id" = "$want" ] || continue
      case " $SKIPPABLE " in
        *" $id "*)
          echo "$1: skipped (skip: $id)"
          return 0
          ;;
        *)
          $warned || echo "::warning::lint: $id is a floor check; it can't be skipped, so $1 runs"
          warned=true
          ;;
      esac
    done
  done < <(skip_ids)
  return 1
}

# PUBLIC, PRIVATE, INTERNAL or UNKNOWN. KILOTRONIC_VISIBILITY when given (the Action passes the event's), else asked
# of gh once and kept in the clone's git directory for a day; UNKNOWN (offline, no gh) counts as not public.
visibility() {
  if [ -n "${KILOTRONIC_VISIBILITY:-}" ]; then
    echo "$KILOTRONIC_VISIBILITY" | tr '[:lower:]' '[:upper:]'
    return
  fi
  local dir cache v
  dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo UNKNOWN
    return
  }
  cache="$dir/kilotronic-visibility"
  if [ -s "$cache" ] && [ -n "$(find "$cache" -mtime -1 2>/dev/null)" ]; then
    cat "$cache"
    return
  fi
  if v=$(gh repo view --json visibility -q .visibility 2>/dev/null) && [[ "$v" =~ ^(PUBLIC|PRIVATE|INTERNAL)$ ]]; then
    echo "$v" >"$cache"
    echo "$v"
  else
    echo UNKNOWN
  fi
}

workflow_files() {
  git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' 'action.yml' 'action.yaml' \
    '**/action.yml' '**/action.yaml' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"}
}
dockerfiles() {
  git ls-files -z -- '**Dockerfile*' '*.Dockerfile' '**/*.Dockerfile' 'Dockerfile*' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"}
}

# Every action a workflow uses is pinned to a full commit SHA (a tag or branch can be moved to other code),
# and every Docker base image to a digest. Local actions (./...) and earlier build stages are fine. A line that
# can't carry the pin itself says why with "# unpinned-ok: <reason>": at the end of a workflow's uses: line, or
# on the line just above a Dockerfile's FROM (a Dockerfile allows comments only on their own line).
cmd_pinned() {
  local bad=0 f line n
  skipped pinned lint-all format-all || true
  while IFS= read -r -d '' f; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"\']?([^\"\'[:space:]#]+) ]] || continue
      local ref="${BASH_REMATCH[2]}"
      case "$ref" in
        ./* | ../*) continue ;;          # an action in this repo
        docker://*@sha256:*) continue ;; # an image by digest
      esac
      [[ "$ref" =~ @[0-9a-f]{40}$ ]] && continue
      [[ "$line" == *"# unpinned-ok:"* ]] && continue # pinned elsewhere, with the reason on the line
      echo "$f:$n: not pinned to a commit SHA: $ref"
      bad=1
    done <"$f"
  done < <(workflow_files)
  while IFS= read -r -d '' f; do
    local stages=" " n=0 prev=""
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      shopt -s nocasematch
      if [[ "$line" =~ ^[[:space:]]*FROM[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([^[:space:]]+)([[:space:]]+AS[[:space:]]+([^[:space:]]+))? ]]; then
        local image="${BASH_REMATCH[2]}" alias="${BASH_REMATCH[4]}"
        shopt -u nocasematch
        if [[ "$image" != *@sha256:* && "$image" != scratch && "$stages" != *" $image "* && "$image" != *'$'* &&
          "$prev" != *"# unpinned-ok:"* ]]; then
          echo "$f:$n: base image not pinned to a digest (image@sha256:...): $image"
          bad=1
        fi
        [ -n "$alias" ] && stages="$stages$alias "
      fi
      shopt -u nocasematch
      prev="$line"
    done <"$f"
  done < <(dockerfiles)
  # pre-commit: a tag can be moved, so every rev is a commit SHA, with its tag kept as "# frozen: <tag>"
  # (what `pre-commit autoupdate --freeze` writes). `repo: local` and `repo: meta` have no rev.
  local rev_re='(^|[{,[:space:]])rev:[[:space:]]*["'"'"']?([^"'"'"',}[:space:]#]*)'
  local frozen_re='#[[:space:]]*frozen:[[:space:]]*[^[:space:]]'
  while IFS= read -r -d '' f; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ $rev_re ]] || continue
      local rev="${BASH_REMATCH[2]}"
      [[ "$line" == *"# unpinned-ok:"* ]] && continue
      if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$f:$n: pre-commit rev not pinned to a commit SHA (rev: <sha> # frozen: <tag>): $rev"
        bad=1
      elif ! [[ "$line" =~ $frozen_re ]]; then
        echo "$f:$n: pre-commit rev has no \"# frozen: <tag>\" comment saying which release it is"
        bad=1
      fi
    done <"$f"
  done < <(git ls-files -z -- '.pre-commit-config.yaml' '.pre-commit-config.yml' '**/.pre-commit-config.yaml' \
    '**/.pre-commit-config.yml' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"})
  # No download piped into a shell (curl ... | sh, sh -c "$(curl ...)"): it runs whatever the server sends
  # that day. Download, check a checksum, then run. Scripts, workflows, actions, Dockerfiles and Makefiles.
  # After the pipe: sudo and its flags, env and its flags, and VAR=value assignments may come before the shell.
  local assign='[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+'
  local pipe_re='(curl|wget)(.*[^|])?\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?(env([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?('"$assign"')*([^[:space:]|]*/)?(ba|z|da|k)?sh([[:space:]]|;|\)|$)'
  local subst_re='(ba|z|da|k)?sh[[:space:]]+-c[[:space:]]+["'"'"']?\$\((curl|wget)'
  local procsub_re='(^|[[:space:];&|(])((ba|z|da|k)?sh|source|\.)[[:space:]]+<\([[:space:]]*(curl|wget)'
  local joined start
  while IFS= read -r -d '' f; do
    n=0 joined="" start=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      # A line ending in a backslash, or in a pipe, continues on the next: read them as one (the finding
      # names the first).
      [ -z "$joined" ] && start=$n
      if [[ "$line" == *\\ ]]; then
        joined="$joined${line%\\} "
        continue
      fi
      if [[ "$line" =~ \|[[:space:]]*$ && ! "$line" =~ \|\|[[:space:]]*$ ]]; then
        joined="$joined$line "
        continue
      fi
      line="$joined$line" joined=""
      [[ "$line" =~ $pipe_re || "$line" =~ $subst_re || "$line" =~ $procsub_re ]] || continue
      [[ "$line" == *"# unpinned-ok:"* ]] && continue
      echo "$f:$start: a download piped into a shell; download it, check its checksum, then run it"
      bad=1
    done <"$f"
  done < <({
    shell_files || true
    # Templates (chezmoi's *.tmpl, copier's *.jinja) become scripts and config when they are applied.
    git ls-files -z -- '*.tmpl' '**/*.tmpl' '*.jinja' '**/*.jinja' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"}
    workflow_files
    dockerfiles
    git ls-files -z -- 'Makefile' '**/Makefile' 'GNUmakefile' \
      '**/GNUmakefile' '*.mk' '**/*.mk' ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"}
  } | sort -zu)
  [ "$bad" = 0 ] && echo "pinned: actions by commit SHA, base images by digest, pre-commit revs by commit, no piped downloads"
  return "$bad"
}

# workflow-safety (src/workflow_safety.py): the workflow rules that keep secrets and runners out of reach.
cmd_workflow_safety() {
  local bad=0 files=() f args=() vis
  skipped workflow-safety || true
  while IFS= read -r -d '' f; do files+=("$f"); done < <(workflow_files)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "workflow-safety: no workflows"
    return "$bad"
  fi
  vis=$(visibility)
  [ "$vis" = PUBLIC ] && args+=(--public)
  if [ "$vis" = UNKNOWN ] && [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::warning::workflow-safety: this event does not say whether the repository is public; the public-runner rule was not checked"
  fi
  python3 "$(dirname "${BASH_SOURCE[0]}")/workflow_safety.py" ${args[@]+"${args[@]}"} "${files[@]}" || bad=1
  [ "$bad" = 0 ] && echo "workflow-safety: ${#files[@]} files, nothing found"
  return "$bad"
}

# non-root: every Dockerfile's final stage sets a USER other than root (a container runs as root otherwise).
# A Dockerfile that builds an image nothing runs from says why with "# non-root-ok: <reason>" on its own line;
# a repository can skip the check (the Action's skip input, a hook's --skip=non-root).
cmd_non_root() {
  local bad=0 f line n
  if skipped non-root; then return 0; fi
  local user_re='^[[:space:]]*[Uu][Ss][Ee][Rr][[:space:]]+([^[:space:]]+)'
  local ok_re='^[[:space:]]*#[[:space:]]*non-root-ok:[[:space:]]*[^[:space:]]'
  while IFS= read -r -d '' f; do
    # A stage starts as the user of the stage it is built FROM (or nonroot for an image tagged :nonroot);
    # "alias=user" pairs, one per line (bash 3.2 has no associative arrays).
    local user="" last_from=0 exempt=false stages="" alias="" image
    local stage_re='^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--[^[:space:]]+[[:space:]]+)*([^[:space:]]+)([[:space:]]+[Aa][Ss][[:space:]]+([^[:space:]]+))?'
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      if [[ "$line" =~ $ok_re ]]; then
        exempt=true
      elif [[ "$line" =~ $stage_re ]]; then
        [ -n "$alias" ] && stages="$stages$alias=$user"$'\n'
        image="${BASH_REMATCH[2]}" alias="${BASH_REMATCH[4]}" last_from=$n user=""
        local pair
        while IFS= read -r pair; do
          [ "$(echo "${pair%%=*}" | tr '[:upper:]' '[:lower:]')" = "$(echo "$image" | tr '[:upper:]' '[:lower:]')" ] && user="${pair#*=}"
        done <<<"$stages"
        [[ -z "$user" && "$image" == *:nonroot* ]] && user=nonroot
      elif [[ "$line" =~ $user_re ]]; then
        user="${BASH_REMATCH[1]}"
      fi
    done <"$f"
    $exempt && continue
    [ "$last_from" -gt 0 ] || continue
    case "$user" in
      "")
        echo "$f:$last_from: the final stage runs as root: add USER <name> after its FROM"
        bad=1
        ;;
      root | 0 | root:* | 0:*)
        echo "$f:$last_from: the final stage runs as root (USER $user)"
        bad=1
        ;;
    esac
  done < <(dockerfiles)
  [ "$bad" = 0 ] && echo "non-root: every Dockerfile's final stage runs as a user other than root"
  return "$bad"
}

cmd_verdict() {
  local failed=()
  [ "${SHELLCHECK_OUTCOME:-}" = failure ] && failed+=(shellcheck)
  [ "${ACTIONLINT_OUTCOME:-}" = failure ] && failed+=(actionlint)
  [ "${PINNED_OUTCOME:-}" = failure ] && failed+=(pinned)
  [ "${WORKFLOW_SAFETY_OUTCOME:-}" = failure ] && failed+=(workflow-safety)
  [ "${NON_ROOT_OUTCOME:-}" = failure ] && failed+=(non-root)
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "::error::lint: ${failed[*]} found something (see the steps above)"
    exit 1
  fi
  echo "lint: nothing found (shellcheck: ${SHELLCHECK_OUTCOME:-off}, actionlint: ${ACTIONLINT_OUTCOME:-off}, pinned: ${PINNED_OUTCOME:-off}, workflow-safety: ${WORKFLOW_SAFETY_OUTCOME:-off}, non-root: ${NON_ROOT_OUTCOME:-off})"
}

# A pre-commit/prek hook: the same check as the Action's step, on the repository's tracked files.
# The hook's args may add --exclude=<git glob> (repeatable), like the Action's exclude input.
cmd_hook() {
  local check="${1:-}" arg
  case "$check" in
    shellcheck | actionlint) install_tools ;;
    pinned | workflow-safety | non-root) ;;
    *)
      echo "usage: lint.sh hook shellcheck|actionlint|pinned|workflow-safety|non-root [--exclude=<glob>]..." >&2
      exit 2
      ;;
  esac
  shift
  for arg in "$@"; do
    case "$arg" in
      --exclude=*) EXCLUDE_GLOBS+=(":(exclude,glob)${arg#--exclude=}") ;;
      --skip=*) SKIP_CHECKS="${SKIP_CHECKS:-} ${arg#--skip=}" ;;
      *)
        echo "lint: unknown hook argument: $arg" >&2
        exit 2
        ;;
    esac
  done
  check_skip_ids >&2 || exit 2
  "cmd_${check//-/_}"
}

check="${1:?usage: lint.sh install|shellcheck|actionlint|pinned|workflow-safety|non-root|verdict|hook <check>}"
shift
"cmd_${check//-/_}" "$@"
