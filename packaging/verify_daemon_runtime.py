#!/usr/bin/env python3
"""Check loaded images and imports after the frozen daemon's fallback starts."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

from jrbar._packaging_native import NATIVE_STEPS
from jrbar._packaging_probe import FORBIDDEN_MODULES, forbidden_images

CORE_HELPER = Path("Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core")


def check_receipt(receipt):
    errors = []
    if receipt.get("schema") != 2 or receipt.get("frozen") is not True or receipt.get("socket_ready") is not True:
        errors.append("frozen daemon did not open its isolated core socket")
    if receipt.get("doctor_appkit_loaded") is not False:
        errors.append("doctor did not confirm AppKit is absent")
    samples = receipt.get("samples")
    if not isinstance(samples, list) or len(samples) != 4 or any(
        not isinstance(sample, dict) or sample.get("fallback_active") is not True
        or type(sample.get("rss_bytes")) is not int or sample["rss_bytes"] <= 0
        or type(sample.get("elapsed_seconds")) not in (float, int) or sample["elapsed_seconds"] < 6
        for sample in samples
    ):
        errors.append("daemon did not complete four resident-memory samples with its native fallback active")
    images, modules = receipt.get("images"), receipt.get("modules")
    if not isinstance(images, list) or not images or not all(isinstance(name, str) for name in images):
        errors.append("loaded image inventory is missing")
    elif forbidden_images(images):
        errors.append("daemon loaded forbidden images: " + ", ".join(forbidden_images(images)))
    if not isinstance(modules, list) or "jrbar.core_runtime" not in modules or not all(isinstance(name, str) for name in modules):
        errors.append("Python module inventory is missing")
    elif any(name.split(".")[0] in FORBIDDEN_MODULES for name in modules):
        errors.append("daemon imported GUI Python bridges")
    steps = receipt.get("native_steps")
    if (not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps)
            or [step.get("name") for step in steps] != list(NATIVE_STEPS)):
        errors.append("native entry point coverage is missing")
    else:
        for step in steps:
            images, modules = step.get("images"), step.get("modules")
            module = step["name"] if step["name"] == "hid" else "jrbar." + step["name"]
            if (step.get("error") is not None or not isinstance(images, list) or not images
                    or not all(isinstance(name, str) for name in images)
                    or not isinstance(modules, list) or not modules or not all(isinstance(name, str) for name in modules)):
                errors.append(f"native probe failed: {step['name']}")
            elif module not in modules:
                errors.append(f"native probe did not import: {step['name']}")
            elif forbidden_images(images) or any(name.split(".")[0] in FORBIDDEN_MODULES for name in modules):
                errors.append(f"native probe loaded GUI code: {step['name']}")
    return errors


def verify(helper: Path, *, timeout=60):
    helper = helper.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="jrb-headless-", dir="/tmp") as directory:
        root = Path(directory)
        env = {"HOME": directory, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "JRBAR_TESTING": "1",
               "JRBAR_TEST_VOLUME_ROOT": str(root / "Volumes")}
        for variable, leaf in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")):
            path = root / leaf
            path.mkdir(mode=0o700)
            env[variable] = str(path)
        result = subprocess.run([str(helper), "-m", "jrbar._packaging_probe", directory],
                                env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout, check=False)
        receipt = json.loads((root / "runtime.json").read_text())
        receipt["helper_sha256"] = hashlib.sha256(helper.read_bytes()).hexdigest()
        errors = check_receipt(receipt)
        if result.returncode != 0:
            errors.append(f"daemon exited with status {result.returncode}")
        receipt.update(accepted=not errors, errors=errors)
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    try:
        receipt = verify(args.bundle / CORE_HELPER)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        receipt = {"accepted": False, "errors": [f"headless daemon verification failed: {type(error).__name__}"]}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"accepted": receipt["accepted"], "errors": receipt["errors"]}))
    return 0 if receipt["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
