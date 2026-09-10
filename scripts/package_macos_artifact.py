#!/usr/bin/env python3
"""Assemble JR-Bar's macOS PKG artifact.

One component package (``JR-Bar.app`` installed to ``/Applications``, the
reviewed postinstall) wrapped by a product archive whose distribution allows
both a system install (``installer -target /``, needs an administrator) and
a home-directory install (``installer -target CurrentUserHomeDirectory``,
lands in ``~/Applications`` with no password).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

PRODUCT_TITLE = "JR-Bar"


class PackageAssemblyError(RuntimeError):
    """Raised when a package cannot be assembled or verified."""


@dataclass(frozen=True)
class PackageToolchain:
    pkgbuild: Path = Path("/usr/bin/pkgbuild")
    productbuild: Path = Path("/usr/bin/productbuild")
    pkgutil: Path = Path("/usr/sbin/pkgutil")


@dataclass(frozen=True)
class PackageRequest:
    app_path: Path
    scripts_dir: Path
    component_pkg: Path
    output_pkg: Path
    identifier: str
    version: str
    installer_sign_identity: str | None
    toolchain: PackageToolchain = PackageToolchain()


def _require_executable(path: Path, *, label: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise PackageAssemblyError(f"{label} tool is missing or not executable: {path}")


def _bounded_error(stderr: str | None) -> str:
    detail = " ".join((stderr or "").split())
    if not detail:
        return "no diagnostic output"
    return detail[:500]


def _run(stage: str, command: list[str]) -> None:
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except subprocess.CalledProcessError as exc:
        raise PackageAssemblyError(
            f"{stage} failed with exit code {exc.returncode}: {_bounded_error(exc.stderr)}"
        ) from None
    except subprocess.TimeoutExpired:
        raise PackageAssemblyError(f"{stage} timed out after 300 seconds") from None
    except OSError as exc:
        raise PackageAssemblyError(f"{stage} could not start: {exc}") from None
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)


def _validate_request(request: PackageRequest) -> None:
    if not request.app_path.is_dir():
        raise PackageAssemblyError(f"application bundle is missing: {request.app_path}")
    if not request.scripts_dir.is_dir():
        raise PackageAssemblyError(f"package scripts directory is missing: {request.scripts_dir}")
    postinstall = request.scripts_dir / "postinstall"
    if not postinstall.is_file() or not os.access(postinstall, os.X_OK):
        raise PackageAssemblyError(f"postinstall is missing or not executable: {postinstall}")
    if not request.identifier or any(character.isspace() for character in request.identifier):
        raise PackageAssemblyError("package identifier must be a non-empty token")
    if not request.version or any(character.isspace() for character in request.version):
        raise PackageAssemblyError("package version must be a non-empty token")
    if request.component_pkg == request.output_pkg:
        raise PackageAssemblyError("component and output package paths must differ")
    if request.component_pkg.is_dir() or request.output_pkg.is_dir():
        raise PackageAssemblyError("package outputs must not be directories")


def _distribution_document(synthesized: Path, *, component_name: str) -> str:
    """Return the synthesized distribution with the reviewed install domains."""

    try:
        root = ET.fromstring(synthesized.read_bytes())
    except (OSError, ET.ParseError) as exc:
        raise PackageAssemblyError(f"productbuild --synthesize wrote an unreadable distribution: {exc}") from None
    if root.tag != "installer-gui-script":
        raise PackageAssemblyError("synthesized distribution is not an installer-gui-script")
    for stale in root.findall("domains") + root.findall("title") + root.findall("options"):
        root.remove(stale)
    title = ET.Element("title")
    title.text = PRODUCT_TITLE
    root.insert(0, title)
    root.insert(
        1,
        ET.Element(
            "options",
            {"customize": "never", "require-scripts": "false", "hostArchitectures": "arm64"},
        ),
    )
    root.insert(
        2,
        ET.Element(
            "domains",
            {"enable_anywhere": "false", "enable_currentUserHome": "true", "enable_localSystem": "true"},
        ),
    )
    references = [element.get("file") for element in root.iter("pkg-ref") if element.get("file")]
    if references and any(reference != component_name for reference in references):
        raise PackageAssemblyError("synthesized distribution references an unexpected component")
    return ET.tostring(root, encoding="unicode") + "\n"


def assemble_package(request: PackageRequest) -> Path:
    """Build one PKG and verify its installer signature when requested."""

    _validate_request(request)
    _require_executable(request.toolchain.pkgbuild, label="pkgbuild")
    _require_executable(request.toolchain.productbuild, label="productbuild")
    if request.installer_sign_identity:
        _require_executable(request.toolchain.pkgutil, label="pkgutil")

    request.component_pkg.parent.mkdir(parents=True, exist_ok=True)
    request.output_pkg.parent.mkdir(parents=True, exist_ok=True)
    request.component_pkg.unlink(missing_ok=True)
    request.output_pkg.unlink(missing_ok=True)

    _run(
        "pkgbuild",
        [
            str(request.toolchain.pkgbuild),
            "--component",
            str(request.app_path),
            "--install-location",
            "/Applications",
            "--identifier",
            request.identifier,
            "--version",
            request.version,
            "--scripts",
            str(request.scripts_dir),
            str(request.component_pkg),
        ],
    )
    if not request.component_pkg.is_file():
        raise PackageAssemblyError(f"pkgbuild reported success without creating: {request.component_pkg}")

    distribution = request.component_pkg.with_suffix(".dist.xml")
    distribution.unlink(missing_ok=True)
    _run(
        "productbuild --synthesize",
        [
            str(request.toolchain.productbuild),
            "--synthesize",
            "--package",
            str(request.component_pkg),
            str(distribution),
        ],
    )
    if not distribution.is_file():
        raise PackageAssemblyError(f"productbuild --synthesize reported success without creating: {distribution}")
    distribution.write_text(
        _distribution_document(distribution, component_name=request.component_pkg.name),
        encoding="utf-8",
    )

    product_command = [
        str(request.toolchain.productbuild),
        "--distribution",
        str(distribution),
        "--package-path",
        str(request.component_pkg.parent),
    ]
    if request.installer_sign_identity:
        product_command.extend(["--sign", request.installer_sign_identity, "--timestamp"])
    product_command.append(str(request.output_pkg))
    _run("productbuild", product_command)
    if not request.output_pkg.is_file():
        raise PackageAssemblyError(f"productbuild reported success without creating: {request.output_pkg}")

    if request.installer_sign_identity:
        _run(
            "pkgutil signature verification",
            [
                str(request.toolchain.pkgutil),
                "--check-signature",
                str(request.output_pkg),
            ],
        )
    return request.output_pkg


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--scripts", type=Path, required=True)
    parser.add_argument("--component-pkg", type=Path, required=True)
    parser.add_argument("--output-pkg", type=Path, required=True)
    parser.add_argument("--identifier", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--installer-sign-identity")
    args = parser.parse_args()

    try:
        output = assemble_package(
            PackageRequest(
                app_path=args.app,
                scripts_dir=args.scripts,
                component_pkg=args.component_pkg,
                output_pkg=args.output_pkg,
                identifier=args.identifier,
                version=args.version,
                installer_sign_identity=args.installer_sign_identity,
            )
        )
    except PackageAssemblyError as exc:
        print(f"macOS package assembly failed: {exc}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
