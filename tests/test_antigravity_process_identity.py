from __future__ import annotations

import os
import subprocess

import pytest

from jrbar import antigravity_process_identity as identity


def test_signed_path_cannot_substitute_for_a_rejected_running_process__and_2_more(monkeypatch) -> None:
    # --- scenario: signed_path_cannot_substitute_for_a_rejected_running_process
    monkeypatch.setattr(
        identity, "_process_facts",
        lambda _pid: (str(identity.ANTIGRAVITY_LANGUAGE_SERVER), os.getuid(), 100, 200),
    )
    monkeypatch.setattr(identity, "_canonical_language_server", lambda _path: True)
    monkeypatch.setattr(
        identity, "_running_process_is_trusted", lambda _pid: False, raising=False,
    )

    assert identity.verified_antigravity_process_identity(1234) is None

    # --- scenario: verified_identity_requires_stable_os_facts
    monkeypatch.undo()
    for changed_process in [False, True]:
        initial = (str(identity.ANTIGRAVITY_LANGUAGE_SERVER), os.getuid(), 100, 200)
        after = (*initial[:2], 101, 0) if changed_process else initial
        observations = iter((initial, after))
        monkeypatch.setattr(identity, "_process_facts", lambda _pid: next(observations))
        monkeypatch.setattr(identity, "_canonical_language_server", lambda _path: True)
        monkeypatch.setattr(identity, "_running_process_is_trusted", lambda _pid: True)

        result = identity.verified_antigravity_process_identity(1234)

        assert result == (None if changed_process else (1234, *initial))

    # --- scenario: invalid_pid_never_reaches_native_validation
    monkeypatch.undo()
    for pid in [0, -1, True, "1234", 2**40]:
        def unexpected_load(*_args, **_kwargs):
            raise AssertionError("invalid PID reached a native framework")

        monkeypatch.setattr(identity.ctypes, "CDLL", unexpected_load)
        assert not identity._running_process_is_trusted(pid)



def test_os_process_facts_match_the_current_process():
    facts = identity._process_facts(os.getpid())
    assert facts is not None
    assert facts[1] == os.getuid()
    assert facts[2] > 0
    assert 0 <= facts[3] < 1_000_000


def test_real_signed_system_process_matches_only_its_publisher(monkeypatch):
    for publisher in ["google", "apple", "wrong-identifier", "invalid-requirement"]:
        if publisher == "apple":
            monkeypatch.setattr(identity, "_PROCESS_REQUIREMENT", "anchor apple")
        elif publisher == "wrong-identifier":
            monkeypatch.setattr(identity, "_PROCESS_REQUIREMENT", 'anchor apple and identifier "not-sleep"')
        elif publisher == "invalid-requirement":
            monkeypatch.setattr(identity, "_PROCESS_REQUIREMENT", "! invalid requirement syntax !")
        process = subprocess.Popen(["/bin/sleep", "30"])
        try:
            check = getattr(identity, "_running_process_is_trusted", None)
            assert callable(check)
            assert check(process.pid) is (publisher == "apple")
        finally:
            process.terminate()
            process.wait(timeout=2)
