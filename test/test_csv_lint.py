"""csv-lint: what it refuses, what it allows, and that it never prints a cell or rewrites a file."""

from __future__ import annotations

import pytest

from kilotronic_lint.csv_lint import main, problems


def write(tmp_path, name, data: bytes):
    path = tmp_path / name
    path.write_bytes(data)
    return str(path)


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"a,b\n1,2\n",
        b'a,b\n"x, y",2\n',
        b'a,b\n"two\nlines",2\n',
        b"a,b\r\n1,2\r\n",
        b"\xef\xbb\xbfa,b\n1,2\n",
        "a,b\né,2\n".encode(),
    ],
)
def test_allows(tmp_path, data):
    assert problems(write(tmp_path, "x.csv", data)) == []


@pytest.mark.parametrize(
    ("data", "want"),
    [
        (b"a,b\n1,2,3\n", ":2: 3 columns; the first row has 2"),
        (b"a,b\n1\n", ":2: 1 columns; the first row has 2"),
        (b"a,b\n\n1,2\n", ":2: an empty row; the first row has 2"),
        (b"a,b\n1,2", ":2: no newline at the end of the file"),
        (b"a,b\n\xff,2\n", ":2: not UTF-8"),
        (b'a,b\n"open,2\n', "not valid CSV"),
    ],
)
def test_refuses(tmp_path, data, want):
    found = problems(write(tmp_path, "x.csv", data))
    assert any(want in f for f in found), found


def test_tsv_uses_tabs(tmp_path):
    assert problems(write(tmp_path, "x.tsv", b"a\tb\n1,2\t3\n")) == []
    assert problems(write(tmp_path, "y.tsv", b"a\tb\n1\t2\t3\n"))


def test_never_prints_a_cell_and_never_rewrites(tmp_path, capsys):
    data = b"name,secret\nalice,hunter2,extra\n"
    path = write(tmp_path, "x.csv", data)
    assert main([path]) == 1
    out = capsys.readouterr().out
    assert "hunter2" not in out and "alice" not in out
    assert (tmp_path / "x.csv").read_bytes() == data


def test_caps_findings_per_file(tmp_path):
    rows = b"".join(b"1,2,3\n" for _ in range(25))
    found = problems(write(tmp_path, "x.csv", b"a,b\n" + rows))
    assert len(found) == 11 and "15 more rows" in found[-1]


def test_exit_code(tmp_path):
    assert main([write(tmp_path, "ok.csv", b"a\n1\n")]) == 0
