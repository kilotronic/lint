"""Wrappers that run yamllint and shfmt with the repository's own configuration when it has one, and the
bundle's defaults when it has none. A repository's own file always wins, whole: nothing is merged."""

from __future__ import annotations

import io
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
YAMLLINT_OWN = (".yamllint", ".yamllint.yaml", ".yamllint.yml")
# cloud-init reads a user-data file only when its first line is exactly this, with no space after the "#".
CLOUD_CONFIG = re.compile(r"#cloud-config[ \t]*\r?(\n|$)")


def _allow_cloud_config(linter) -> None:
    """Drop yamllint's "missing starting space in comment" for a `#cloud-config` first line, the way yamllint
    already allows a `#!` shebang there. Every other problem, on that line or any other, is kept."""
    run = linter.run

    def patched(source, conf, filepath=None):
        if isinstance(source, io.IOBase):
            source = source.read()
        text = (
            source.decode("utf-8", "replace") if isinstance(source, bytes) else source
        )
        problems = run(source, conf, filepath)
        if not CLOUD_CONFIG.match(text):
            return problems
        return (
            p
            for p in problems
            if not (p.line == 1 and p.rule == "comments" and "starting space" in p.desc)
        )

    linter.run = patched


def yamllint_main() -> None:
    from yamllint import cli, linter

    _allow_cloud_config(linter)
    args = sys.argv[1:]
    if not any(Path(f).is_file() for f in YAMLLINT_OWN) and not os.environ.get(
        "YAMLLINT_CONFIG_FILE"
    ):
        args = ["-c", str(HERE / "yamllint.yaml"), *args]
    cli.run(["--strict", *args])


def shfmt_main() -> None:
    # The owner's shell style (2-space indent, indented case, binary operators start a line) unless the
    # repository says otherwise in .editorconfig (shfmt reads it only when given no style flags).
    style = [] if Path(".editorconfig").is_file() else ["-i", "2", "-ci", "-bn"]
    sys.exit(subprocess.call(["shfmt", "-w", *style, *sys.argv[1:]]))
