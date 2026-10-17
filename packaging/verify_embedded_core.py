#!/usr/bin/env python3
"""Compare all bundled JR-Bar Python code with source without running the helper."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import marshal
import struct
import sys
import types
import zlib
from pathlib import Path

COOKIE_MAGIC = b"MEI\x0c\x0b\x0a\x0b\x0e"
COOKIE = struct.Struct("!8sIIII64s")
TOC_ENTRY = struct.Struct("!IIIIBc")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def semantic(value):
    """Ignore build paths and line tables, retaining executable code and constants."""
    if isinstance(value, types.CodeType):
        fields = (
            "co_name", "co_qualname", "co_argcount", "co_posonlyargcount",
            "co_kwonlyargcount", "co_nlocals", "co_stacksize", "co_flags",
            "co_code", "co_names", "co_varnames", "co_freevars", "co_cellvars",
            "co_exceptiontable",
        )
        return ("code", tuple(getattr(value, field) for field in fields),
                tuple(semantic(item) for item in value.co_consts))
    if isinstance(value, tuple):
        return ("tuple", tuple(semantic(item) for item in value))
    if isinstance(value, frozenset):
        return ("frozenset", tuple(sorted((semantic(item) for item in value), key=repr)))
    return (type(value).__name__, value)


def read_archive(binary: bytes) -> dict[str, tuple[bytes, bytes]]:
    cookie_offset = binary.rfind(COOKIE_MAGIC)
    if cookie_offset < 0 or cookie_offset + COOKIE.size > len(binary):
        raise ValueError("PyInstaller cookie not found")
    magic, size, toc_offset, toc_size, python_version, _ = COOKIE.unpack_from(binary, cookie_offset)
    if magic != COOKIE_MAGIC or python_version != sys.version_info.major * 100 + sys.version_info.minor:
        raise ValueError("Embedded Python version differs from this interpreter")
    start = cookie_offset + COOKIE.size - size
    position, end = start + toc_offset, start + toc_offset + toc_size
    if start < 0 or position < start or end != cookie_offset:
        raise ValueError("Invalid archive bounds")
    entries = {}
    while position < end:
        if position + TOC_ENTRY.size > end:
            raise ValueError("Truncated archive table")
        length, offset, compressed_size, raw_size, compressed, kind = TOC_ENTRY.unpack_from(binary, position)
        if length <= TOC_ENTRY.size or position + length > end or compressed not in (0, 1):
            raise ValueError("Invalid archive table entry")
        raw_name = binary[position + TOC_ENTRY.size:position + length]
        if b"\0" not in raw_name:
            raise ValueError("Unterminated archive member name")
        name = raw_name.split(b"\0", 1)[0].decode("utf-8")
        if start + offset + compressed_size > start + toc_offset:
            raise ValueError("Invalid archive member bounds")
        # Options may repeat; only code and PYZ members are relevant here.
        if kind in (b"z", b"s", b"m", b"M"):
            if name in entries:
                raise ValueError("Duplicate archive code member")
            payload = binary[start + offset:start + offset + compressed_size]
            if compressed:
                payload = zlib.decompress(payload)
            if len(payload) != raw_size:
                raise ValueError("Archive member size differs from its table")
            entries[name] = (kind, payload)
        position += length
    return entries


def read_pyz(entries: dict[str, tuple[bytes, bytes]]) -> dict[str, tuple[int, types.CodeType | None]]:
    archives = [payload for kind, payload in entries.values() if kind == b"z"]
    if len(archives) != 1:
        raise ValueError("Expected one PYZ archive")
    pyz = archives[0]
    if len(pyz) < 12 or pyz[:4] != b"PYZ\0" or pyz[4:8] != importlib.util.MAGIC_NUMBER:
        raise ValueError("Missing PYZ or incompatible bytecode magic")
    toc_position = struct.unpack_from("!i", pyz, 8)[0]
    if not 12 <= toc_position < len(pyz):
        raise ValueError("Invalid PYZ table offset")
    table = marshal.loads(pyz[toc_position:])
    if isinstance(table, dict):
        table = list(table.items())
    if not isinstance(table, list):
        raise ValueError("Invalid PYZ table")
    modules = {}
    for name, (kind, offset, size) in table:
        if not isinstance(name, str) or name in modules:
            raise ValueError("Invalid or duplicate PYZ module")
        if not (name == "jrbar" or name.startswith("jrbar.")):
            continue
        if kind not in (0, 1, 3) or offset < 12 or size < 0 or offset + size > toc_position:
            raise ValueError("Invalid JR-Bar module entry")
        code = None if kind == 3 else marshal.loads(zlib.decompress(pyz[offset:offset + size]))
        if kind != 3 and not isinstance(code, types.CodeType):
            raise ValueError("Embedded module is not Python code")
        modules[name] = (kind, code)
    return modules


def source_modules(source_root: Path) -> dict[str, tuple[int, Path]]:
    package = source_root / "jrbar"
    if not (package / "__init__.py").is_file():
        raise ValueError("Missing JR-Bar source package")
    modules = {}
    for path in sorted(package.rglob("*.py")):
        relative = path.relative_to(source_root).with_suffix("")
        parts = relative.parts[:-1] if path.name == "__init__.py" else relative.parts
        if any(not part.isidentifier() for part in parts):
            raise ValueError("Invalid source module name")
        name = ".".join(parts)
        if name in modules:
            raise ValueError("Ambiguous source module")
        modules[name] = (int(path.name == "__init__.py"), path)
    return modules


def compare(code: types.CodeType, source_path: Path) -> dict:
    source = source_path.read_bytes()
    current = compile(source, code.co_filename, "exec", dont_inherit=True, optimize=0)
    embedded_semantic, source_semantic = semantic(code), semantic(current)
    return {
        "matched": embedded_semantic == source_semantic,
        "source_sha256": digest(source),
        "embedded_semantic_sha256": digest(repr(embedded_semantic).encode()),
        "source_semantic_sha256": digest(repr(source_semantic).encode()),
    }


def verify(binary_path: Path, source_root: Path) -> dict:
    receipt = {"schema": 2, "python": sys.version.split()[0], "matched": False, "modules": {}}
    try:
        binary = binary_path.read_bytes()
        receipt["helper_sha256"] = digest(binary)
        entries = read_archive(binary)
        if any(name == "jrbar" or name.startswith("jrbar.") for name in entries):
            raise ValueError("JR-Bar modules outside PYZ are not covered by this build contract")
        embedded = read_pyz(entries)
        sources = source_modules(source_root)
        receipt["expected_modules"] = len(sources)
        receipt["missing_modules"] = sorted(sources.keys() - embedded.keys())
        receipt["unexpected_modules"] = sorted(embedded.keys() - sources.keys())
        for name in sorted(sources.keys() & embedded.keys()):
            source_kind, source_path = sources[name]
            embedded_kind, code = embedded[name]
            if source_kind != embedded_kind or code is None:
                receipt["modules"][name] = {"matched": False, "error": "Module type differs from source"}
            else:
                receipt["modules"][name] = compare(code, source_path)
        # The build's entry script is stored in CArchive, separately from PYZ.
        entry_kind, entry_payload = entries["jrbar_entry"]
        if entry_kind != b"s":
            raise ValueError("Missing JR-Bar entry script")
        entry_code = marshal.loads(entry_payload)
        if not isinstance(entry_code, types.CodeType):
            raise ValueError("Entry script is not Python code")
        receipt["entry_point"] = compare(entry_code, source_root.parent / "packaging/jrbar_entry.py")
        receipt["matched"] = bool(sources) and (
            not receipt["missing_modules"] and not receipt["unexpected_modules"]
            and all(result["matched"] for result in receipt["modules"].values())
            and receipt["entry_point"]["matched"]
        )
    except Exception as error:
        receipt["error_type"] = type(error).__name__
        # Do not print syntax-error contents or arbitrary embedded constants.
        receipt["error"] = "Archive or source verification failed"
    return receipt


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: verify_embedded_core.py HELPER_BINARY SOURCE_ROOT RECEIPT_JSON", file=sys.stderr)
        return 2
    binary_path, source_root, receipt_path = map(Path, sys.argv[1:])
    receipt = verify(binary_path, source_root)
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"matched": receipt["matched"], "checked_modules": len(receipt["modules"]),
                      "missing_modules": receipt.get("missing_modules", []),
                      "unexpected_modules": receipt.get("unexpected_modules", []),
                      "error_type": receipt.get("error_type")}))
    return 0 if receipt["matched"] else 1


if __name__ == "__main__":
    sys.exit(main())
