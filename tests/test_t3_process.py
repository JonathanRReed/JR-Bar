"""Process detection never starts a shell or opens T3's database."""
from __future__ import annotations

import pytest

from jrbar import t3_process


@pytest.mark.parametrize("bundle, expected", [
    (b"/Applications/T3 Code.app/Contents/MacOS/T3 Code", True),
    (b"/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)", True),
    (b"/synthetic/T3 Code", False),
])
def test_libproc_accepts_only_the_desktop_bundle(monkeypatch, bundle, expected):
    class Lib:
        def proc_listpids(self, kind, flags, buffer, size):
            if buffer is not None:
                buffer[0] = 42
            return 4

        def proc_name(self, pid, buffer, size):
            buffer.value = b"T3 Code"
            return len(buffer.value)

        def proc_pidpath(self, pid, buffer, size):
            buffer.value = bundle
            return len(bundle)

    monkeypatch.setattr(t3_process, "_libproc", lambda: Lib())
    monkeypatch.setattr(t3_process, "_cached", (0.0, False))
    assert t3_process.t3_code_running() is expected
    monkeypatch.setattr(t3_process, "_libproc", lambda: pytest.fail("cached check loaded libproc"))
    assert t3_process.t3_code_running() is expected
