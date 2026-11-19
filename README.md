# lint

A GitHub Action that runs three checks every repository wants, with no configuration:

- **shellcheck** on every tracked shell script: `*.sh`, `*.bash`, and extension-less files with a
  `sh`/`bash` shebang.
- **actionlint** on every workflow in `.github/workflows`. It also runs shellcheck on each `run:` script.
- **pinned**: every action a workflow uses is pinned to a full commit SHA (a tag or branch can be moved to
  other code), and every Docker base image to a digest (`image@sha256:...`).

shellcheck and actionlint are installed at pinned versions, and their downloads are checked against
checksums. All three checks always run, so one run shows every finding. The job fails if any of them found
something.

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
  command supplies. End the line with `# unpinned-ok: <reason>`, and the pinned check passes it.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `shellcheck` | `true` | Run shellcheck on shell scripts (also used by actionlint for `run:` scripts) |
| `actionlint` | `true` | Run actionlint on `.github/workflows` |
| `pinned` | `true` | Check actions are pinned to commit SHAs and base images to digests |
| `exclude` | empty | Space- or newline-separated git glob patterns that shellcheck and the pinned check skip, e.g. `vendor/** originals/**` |
| `shellcheck-args` | empty | Extra shellcheck arguments, split on spaces, e.g. `--severity=warning` |
| `actionlint-args` | empty | Extra actionlint arguments, split on spaces, e.g. `-ignore=SC2016` |

## Versions

shellcheck 0.11.0 and actionlint 1.7.12. A new version means new checksums in `src/lint.sh`.

MIT
