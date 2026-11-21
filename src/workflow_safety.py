#!/usr/bin/env python3
"""workflow-safety: the workflow rules that keep a repository's secrets and runners out of reach.

Usage: workflow_safety.py [--public] FILE...

For each workflow (.github/workflows/*.yml):
  - a top-level `permissions:` that grants nothing beyond read (write goes on the job that needs it);
  - a `pull_request_target` or `workflow_run` workflow never checks out or runs the pull request's code;
  - with --public, a workflow that pull requests or comments can start runs only on GitHub's runners
    (no `self-hosted` label and no `vars.*` runner choice);
  - no `workflow_dispatch` input that skips or forces the checks (skip-tests, force, bypass, no-verify).
For workflows and composite actions (action.yml): no `${{ secrets.* }}`, `${{ github.event.* }}` or
`${{ github.head_ref }}` written into a `run:` script, where the text becomes shell code. Pass it through
`env:` and use "$NAME" instead.

A line that must break a rule says why with `# workflow-safety-ok: <reason>` at its end; the missing
top-level `permissions:` has no exception. Prints one `path:line: why` line per finding; exits 1 if any.

YAML is read line by line (by indentation), not parsed: no third-party module, Python 3.9 or later.
"""

from __future__ import annotations

import re
import sys

OK = re.compile(r"#\s*workflow-safety-ok:\s*\S")
KEY = re.compile(r"""^(\s*)(-\s+)?(["']?)([A-Za-z0-9_.-]+)\3\s*:(?:\s+|$)(.*)$""")
EXPR = re.compile(r"\$\{\{(.*?)\}\}")
# Text an attacker can write (event payloads, branch names) or a secret: never shell code.
TAINTED = re.compile(
    r"\b(secrets\b|github\s*\.\s*event\b|github\s*\.\s*head_ref\b|github\s*\[)",
    re.IGNORECASE,
)
# The keys whose value is code: a run: script, and actions/github-script's script:.
CODE_KEYS = ("run", "script")
FLOW_CODE = re.compile(r"[{,]\s*[\"']?(run|script)[\"']?\s*:(.*)")
# The pull request's code: a checkout `ref:`/`repository:` naming its head, its refs/pull/ ref, or gh pr checkout.
# Naming its commit elsewhere (a message, an env value) is fine.
# A checkout ref is the base branch's code only when it names one of these; any other expression (the head,
# the merge commit, an env value or a step output that could hold either) counts as the pull request's code.
BASE_REF = re.compile(
    r"^\s*\$\{\{\s*(github\.event\.pull_request\.base\.(sha|ref)|github\.sha|github\.ref|github\.base_ref"
    r"|github\.event\.repository\.default_branch|github\.repository|github\.event\.repository\.full_name)\s*\}\}\s*$",
    re.IGNORECASE,
)
HEAD_RUN = re.compile(
    r"refs/pull/|\bpull/[^\s/]+/(head|merge)\b|\bgh\s+pr\s+checkout\b", re.IGNORECASE
)
# Events that anyone who can open a pull request or write a comment can start.
OUTSIDE_EVENTS = {
    "pull_request",
    "pull_request_target",
    "pull_request_review",
    "pull_request_review_comment",
    "issue_comment",
    "discussion_comment",
}
BYPASS_WORDS = {"skip", "force", "bypass"}


# `runs-on: ${{ (github.event.repository.private && vars.X) || '<GitHub-hosted label>' }}`: a vars.* runner only
# while the repository is private, GitHub's runner once it is public. The dotfiles copier templates use it.
PRIVATE_ONLY_RUNNER = re.compile(
    r"""^\$\{\{\s*\(\s*github\.event\.repository\.private\s*&&\s*vars\.[A-Za-z_][A-Za-z0-9_]*\s*\)"""
    r"""\s*\|\|\s*(['"])(ubuntu|windows|macos)-[A-Za-z0-9.-]+\1\s*\}\}$"""
)


def bypasses(name: str) -> bool:
    """An input name made of words such as skip, force or bypass (skip-tests, force_deploy, no-verify)."""
    low = name.lower()
    words = set(re.split(r"[-_\s]+", re.sub(r"([a-z])([A-Z])", r"\1_\2", name).lower()))
    return (
        bool(words & BYPASS_WORDS)
        or low.startswith("skip")
        or "noverify" in re.sub(r"[-_]", "", low)
    )


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def strip_comment(text: str) -> str:
    """The text before a YAML comment (a # at the start or after a space, outside quotes)."""
    quote = ""
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or text[i - 1] in " \t"):
            return text[:i].rstrip()
    return text.rstrip()


def is_blank(line: str) -> bool:
    s = line.strip()
    return not s or s.startswith("#")


def block(
    lines: list[str], start: int, key_indent: int, comments: bool = False
) -> list[int]:
    """Indexes of the lines below line `start` that belong to its key (indented more, or blank). With
    `comments`, a `#` line indented under the key is kept: inside a block scalar it is text, not a comment."""
    out = []
    for j in range(start + 1, len(lines)):
        if not lines[j].strip():
            continue
        if lines[j].strip().startswith("#") and not (
            comments and indent_of(lines[j]) > key_indent
        ):
            continue
        if indent_of(lines[j]) <= key_indent:
            break
        out.append(j)
    return out


def key_at(line: str):
    """(indent of the key, key, value) for a `key: value` line, or None."""
    m = KEY.match(line)
    if not m:
        return None
    ind = len(m.group(1)) + len(m.group(2) or "")
    return ind, m.group(4), strip_comment(m.group(5))


def top_level(lines: list[str]) -> dict[str, int]:
    keys = {}
    for i, line in enumerate(lines):
        if line[:1] not in ("", " ", "#", "-") and (k := key_at(line)) and k[0] == 0:
            name = "on" if k[1] in ("on", "true") else k[1]
            keys.setdefault(name, i)
    return keys


def triggers(lines: list[str], on_line: int) -> set[str]:
    _, _, value = key_at(lines[on_line])
    if value:
        return set(re.findall(r"[A-Za-z_]+", value))
    found = set()
    body = block(lines, on_line, 0)
    if not body:
        return found
    child = indent_of(lines[body[0]])
    for j in body:
        if indent_of(lines[j]) != child:
            continue
        s = strip_comment(lines[j].strip())
        if s.startswith("- "):
            found.add(s[2:].strip().strip("\"'"))
        elif k := key_at(lines[j]):
            found.add(k[1])
    return found


def dispatch_inputs(lines: list[str], on_line: int):
    """(line index, name) of every input under an `inputs:` key in the `on:` block."""
    for j in block(lines, on_line, 0):
        k = key_at(lines[j])
        if not k or k[1] != "inputs":
            continue
        if k[2]:  # a one-line mapping: every key in it
            for name in re.findall(r"[{,]\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*:", k[2]):
                yield j, name
            continue
        body = block(lines, j, k[0])
        if not body:
            continue
        child = indent_of(lines[body[0]])
        for b in body:
            kb = key_at(lines[b])
            if kb and indent_of(lines[b]) == child:
                yield b, kb[1]


def check_run_scripts(path: str, lines: list[str], report) -> None:
    for i, line in enumerate(lines):
        k = key_at(line)
        if k and k[1] in CODE_KEYS:
            rows = [
                (i, k[2]),
                *((j, lines[j]) for j in block(lines, i, k[0], comments=True)),
            ]
        elif m := FLOW_CODE.search(strip_comment(line)):
            rows = [(i, m.group(2))]
        else:
            continue
        for j, text in rows:
            for expr in EXPR.findall(text):
                if TAINTED.search(expr):
                    report(
                        j,
                        f"${{{{{expr}}}}} is written into a run: script, where it becomes shell code; "
                        'pass it through env: and use "$NAME"',
                    )
                    break


def check_workflow(path: str, lines: list[str], public: bool, report) -> None:
    keys = top_level(lines)
    if "permissions" not in keys:
        report(
            0,
            "no top-level permissions: (add `permissions: contents: read`, or `{}`, at the top; "
            "grant more on the job that needs it)",
            exempt=False,
        )
    else:
        p = keys["permissions"]
        _, _, value = key_at(lines[p])
        rows = [p] if value else block(lines, p, 0)
        for j in rows:
            text = strip_comment(lines[j]) if j != p else value
            if re.search(r"\bwrite(-all)?\b", text):
                report(
                    j,
                    "the top-level permissions grant write; grant it on the job that needs it",
                )
    events = triggers(lines, keys["on"]) if "on" in keys else set()
    if events & {"pull_request_target", "workflow_run"}:
        for j, line in enumerate(lines):
            if is_blank(line):
                continue
            k = key_at(line)
            if (
                k
                and k[1] in ("ref", "repository")
                and "${{" in k[2]
                and not BASE_REF.match(k[2])
            ) or (HEAD_RUN.search(strip_comment(line))):
                report(
                    j,
                    "a pull_request_target or workflow_run workflow runs with this repository's secrets; "
                    "it must not check out or run the pull request's code",
                )
    # A reusable workflow (workflow_call) counts too: a pull request's workflow may call it.
    if public and events & (OUTSIDE_EVENTS | {"workflow_call"}):
        why = (
            "a public repository's pull requests and comments run only on GitHub's runners "
            "(no self-hosted label, runner group or vars.* runner)"
        )
        flagged = set()
        code = set()
        for i, line in enumerate(lines):
            k = key_at(line)
            if k and k[1] in CODE_KEYS:
                code.update([i, *block(lines, i, k[0], comments=True)])
        for i, line in enumerate(lines):
            k = key_at(line)
            if k and k[1] == "runs-on":
                for j in [i, *block(lines, i, k[0])]:
                    text = k[2] if j == i else strip_comment(lines[j])
                    if PRIVATE_ONLY_RUNNER.match(strip_comment(text).strip()):
                        continue
                    if re.search(
                        r"self-hosted|\bvars\s*\.|\bgroup\s*:", text, re.IGNORECASE
                    ):
                        flagged.add(j)
            # A self-hosted label anywhere else (a matrix value runs-on reads, an include) counts as well.
            # (a value, not prose: a name: or description: line may mention self-hosted)
            k = key_at(line)
            if (
                i not in code
                and not (k and k[1] in ("name", "description"))
                and not is_blank(line)
                and re.search(r"self-hosted", strip_comment(line), re.IGNORECASE)
            ):
                flagged.add(i)
        for j in sorted(flagged):
            report(j, why)
    if "on" in keys:
        for j, name in dispatch_inputs(lines, keys["on"]):
            if bypasses(name):
                report(
                    j,
                    f"input {name!r} skips or forces the checks; a run either passes them or fails",
                )
    check_run_scripts(path, lines, report)


def main(argv: list[str]) -> int:
    public = "--public" in argv
    files = [a for a in argv if a != "--public"]
    findings = 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()

        def report(
            i: int, why: str, exempt: bool = True, lines=lines, path=path
        ) -> None:
            nonlocal findings
            line = lines[i] if i < len(lines) else ""
            if exempt and OK.search(line):
                return
            findings += 1
            print(f"{path}:{i + 1}: {why}")

        if re.search(r"(^|/)\.github/workflows/[^/]+\.ya?ml$", path):
            check_workflow(path, lines, public, report)
        else:
            check_run_scripts(path, lines, report)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
