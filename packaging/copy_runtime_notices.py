#!/usr/bin/env python3
"""Copy the build interpreter's runtime notices into the app bundle."""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import importlib.metadata
import io
import json
import platform
import re
import shutil
import sysconfig
from pathlib import Path

STATIC_PROFILE = Path(__file__).parent / "licenses/python-build-standalone-20260602.json"
STATIC_DIRECTORY = STATIC_PROFILE.with_suffix("")

PYOBJC_VERSION = "12.2.1"
PYOBJC_SHA256 = "0ca04b07928d4872b9d9bb22187ca0426dd8bfab08f26eada0999a71dc81aaff"
PYOBJC_SOURCE = (
    "https://raw.githubusercontent.com/ronaldoussoren/pyobjc/"
    "cb525f3e7f433c851b68725dea54bc70d35681b8/pyobjc-core/License.txt"
)


def runtime_text_identity() -> dict | None:
    """Read the library selected by the build's PyInstaller, without native tools."""
    try:
        from macholib.MachO import MachO
        from PyInstaller.depend.bindepend import get_python_library_path

        library = get_python_library_path()
        if library is None:
            return None
        binary = MachO(str(library))
        if len(binary.headers) != 1 or binary.headers[0].header.cputype != 0x0100000C:
            return None
        sections = {}
        with open(library, "rb") as stream:
            for _, command, entries in binary.headers[0].commands:
                if getattr(command, "segname", b"").rstrip(b"\0") != b"__TEXT":
                    continue
                for section in entries:
                    name = section.sectname.rstrip(b"\0").decode("ascii")
                    if name in sections:
                        return None
                    stream.seek(section.offset)
                    data = stream.read(section.size)
                    if len(data) != section.size:
                        return None
                    sections[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        return sections or None
    except Exception:
        # Native parsing is optional evidence; source profile errors still fail below.
        return None


def static_notices(profile_path: Path, notice_directory: Path) -> tuple[dict, list]:
    """Validate reviewed source material before creating any output."""
    try:
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        if profile["schema"] != 1:
            raise ValueError("unsupported schema")
        for key in ("python_version", "target_triple", "build_release", "build_options", "source_url"):
            if not isinstance(profile[key], str) or not profile[key]:
                raise ValueError(f"invalid {key}")
        hashes = [profile["archive_sha256"], profile["source_manifest_sha256"]]
        sections = profile["text_sections"]
        if not isinstance(sections, dict) or not sections:
            raise ValueError("missing text sections")
        for name, identity in sections.items():
            if not isinstance(name, str) or not name or type(identity["bytes"]) is not int or identity["bytes"] < 0:
                raise ValueError("invalid text section")
            hashes.append(identity["sha256"])
        records = profile["notices"]
        if not isinstance(records, list) or not records:
            raise ValueError("missing notices")
        files, contents = set(), []
        for record in records:
            name = record["file"]
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or name in files:
                raise ValueError("unsafe or duplicate notice filename")
            files.add(name)
            for key in ("extensions", "libraries", "licenses"):
                if not isinstance(record[key], list) or not all(isinstance(item, str) and item for item in record[key]):
                    raise ValueError(f"invalid notice {key}")
            hashes.append(record["sha256"])
            data = (notice_directory / name).read_bytes()
            if not data.strip() or hashlib.sha256(data).hexdigest() != record["sha256"]:
                raise ValueError(f"notice SHA256 does not match: {name}")
            contents.append((name, data))
        if not all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes):
            raise ValueError("invalid SHA256")
        return profile, contents
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"Invalid reviewed static runtime profile: {error}") from error


VENDOR_FOLDER = "setuptools-vendored"


def vendor_notices(root: Path, parent_version: str) -> tuple[dict, list]:
    """Read notices supplied with setuptools, without claiming runtime membership."""
    safe_component = r"[A-Za-z0-9][A-Za-z0-9._+-]*"
    safe_version = r"[0-9][A-Za-z0-9.!+_-]*"
    if not isinstance(parent_version, str) or not re.fullmatch(safe_version, parent_version):
        raise ValueError("Invalid setuptools version")
    manifest = {
        "parent": "setuptools", "parent_version": parent_version,
        "source": "setuptools/_vendor",
        "scope": "Notices supplied with setuptools; runtime membership is unverified.",
        "runtime_membership": "unverified", "distributions": [],
    }
    if not root.exists():
        manifest["state"] = "not_present"
        return manifest, []
    if not root.is_dir():
        raise ValueError("setuptools vendor root is not a directory")
    root = root.resolve(strict=True)
    contents, names, destinations = [], set(), set()
    try:
        for distribution in importlib.metadata.distributions(path=[str(root)]):
            name, version = distribution.metadata["Name"], distribution.version
            if (not isinstance(name, str) or not re.fullmatch(safe_component, name)
                    or not isinstance(version, str) or not re.fullmatch(safe_version, version)):
                raise ValueError("Unsafe vendor name or version")
            normalized = re.sub(r"[-_.]+", "-", name).lower()
            if normalized in names:
                raise ValueError("Duplicate vendor distribution")
            names.add(normalized)
            record = {"name": name, "version": version, "notices": []}
            inventory = distribution.read_text("RECORD")
            if inventory is None:
                raise ValueError("Vendor distribution has no RECORD")
            referenced_notices = set()
            inventory_paths = set()
            for row in csv.reader(io.StringIO(inventory)):
                if len(row) != 3:
                    raise ValueError("Invalid vendor RECORD row")
                source = row[0]
                source_path = Path(source)
                if not re.match(r"^(LICENSE|COPYING|NOTICE|COPYRIGHT)(?:[._-].*)?$", source_path.name, re.I):
                    continue
                if (source_path.is_absolute() or ".." in source_path.parts or "\\" in source
                        or any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._+-]*", part)
                               or part in (".", "..") for part in source.split("/"))):
                    raise ValueError("Unsafe vendor file path")
                if source.casefold() in inventory_paths:
                    raise ValueError("Duplicate vendor file path")
                inventory_paths.add(source.casefold())
                referenced_notices.add(source)
            files = distribution.files
            if files is None:
                raise ValueError("Vendor distribution has no file inventory")
            sources = set()
            for file in files:
                source = str(file)
                if not re.match(r"^(LICENSE|COPYING|NOTICE|COPYRIGHT)(?:[._-].*)?$", file.name, re.I):
                    continue
                if (file.is_absolute() or ".." in file.parts or "\\" in source
                        or any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._+-]*", part)
                               or part in (".", "..") for part in source.split("/"))):
                    raise ValueError("Unsafe vendor file path")
                if source.casefold() in sources:
                    raise ValueError("Duplicate vendor file path")
                sources.add(source.casefold())
                path = Path(distribution.locate_file(file)).resolve(strict=True)
                if not path.is_relative_to(root) or path == root:
                    raise ValueError("Vendor notice escapes vendor root")
                data = path.read_bytes()
                if not data.strip():
                    raise ValueError("Vendor notice is empty")
                identity = file.hash
                if identity is None or identity.mode != "sha256" or file.size is None:
                    raise ValueError("Vendor notice lacks RECORD identity")
                digest = hashlib.sha256(data).digest()
                encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
                if encoded != identity.value or len(data) != file.size:
                    raise ValueError("Vendor notice does not match RECORD")
                destination = f"{VENDOR_FOLDER}/{name}-{version}/{source}"
                if destination.casefold() in destinations:
                    raise ValueError("Duplicate vendor notice destination")
                destinations.add(destination.casefold())
                record["notices"].append({
                    "file": destination, "source": f"setuptools/_vendor/{source}",
                    "sha256": digest.hex(), "bytes": len(data),
                })
                contents.append((destination, data))
            copied_sources = {item["source"].removeprefix("setuptools/_vendor/") for item in record["notices"]}
            if copied_sources != referenced_notices:
                raise ValueError("Referenced vendor notice is missing")
            record["notices"].sort(key=lambda item: item["file"])
            record["notice_state"] = "supplied" if record["notices"] else "missing"
            manifest["distributions"].append(record)
    except (OSError, KeyError, TypeError, AttributeError, csv.Error) as error:
        raise ValueError("Cannot validate setuptools vendor notices") from error
    manifest["distributions"].sort(key=lambda item: (item["name"].casefold(), item["version"]))
    manifest["state"] = "supplied" if names else "unverified"
    return manifest, sorted(contents)


def copy_notices(
    output: Path, runtime_license: Path, python_version: str,
    core_license: Path, core_version: str, *,
    runtime_text_sections: dict | None = None,
    vendor_root: Path | None = None, parent_version: str | None = None,
    profile_path: Path = STATIC_PROFILE, notice_directory: Path = STATIC_DIRECTORY,
) -> None:
    if not re.fullmatch(r"\d+\.\d+\.\d+", python_version):
        raise ValueError(f"Unknown Python runtime version: {python_version!r}")
    if core_version != PYOBJC_VERSION:
        raise ValueError(
            f"pyobjc-core {core_version!r} has no reviewed notice; expected {PYOBJC_VERSION}"
        )
    try:
        python_bytes = runtime_license.read_bytes()
    except OSError as error:
        raise ValueError("Cannot read build interpreter stdlib/LICENSE.txt") from error
    if not python_bytes.strip():
        raise ValueError("Build interpreter stdlib/LICENSE.txt is empty")
    try:
        core_bytes = core_license.read_bytes()
    except OSError as error:
        raise ValueError("Cannot read reviewed pyobjc-core license") from error
    core_hash = hashlib.sha256(core_bytes).hexdigest()
    if core_hash != PYOBJC_SHA256:
        raise ValueError("Reviewed pyobjc-core license SHA256 does not match")
    profile, static_contents = static_notices(profile_path, notice_directory)
    matched = python_version == profile["python_version"] and runtime_text_sections == profile["text_sections"]
    static_runtime = {"state": "unverified", "reason": (
        "runtime_identity_unavailable" if runtime_text_sections is None else "runtime_profile_mismatch"
    )}
    static_folder = "python-build-standalone-20260602"
    if matched:
        static_runtime = {key: profile[key] for key in (
            "python_version", "target_triple", "build_release", "build_options", "source_url",
            "archive_sha256", "source_manifest_sha256", "text_sections",
        )}
        static_runtime["state"] = "matched"
        static_runtime["notices"] = [
            {**record, "file": f"{static_folder}/{record['file']}"}
            for record in profile["notices"]
        ]
    components = [
        {
            "component": "Python", "version": python_version, "file": "Python.txt",
            "sha256": hashlib.sha256(python_bytes).hexdigest(),
            "source": "build interpreter stdlib/LICENSE.txt",
        },
        {
            "component": "pyobjc-core", "version": core_version,
            "file": "PyObjC-core.txt", "sha256": core_hash, "source": PYOBJC_SOURCE,
        },
    ]
    manifest_data = {"components": components, "static_runtime": static_runtime}
    vendor_contents = []
    if vendor_root is not None:
        vendor_manifest, vendor_contents = vendor_notices(vendor_root, parent_version)
        manifest_data["setuptools_vendored"] = vendor_manifest
    manifest = json.dumps(manifest_data, indent=2, sort_keys=True) + "\n"
    output.mkdir(parents=True, exist_ok=True)
    if (output / static_folder).exists():
        shutil.rmtree(output / static_folder)
    if matched:
        (output / static_folder).mkdir(exist_ok=True)
        for name, data in static_contents:
            (output / static_folder / name).write_bytes(data)
    vendor_output = output / VENDOR_FOLDER
    if vendor_output.is_symlink():
        vendor_output.unlink()
    elif vendor_output.exists():
        shutil.rmtree(vendor_output)
    for name, data in vendor_contents:
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (output / "Python.txt").write_bytes(python_bytes)
    (output / "PyObjC-core.txt").write_bytes(core_bytes)
    (output / "runtime-notices.json").write_text(manifest, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        core_version = importlib.metadata.version("pyobjc-core")
        setuptools = importlib.metadata.distribution("setuptools")
        copy_notices(
            args.output, Path(sysconfig.get_path("stdlib")) / "LICENSE.txt",
            platform.python_version(),
            Path(__file__).parent / "licenses/pyobjc-core-12.2.1.txt", core_version,
            runtime_text_sections=runtime_text_identity(),
            vendor_root=Path(setuptools.locate_file("setuptools/_vendor")),
            parent_version=setuptools.version,
        )
    except (ValueError, importlib.metadata.PackageNotFoundError) as error:
        parser.exit(2, f"Runtime notices: {error}\n")


if __name__ == "__main__":
    main()
