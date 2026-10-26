#!/usr/bin/env python3
"""Measure the real core with synthetic hook sessions and two LED files.

The child runs a frozen copy of src, a temporary home, and the production
entry point. Hardware discovery is restricted to the fake volumes. Network,
Keychain, power assertions, HID and desktop automation are refused. CPU is
one core's process CPU, excluding startup. Tracing is a separate optional
mode because allocation tracing changes CPU and RSS. No installed app runs.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import tracemalloc


def child(root: Path, seconds: float, sessions: int, trace: bool) -> None:
    sys.path.insert(0, str(root / "src"))
    if trace:
        tracemalloc.start(1)
    original_run = subprocess.Popen

    def guarded_popen(args, *rest, **kwargs):
        executable = Path(args[0] if isinstance(args, (list, tuple)) else args).name
        if executable in {"security", "osascript", "caffeinate", "pmset", "ioreg", "hidutil"}:
            raise OSError("hardware and account probes are disabled in the synthetic workload")
        return original_run(args, *rest, **kwargs)

    subprocess.Popen = guarded_popen

    def audit(event, args):
        if event == "socket.connect" and args[0].family != socket.AF_UNIX:
            raise OSError("network is disabled in the synthetic workload")

    sys.addaudithook(audit)
    from jrbar import core_runtime, status_bar_legacy as controller_module
    from jrbar.device_writer import discover_devices

    volumes = root / "Volumes"
    for name, count in (("SidePulsePro", 8), ("SidePulseDot", 2)):
        volume = volumes / name
        volume.mkdir(parents=True)
        (volume / "LEDS.LED").write_text("off\n")
        (volume / "STATUS.TXT").write_text(f"led_count={count}\n")
    controller_module.discover_devices = lambda **_: discover_devices(mount_root=volumes)
    # The pad is outside this workload. Never enumerate the owner's HID bus.
    from jrbar.application_composition import compose_status_bar_application

    compose_status_bar_application()
    cls = core_runtime.build_headless_controller_class()
    cls._core_deck_probe_now = lambda self: None
    holder = []

    class Allocation:
        def init(self):
            result = cls.alloc().init()
            holder.append(result)
            return result

    class Factory:
        @staticmethod
        def alloc():
            return Allocation()

    core_runtime.build_headless_controller_class = lambda: Factory
    stop = threading.Event()

    def sample():
        from jrbar.hook_ingress_protocol import HookIngressRequest, submit_hook_ingress
        from jrbar.memory_probe import resident_bytes
        from jrbar.state_paths import default_state_dir

        sock = root / "core.sock"
        deadline = time.monotonic() + 120
        while not sock.exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("core did not start")
            stop.wait(0.05)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(str(sock))
        client.settimeout(0.2)
        messages = collections.Counter()
        sizes = collections.Counter()
        pending = b""
        rss = []
        latency = []
        heap = []
        start = time.monotonic()
        cpu_start = resource.getrusage(resource.RUSAGE_SELF)
        next_hook = start
        next_probe = start
        round_number = 0
        admissions = collections.Counter()
        session_counts = []
        errors = []
        warmup = 30
        end = start + warmup + seconds
        while time.monotonic() < end:
            now = time.monotonic()
            measured = now >= start + warmup
            if now >= next_hook:
                for index in range(sessions):
                    event = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop")[round_number % 4]
                    payload = json.dumps({"hook_event_name": event, "session_id": f"probe-session-{index}",
                                          "cwd": str(root / "project"), "tool_name": "Read"})
                    disposition = submit_hook_ingress(HookIngressRequest("claude", str(default_state_dir() / "claude.jsonl"), payload))
                    admissions[str(disposition)] += 1
                round_number += 1
                next_hook = now + 5
            if now >= next_probe:
                if measured:
                    rss.append(resident_bytes())
                    if trace:
                        heap.append(tracemalloc.get_traced_memory()[0])
                posted = time.monotonic()
                done = threading.Event()

                def pong(_=None, sent=posted, counted=measured, completed=done):
                    if counted:
                        latency.append((time.monotonic() - sent) * 1000)
                    completed.set()

                box = core_runtime.CoreCallableBox(pong)
                holder[0].performSelectorOnMainThread_withObject_waitUntilDone_("runCoreCallable:", box, False)
                next_probe = now + 1
            if not measured:
                cpu_start = resource.getrusage(resource.RUSAGE_SELF)
            try:
                pending += client.recv(1024 * 1024)
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    frame = json.loads(line)
                    if frame.get("t") == "hello" and "state_slices" in frame.get("capabilities", []):
                        client.sendall(b'{"t":"command","v":1,"id":"probe-subscribe","name":"subscribe","args":{"state_slices":true}}\n')
                    if frame.get("t") == "state":
                        session_counts.append(len(frame.get("sessions", [])))
                    elif frame.get("t") == "state_delta" and "sessions" in frame.get("slices", {}):
                        session_counts.append(len(frame["slices"]["sessions"]["value"] or []))
                    if frame.get("t") == "reply" and frame.get("ok") is False:
                        errors.append(frame.get("error"))
                    if frame.get("t") == "log" and "failed" in str(frame.get("message", "")).lower():
                        errors.append(str(frame.get("message"))[:200])
                    if measured:
                        kind = frame.get("t", "unknown")
                        messages[kind] += 1
                        sizes[kind] += len(line) + 1
            except socket.timeout:
                pass
        cpu_end = resource.getrusage(resource.RUSAGE_SELF)
        cpu_seconds = cpu_end.ru_utime + cpu_end.ru_stime - cpu_start.ru_utime - cpu_start.ru_stime
        loaded = sorted(name for name in sys.modules if name.split(".")[0] in {"AppKit", "Foundation", "WebKit", "Quartz", "objc"})
        report = {"duration_seconds": seconds, "sessions": sessions, "tracing": trace,
                  "cpu_percent": 100 * cpu_seconds / seconds, "cpu_seconds": cpu_seconds,
                  "rss_mean_mb": sum(x for x in rss if x) / len(rss) / 1048576,
                  "rss_max_mb": max(x for x in rss if x) / 1048576,
                  "heap_max_mb": max(heap) / 1048576 if heap else None,
                  "messages_per_minute": {key: value * 60 / seconds for key, value in messages.items()},
                  "bytes_per_minute": {key: value * 60 / seconds for key, value in sizes.items()},
                  "loop_max_ms": max(latency, default=None), "loop_samples": len(latency),
                  "loop_over_250ms": sum(x > 250 for x in latency), "framework_modules": loaded,
                  "hook_admissions": dict(admissions), "max_visible_sessions": max(session_counts, default=0),
                  "errors": errors, "source_sha256": (root / "source-sha256.txt").read_text().strip(),
                  "source_commit": (root / "revision.txt").read_text().strip()}
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        client.close()
        os.kill(os.getpid(), signal.SIGTERM)

    def sampling_thread():
        try:
            sample()
        except BaseException:
            import traceback
            (root / "probe-error.txt").write_text(traceback.format_exc())
            os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=sampling_thread, name="synthetic-workload", daemon=True).start()
    raise SystemExit(core_runtime.run_core(["--socket", str(root / "core.sock")]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--sessions", type=int, choices=range(3, 7), default=3)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    root = args.output.resolve()
    if args.child:
        child(root, args.seconds, args.sessions, args.trace)
        return
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    shutil.copytree(repo / "src", root / "src", ignore=shutil.ignore_patterns("__pycache__"))
    digest = hashlib.sha256()
    for path in sorted((root / "src").rglob("*.py")):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    (root / "source-sha256.txt").write_text(digest.hexdigest() + "\n")
    (root / "revision.txt").write_text(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True))
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("JRBAR_", "SIDEPULSE_")) or key in {"CODEX_HOME", "CLAUDE_CONFIG_DIR", "PYTEST_CURRENT_TEST"}:
            env.pop(key)
    for key, directory in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")):
        (root / directory).mkdir()
        env[key] = str(root / directory)
    env.update(JRBAR_TESTING="1", JRBAR_STATE_DIR=str(root / "state"), PYTHONPATH=str(root / "src"))
    shutil.copyfile(__file__, root / "probe.py")
    command = [sys.executable, "-X", "importtime", str(root / "probe.py"), str(root), "--child", "--seconds", str(args.seconds), "--sessions", str(args.sessions)]
    if args.trace:
        command.append("--trace")
    with (root / "stdout.log").open("w") as out, (root / "importtime.log").open("w") as err:
        result = subprocess.run(command, env=env, stdout=out, stderr=err, timeout=args.seconds + 180, check=False)
    if not (root / "report.json").exists():
        raise SystemExit(f"probe failed ({result.returncode}); inspect {root}")
    print((root / "report.json").read_text())


if __name__ == "__main__":
    main()
