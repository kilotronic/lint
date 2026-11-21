"""Wrappers that run yamllint and shfmt with the repository's own configuration when it has one, and the
bundle's defaults when it has none. A repository's own file always wins, whole: nothing is merged."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
YAMLLINT_OWN = (".yamllint", ".yamllint.yaml", ".yamllint.yml")


def yamllint_main() -> None:
    from yamllint import cli

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
