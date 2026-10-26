"""The HID rebuild refuses unreviewed archives and unexpected source."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import pytest

spec = spec_from_file_location("headless_hidapi", Path(__file__).resolve().parents[1] / "packaging/build_headless_hidapi.py")
builder = module_from_spec(spec)
spec.loader.exec_module(builder)


def test_unreviewed_source_is_rejected_before_extracting_or_building(tmp_path):
    archive = tmp_path / "source.tar.gz"
    archive.write_bytes(b"unreviewed")
    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        builder.build(archive, tmp_path / "output")
    assert not (tmp_path / "output").exists()


@pytest.mark.parametrize("source", ["no match", "old old"])
def test_patch_requires_exactly_one_match(tmp_path, source):
    path = tmp_path / "hid.c"
    path.write_text(source)
    with pytest.raises(ValueError, match="unexpected HID source"):
        builder.replace_once(path, "old", "new")
    assert path.read_text() == source
