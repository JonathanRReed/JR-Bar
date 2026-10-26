#!/usr/bin/env python3
"""Build the pinned HID backend without its AppKit version-number lookup."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

VERSION = "0.14.0.post4"
SOURCE_SHA256 = "48fce253e526d17b663fbf9989c71c7ef7653ced5f4be65f1437c313fb3dbdf6"
SOURCE_URL = f"https://files.pythonhosted.org/packages/source/h/hidapi/hidapi-{VERSION}.tar.gz"


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise ValueError(f"unexpected HID source in {path.name}")
    path.write_text(source.replace(old, new))


def build(archive: Path, output: Path):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise ValueError("HID source SHA-256 mismatch")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jrb-hid-build-") as directory:
        root = Path(directory)
        with tarfile.open(archive) as source:
            source.extractall(root, filter="data")
        source = root / f"hidapi-{VERSION}"
        native = source / "hidapi/mac/hid.c"
        replace_once(native, "/* As defined in AppKit.h, but we don't need the entire AppKit for a single constant. */\n"
                     "extern const double NSAppKitVersionNumber;", "")
        replace_once(native, "is_macos_10_10_or_greater = (NSAppKitVersionNumber >= 1343); /* NSAppKitVersionNumber10_10 */",
                     "if (__builtin_available(macOS 10.10, *)) {\n"
                     "\t\t\tis_macos_10_10_or_greater = 1;\n\t\t} else {\n"
                     "\t\t\tis_macos_10_10_or_greater = 0;\n\t\t}")
        setup = source / "setup.py"
        # The sdist includes Cython's generated C, so no new build dependency
        # or regeneration of the Python binding is needed.
        replace_once(setup, "from Cython.Build import cythonize", "")
        replace_once(setup, 'sources=["hid.pyx", hidapi_src("mac")]', 'sources=["hid.c", hidapi_src("mac")]')
        replace_once(setup, '                    "-framework",\n                    "AppKit",\n', "")
        replace_once(setup, "ext_modules=cythonize(modules, language_level=3)", "ext_modules=modules")
        subprocess.run([sys.executable, "setup.py", "bdist_wheel", "--dist-dir", str(output)],
                       cwd=source, check=True, timeout=180)
    wheels = list(output.glob(f"hidapi-{VERSION}-*.whl"))
    if len(wheels) != 1:
        raise ValueError("HID build must produce exactly one wheel")
    (output / "headless-hidapi.json").write_text(json.dumps({
        "version": VERSION, "source_sha256": SOURCE_SHA256,
        "builder_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "wheel": wheels[0].name, "wheel_sha256": hashlib.sha256(wheels[0].read_bytes()).hexdigest(),
    }, indent=2) + "\n")
    return wheels[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="jrb-hid-source-") as directory:
        archive = args.source
        if archive is None:
            archive = Path(directory) / "hidapi.tar.gz"
            with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
                archive.write_bytes(response.read(16 * 1024 * 1024 + 1))
        print(build(archive, args.output))


if __name__ == "__main__":
    main()
