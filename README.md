# lint

A GitHub Action and a set of pre-commit hooks for the checks every repository wants, with no configuration.

The Action runs five checks:

- **shellcheck** on every tracked shell script: `*.sh`, `*.bash`, and extension-less files with a
  `sh`/`bash` shebang.
- **actionlint** on every workflow in `.github/workflows`. It also runs shellcheck on each `run:` script.
- **pinned**: every action a workflow uses is pinned to a full commit SHA (a tag or branch can be moved to
  other code), every Docker base image to a digest (`image@sha256:...`), every pre-commit hook's `rev:` to a
  commit SHA with its tag as a `# frozen: <tag>` comment (what `pre-commit autoupdate --freeze` writes), and no
  download is piped into a shell (`curl ... | sh`, `sh -c "$(curl ...)"`, `bash <(curl ...)`, also across a
  backslash-continued line) in a script, workflow, action, Dockerfile or Makefile.
- **workflow-safety**, on every workflow:
  - a top-level `permissions:` that grants nothing beyond read (`contents: read`, `{}` or `read-all`); a job that
    needs write asks for it itself;
  - a `pull_request_target` or `workflow_run` workflow never checks out or runs the pull request's code: a
    checkout `ref:` or `repository:` expression may name only the base (`github.event.pull_request.base.*`,
    `github.sha`, `github.ref`, `github.base_ref`, the default branch), and no script fetches `pull/<n>/head`,
    a `refs/pull/` ref or runs `gh pr checkout`;
  - no `${{ secrets.* }}`, `${{ github.event.* }}` or `${{ github.head_ref }}` (any case) written into a `run:`
    script or `actions/github-script`'s `script:` (workflows and composite actions, one-line step mappings
    too), where the text becomes code: pass it through `env:` and use `"$NAME"`;
  - on a public repository, a workflow that pull requests or comments can start (or a reusable one, which such
    a workflow may call, even if only push workflows call it today) runs only on GitHub's runners: no `self-hosted` label anywhere outside a script (a
    matrix value included), no runner group and no `vars.*` runner choice;
  - no `workflow_dispatch` input that skips or forces the checks (a name with the word `skip`, `force` or
    `bypass`, or `no-verify`).
- **non-root**: every Dockerfile's final stage runs as a user other than root: its own `USER`, the user of the
  stage it is built `FROM`, or an image tagged `:nonroot`.

shellcheck and actionlint are installed at pinned versions, and their downloads are checked against
checksums. All checks always run, so one run shows every finding. The job fails if any of them found
something.

workflow-safety is this repository's own check, not [zizmor](https://github.com/zizmorcore/zizmor): zizmor
judges which `${{ }}` text an attacker controls and flags `pull_request_target` whether or not it runs pull
request code, while these rules are plainer and stricter (no secret or event text in a `run:` script at all,
read-only at the top, no self-hosted runner for a public repository's pull requests), need no third download,
and run with Python's standard library alone.

## Use

```yaml
on: [pull_request]
permissions:
  contents: read
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4       # pin a commit SHA, as the pinned check will tell you
      - uses: kilotronic/lint@v1        # pin a commit SHA in production
```

Linux and macOS runners, x86_64 or arm64.

## Use as pre-commit or prek hooks: the format and lint bundle

The same checks, and a formatter and a linter for every common file type, run on your machine with
[prek](https://github.com/j178/prek) or [pre-commit](https://pre-commit.com), at pinned versions. One block in
your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/kilotronic/lint
    rev: <commit of the release>  # frozen: v1.2.0
    hooks:
      # format-all: formatters, which rewrite files (first, so the linters see the result)
      - id: ruff-format          # Python
      - id: prettier             # JS, TS, CSS, Markdown, JSON, YAML
      - id: shfmt                # shell
      - id: taplo-format         # TOML
      # lint-all: linters
      - id: ruff-check           # Python (fixes what it safely can)
      - id: shellcheck
      - id: actionlint
      - id: markdownlint
      - id: yamllint
      - id: csv-lint             # UTF-8, same columns in every row, a final newline; never rewritten
      - id: check-json
      - id: check-yaml
      - id: check-toml
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: mixed-line-ending
      - id: check-merge-conflict
      # workflows, pins and containers
      - id: pinned
      - id: workflow-safety
      - id: non-root
        # args: [--exclude=vendor/**]   # like the Action's exclude input (lint.sh hooks only)
```

Run the same hooks in CI with `prek run --all-files` (`SKIP=` any hook CI must not run), so a commit is
checked the same way at commit time and in CI.

| Hooks | Versions | Default configuration when the repository has none of its own |
| --- | --- | --- |
| `ruff-format`, `ruff-check` | ruff 0.17.4 | ruff's defaults (`ruff.toml` / `pyproject.toml` win) |
| `prettier` | prettier 3.9.10 | prettier's defaults (`.prettierrc`, `.prettierignore` win); lockfiles skipped |
| `shfmt` | shfmt-py 4.2.0 | `-i 2 -ci -bn`; a `.editorconfig` replaces them |
| `taplo-format` | taplo 0.9.3 | taplo's defaults (`taplo.toml` / `.taplo.toml` win) |
| `markdownlint` | markdownlint-cli2 0.24.0 | [`src/markdownlint/.markdownlint.jsonc`](src/markdownlint/.markdownlint.jsonc): line length and table layout left to prettier |
| `yamllint` | yamllint 1.38.0 | [`src/kilotronic_lint/yamllint.yaml`](src/kilotronic_lint/yamllint.yaml): spacing left to prettier, `on:` allowed |
| `csv-lint` | this repository | none needed; prints where, never a cell's text |
| `check-*`, fixers | pre-commit-hooks 6.0.0 | CSV/TSV files are never rewritten; `check-json` skips JSON-with-comments files (`tsconfig*.json`, `.vscode/`, `.devcontainer/`) |

The `lint.sh` hooks (`shellcheck`, `actionlint`, `pinned`, `workflow-safety`, `non-root`) run the Action's own
step on all of the repository's tracked files, so a commit is checked the way CI will check it. shellcheck and
actionlint are downloaded once, at the same pinned versions and with the same checksum checks, into
`~/.cache`. They need `bash`, `curl`, `tar` and `python3` (Linux or macOS). The others need Python 3.9 or later,
and Node for `prettier` and `markdownlint`.

workflow-safety's public-repository rule needs to know the repository's visibility: the Action reads the event's
(as `KILOTRONIC_VISIBILITY`); a hook asks `gh repo view` once a day and keeps the answer in the clone's git
directory (`kilotronic-visibility`, the same file kilotronic/git-identity's hooks use). Offline or without `gh`,
the repository counts as not public; in an Action run that can't tell, the step says so as a warning.

## Skipping a check

Only `non-root` can be skipped: `skip: non-root` in the Action, `args: [--skip=non-root]` on the hook (or leave
the hook out). The reason for a skip lives in the owner's repository settings, which a nightly sweep matches
against each workflow's `skip:`.

The floor checks can't be skipped: naming `shellcheck`, `actionlint`, `pinned`, `workflow-safety`, `lint-all` or
`format-all` in `skip` prints a warning and the check runs anyway, and so does setting the v1 inputs
`shellcheck`, `actionlint` or `pinned` to `false`. Ids are lower case; an unknown id fails the run, so a typo can't look like a skip.

## Settings in your repository

- **Self-hosted runner labels:** actionlint reports labels it doesn't know. List yours in
  `.github/actionlint.yaml`:
  ```yaml
  self-hosted-runner:
    labels:
      - azure
  ```
- **shellcheck options:** a `.shellcheckrc` in the repository applies as usual.
- **A line that can't carry its own pin:** for example a Docker build context whose digest the build
  command supplies. Say why with `# unpinned-ok: <reason>`: at the end of the workflow's `uses:` line, a
  pre-commit `rev:` line or a piped download's line, or on its own line just above the Dockerfile's `FROM`
  (Docker allows comments only on their own line).
- **A workflow line that must break a workflow-safety rule:** `# workflow-safety-ok: <reason>` at its end. The
  missing top-level `permissions:` has no exception.
- **A Dockerfile for an image nothing runs:** `# non-root-ok: <reason>` on its own line anywhere in it.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `skip` | empty | Checks to skip, by id: only `non-root`; a floor check named here warns and runs |
| `shellcheck`, `actionlint`, `pinned` | `true` | Kept for v1 callers: floor checks, so `false` warns and they run |
| `exclude` | empty | Space- or newline-separated git glob patterns that shellcheck, pinned, workflow-safety and non-root skip, e.g. `vendor/** originals/**` |
| `shellcheck-args` | empty | Extra shellcheck arguments, split on spaces, e.g. `--severity=warning` |
| `actionlint-args` | empty | Extra actionlint arguments, split on spaces, e.g. `-ignore=SC2016` |

## Versions

shellcheck 0.11.0 and actionlint 1.7.12. A new version means new checksums in `src/lint.sh`. The bundle's
versions are in `.pre-commit-hooks.yaml` and the table above.

Releases are tagged `vX.Y.Z`, with a moving `vX` tag for the Action. Hooks pin the release's commit.

MIT
