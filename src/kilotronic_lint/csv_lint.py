"""csv-lint: every CSV (or TSV) file is UTF-8, has the same number of columns in every row, and ends with a
newline. It never rewrites a file (a CSV is data: a fixer could change a value) and never prints a cell, so
a finding in a public log shows where, not what.

Usage: kilotronic-csv-lint FILE...   (a .tsv file is read with tabs)
"""

from __future__ import annotations

import csv
import io
import sys

MAX_PER_FILE = 10


def problems(path: str) -> list[str]:
    with open(path, "rb") as fh:
        data = fh.read()
    if not data:
        return []
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as err:
        line = data[: err.start].count(b"\n") + 1
        return [f"{path}:{line}: not UTF-8 (byte {err.start + 1}); save it as UTF-8"]
    found = []
    if not text.endswith("\n"):
        found.append(
            f"{path}:{text.count(chr(10)) + 1}: no newline at the end of the file"
        )
    delimiter = "\t" if path.lower().endswith(".tsv") else ","
    reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter, strict=True)
    width = None
    mismatched = 0
    try:
        for row in reader:
            if width is None:
                width = len(row)
            elif len(row) != width:
                mismatched += 1
                if mismatched <= MAX_PER_FILE:
                    what = "an empty row" if row == [] else f"{len(row)} columns"
                    found.append(
                        f"{path}:{reader.line_num}: {what}; the first row has {width}"
                    )
    except csv.Error as err:
        found.append(f"{path}:{reader.line_num}: not valid CSV: {err}")
    if mismatched > MAX_PER_FILE:
        found.append(
            f"{path}: and {mismatched - MAX_PER_FILE} more rows with the wrong number of columns"
        )
    return found


def main(argv: list[str] | None = None) -> int:
    paths = sys.argv[1:] if argv is None else argv
    csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
    found = [p for path in paths for p in problems(path)]
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
