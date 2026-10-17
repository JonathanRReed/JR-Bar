from pathlib import Path

import pytest

from jrbar.collector import RECENT_LINES_MAX_BYTES, read_recent_lines


def test_sparse_giant_line_tail_reads_at_most_byte_budget(tmp_path: Path, monkeypatch) -> None:
    path = tmp_path / "synthetic.jsonl"
    with path.open("wb") as handle:
        handle.seek(1024 * 1024 * 1024)
        handle.write(b'giant-line-end\n{"latest":1}\n{"latest":2}\n')
    original_open = Path.open
    reads = []

    class CountingReader:
        def __init__(self, handle):
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.handle.close()

        def seek(self, *args):
            return self.handle.seek(*args)

        def tell(self):
            return self.handle.tell()

        def read(self, size):
            reads.append(size)
            return self.handle.read(size)

    monkeypatch.setattr(Path, "open", lambda self, *args, **kwargs:
                        CountingReader(original_open(self, *args, **kwargs)))
    assert read_recent_lines(path, 500) == ['{"latest":1}', '{"latest":2}']
    assert sum(reads) <= RECENT_LINES_MAX_BYTES
    assert max(reads) <= 8192


@pytest.mark.parametrize("tail", [b"\nalpha\nbeta\n", "\n日本語\nlast".encode()])
def test_tail_discards_cap_cut_row_and_preserves_utf8(tmp_path: Path, tail: bytes) -> None:
    path = tmp_path / "tail"
    path.write_bytes(b"x" * 1000 + tail)
    expected = tail.decode().splitlines()[1:]
    assert read_recent_lines(path, 10, max_bytes=len(tail) + 10) == expected
    assert read_recent_lines(path, 1, max_bytes=len(tail) + 10) == expected[-1:]


def test_tail_cap_at_line_boundary_keeps_first_complete_row(tmp_path: Path) -> None:
    path = tmp_path / "tail"
    path.write_bytes(b"old\nalpha\nbeta\n")
    assert read_recent_lines(path, 10, max_bytes=len(b"alpha\nbeta\n") + 1) == ["alpha", "beta"]
    path.write_bytes(b"x" * 1000)
    assert read_recent_lines(path, 10, max_bytes=100) == []


def test_zero_line_or_byte_limit_never_opens_file(tmp_path: Path) -> None:
    missing = tmp_path / "missing"
    assert read_recent_lines(missing, 0) == []
    assert read_recent_lines(missing, 1, max_bytes=0) == []
