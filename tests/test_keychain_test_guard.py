"""The suite refuses unstubbed Keychain access before spawning anything."""

import subprocess
import sys

import pytest

from jrbar import keychain_read


@pytest.mark.parametrize("command", [
    ["/usr/bin/security", "find-generic-password", "-s", "synthetic"],
    ["security", "show-keychain-info"],
    [sys.executable, "-m", "jrbar.keychain_read", "--service", "synthetic"],
])
@pytest.mark.parametrize("spawn", [subprocess.run, subprocess.Popen])
def test_real_keychain_subprocess_is_blocked(command, spawn):
    # Look up the guarded entry point after fixture setup.
    with pytest.raises(pytest.fail.Exception, match="live Keychain"):
        getattr(subprocess, spawn.__name__)(command)


def test_real_keychain_api_is_blocked():
    with pytest.raises(pytest.fail.Exception, match="real Keychain API"):
        keychain_read._load_api()


def test_reader_cannot_swallow_the_real_api_guard():
    with pytest.raises(pytest.fail.Exception, match="real Keychain API"):
        keychain_read._read_secret("synthetic")
