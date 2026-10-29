#!/usr/bin/env python3
"""Copy privacy descriptions without passing text through a command parser."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path


def write_privacy_usage(target: Path, *, key: str | None = None) -> None:
    source = Path(__file__).with_name("privacy_usage.plist")
    descriptions = plistlib.loads(source.read_bytes())
    info = plistlib.loads(target.read_bytes())
    info.update(descriptions if key is None else {key: descriptions[key]})
    target.write_bytes(plistlib.dumps(info, sort_keys=False))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    parser.add_argument("--key")
    args = parser.parse_args()
    write_privacy_usage(args.target, key=args.key)


if __name__ == "__main__":
    main()
