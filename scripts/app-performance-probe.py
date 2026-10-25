#!/usr/bin/env python3
"""Profile the isolated Swift state-feed test, never an installed app."""
import argparse
import os
import signal
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--render", action="store_true", help="lay out the real panel offscreen after each message")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    app = Path(__file__).resolve().parents[1] / "app"
    env = os.environ.copy()
    env.pop("JRBAR_INTERACTIVE_TESTS", None)
    env["JRBAR_PERF_ISOLATED"] = "1"
    if args.render:
        env["JRBAR_PERF_RENDERED"] = "1"
    command = ["swift", "test", "--skip-build", "--filter", "AppPerformanceTests"]
    for run in range(args.runs):
        for mode in ("legacy", "slices"):
            env["JRBAR_PERF_MODE"] = mode
            log = output / f"feed-{run}-{mode}.log"
            with log.open("w") as stream:
                subprocess.run(command, cwd=app, env=env, stdout=stream,
                               stderr=subprocess.STDOUT, check=True, timeout=600 if args.render else 180)
            for line in log.read_text().splitlines():
                if line.startswith("PERF "):
                    print(line, flush=True)
    if not args.profile:
        return
    os.mkfifo(output / "continue")
    env["JRBAR_PERF_CHECKPOINT_DIR"] = str(output)
    with (output / "profile-feed.log").open("w") as stream:
        process = subprocess.Popen(command, cwd=app, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT)
        target_pid = None
        try:
            for stage in ("warm", "fed"):
                deadline = time.monotonic() + (600 if args.render else 180)
                checkpoint = output / stage
                while not checkpoint.exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"state probe did not reach {stage}")
                    time.sleep(0.1)
                pid = checkpoint.read_text().strip()
                target_pid = int(pid)
                for tool in ("heap", "vmmap", "leaks"):
                    with (output / f"{stage}-{tool}.txt").open("w") as receipt:
                        subprocess.run(["/usr/bin/" + tool, pid], stdout=receipt,
                                       stderr=subprocess.STDOUT, timeout=120, check=False)
                sampler = None
                if stage == "warm":
                    sampler = subprocess.Popen(["/usr/bin/sample", pid, "5", "1", "-file",
                                                str(output / "feed-sample.txt")],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    # Let the profiler attach before this short feed starts.
                    # Profiling runs are separate from the timing runs.
                    time.sleep(2)
                with (output / "continue").open("w") as release:
                    release.write("x")
                if sampler is not None:
                    sampler.wait(timeout=15)
            if process.wait(timeout=180) != 0:
                raise RuntimeError("state probe failed; read profile-feed.log")
        finally:
            if process.poll() is None:
                if target_pid is not None:
                    try:
                        os.kill(target_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
