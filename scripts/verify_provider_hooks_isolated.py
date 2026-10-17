#!/usr/bin/env python3
"""Check real Claude/Codex normal-turn hooks against a local scripted API.

This checks hook emission only. It does not certify approvals, interruptions,
daemon projection, quota sources, or supported version ranges. Provider
processes can read only their own executable in the real home and cannot
connect beyond loopback.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd")
PROFILE = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))'


def _run(argv: list[str], env: dict[str, str], work: Path, timeout: int = 60) -> subprocess.CompletedProcess:
    process = subprocess.Popen(
        argv, env=env, cwd=work, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        raise RuntimeError("provider probe timed out") from None
    return subprocess.CompletedProcess(argv, process.returncode, output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=("claude", "codex"), nargs="+", default=["claude", "codex"])
    parser.add_argument("--receipt", type=Path, required=True, help="save the synthetic check receipt")
    args = parser.parse_args()
    if not Path("/usr/bin/sandbox-exec").is_file():
        parser.error("sandbox-exec is required to block external traffic")
    real_home = str(Path.home().resolve())
    binaries = {name: shutil.which(name) for name in args.only}
    spec = importlib.util.spec_from_file_location("local_provider_harness", REPO / "scripts/verify_providers_live.py")
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    receipts = []
    with tempfile.TemporaryDirectory(prefix="jrbar-hook-isolated-") as temporary:
        scratch = Path(temporary).resolve()
        home, work, state = (scratch / name for name in ("home", "work", "state"))
        for directory in (home, work, state):
            directory.mkdir(mode=0o700)
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "XDG_CONFIG_HOME": str(scratch / "config"), "XDG_STATE_HOME": str(state),
            "XDG_CACHE_HOME": str(scratch / "cache"), "JRBAR_STATE_DIR": str(state),
            "PYTHONPATH": str(REPO / "src"), "TMPDIR": str(scratch),
            "TERM": "dumb", "MOCK_API_KEY": "fixture-local-api-key",
            "ANTHROPIC_API_KEY": "fixture-local-api-key",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_DISABLE_AUTO_UPDATE": "1",
        }
        shim = scratch / "jrbar-hook"
        subprocess.run(["/usr/bin/clang", "-O2", "-std=c11", "-o", str(shim), str(REPO / "hook/jrbar-hook.c")], check=True)
        env["JRBAR_HOOK_EXEC"] = str(shim)
        prepare = '''
import json, os
from pathlib import Path
from jrbar import install
home = Path(os.environ["HOME"])
state = Path(os.environ["JRBAR_STATE_DIR"])
codex = home / ".codex/config.toml"
claude = home / ".claude/settings.json"
install.install_codex_hooks(config_path=codex, log_path=state / "codex.jsonl")
install.install_claude_hooks(config_path=claude, log_path=state / "claude.jsonl")
'''
        _run([sys.executable, "-c", prepare], env, work).check_returncode()
        for provider in args.only:
            binary = binaries[provider]
            if binary is None:
                receipts.append({"provider": provider, "status": "missing_cli"})
                continue
            binary_real = str(Path(binary).resolve())
            mock = harness.Mock(scratch)
            try:
                child_env = dict(env)
                if provider == "codex":
                    config = home / ".codex/config.toml"
                    config.write_text(
                        'model = "mock-model"\nmodel_provider = "mock"\n'
                        'suppress_unstable_features_warning = true\n'
                        '[model_providers.mock]\nname = "mock"\n'
                        f'base_url = "{mock.base}/v1"\nenv_key = "MOCK_API_KEY"\n'
                        'wire_api = "responses"\nrequest_max_retries = 0\nstream_max_retries = 0\n'
                        + config.read_text()
                    )
                    child_env["CODEX_HOME"] = str(config.parent)
                    argv = [binary_real, "exec", "--skip-git-repo-check", "-s", "danger-full-access",
                            "-c", 'approval_policy="never"', "--json", "run echo hi"]
                else:
                    child_env["CLAUDE_CONFIG_DIR"] = str(home / ".claude")
                    child_env["ANTHROPIC_BASE_URL"] = mock.base
                    argv = [binary_real, "-p", "run echo hi", "--dangerously-skip-permissions"]
                profile = PROFILE + (
                    f'(deny file-read-data (subpath {json.dumps(real_home)}))'
                    f'(deny file-write* (subpath {json.dumps(real_home)}))'
                    f'(allow file-read* (literal {json.dumps(binary_real)}))'
                )
                completed = _run(["/usr/bin/sandbox-exec", "-p", profile, *argv], child_env, work)
                path = state / f"{provider}.pending.jsonl"
                events = []
                if path.is_file():
                    for line in path.read_text().splitlines():
                        payload = json.loads(json.loads(line)["payload"])
                        events.append(payload.get("hook_event_name"))
                remaining = iter(events)
                ordered = all(any(event == item for item in remaining) for event in EVENTS)
                passed = completed.returncode == 0 and mock.requests() >= 2 and ordered
                version = _run(["/usr/bin/sandbox-exec", "-p", profile, binary_real, "--version"], child_env, work, 10)
                version_line = next((line for line in reversed(version.stdout.splitlines())
                                     if re.search(r"\d+\.\d+\.\d+", line)), None)
                receipt = {"provider": provider, "version": version_line,
                           "status": "passed" if passed else "failed", "exitCode": completed.returncode,
                           "mockRequests": mock.requests(), "events": events,
                           "scope": "normal-turn hook emission, isolated scratch home, loopback API"}
                if not passed:
                    receipt["diagnostic"] = completed.stdout[-1200:]
                receipts.append(receipt)
                print(json.dumps(receipt), flush=True)
            finally:
                mock.stop()
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps({
        "testedAt": datetime.now(timezone.utc).isoformat(),
        "network": "loopback only, enforced by sandbox-exec",
        "realHome": "file writes denied; file data reads denied except the CLI executable",
        "providers": receipts,
    }, indent=2) + "\n")
    return 0 if receipts and all(row["status"] == "passed" for row in receipts) else 1


if __name__ == "__main__":
    raise SystemExit(main())
