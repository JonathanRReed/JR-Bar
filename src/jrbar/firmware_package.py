"""Getting a firmware package, and trusting it only after it is checked.

The one place JR-Bar fetches firmware. It runs when a person presses
"Download and update" (or runs ``jrbar firmware upgrade``), never in the
background and never to look for news: the app already knows which releases
exist (``device_firmware.RELEASES``), so "is there an update" is answered
offline from what the device reports.

Everything that comes back is untrusted data until it passes, in this order:

1. the request goes to the pinned host over https, with no redirect to
   anywhere else, a size cap and a time cap;
2. the bytes are hashed and compared with the zip hash pinned in the app.
   Nothing is opened before that matches, and the hash is never taken from
   the place that serves the file;
3. the zip's member names are checked (no absolute path, no ``..``, only the
   four expected files, size caps, nothing encrypted or linked);
4. the ``FIRMWARE.BIN`` inside is hashed against its own pinned hash, its size
   is compared, and its first bytes must be the header of the right model.

A package that passes is cached under the app's state directory (private
files), so a retry or a second device needs no new download. The cache is
checked again every time it is used.
"""

from __future__ import annotations

import hashlib
import io
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .device_firmware import (
    IMAGE_FILE_NAME,
    PACKAGE_HOST,
    PACKAGE_MEMBER_NAMES,
    RELEASES,
    FirmwareRelease,
)
from .private_io import atomic_private_write, ensure_private_directory, read_private_bytes

#: No package is larger than this; a bigger download is refused unread.
PACKAGE_MAX_BYTES: Final = 1 << 20
#: The reference files in a package are small text.
REFERENCE_MAX_BYTES: Final = 16 * 1024
DOWNLOAD_TIMEOUT_SECONDS: Final = 20.0
#: The whole download, not one read: a trickling server is cut off.
DOWNLOAD_DEADLINE_SECONDS: Final = 45.0
CACHE_DIRECTORY: Final = "firmware"
_CHUNK: Final = 16 * 1024
_PACKAGE_FILE: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip")
_USER_AGENT: Final = "JR-Bar firmware updater (user-initiated)"


class PackageError(Exception):
    """A package that cannot be trusted, or could not be fetched.

    ``code`` is a short word for programs; ``str(error)`` is a sentence for
    the person and says what happened to the device (nothing was written)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class VerifiedPackage:
    release: FirmwareRelease
    image: bytes
    #: ``download``, ``cache`` or ``file``.
    source: str


Opener = Callable[[urllib.request.Request, float], Any]
Progress = Callable[[int, int | None], None]


# --- verifying ----------------------------------------------------------------


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _member_names(release: FirmwareRelease, names: list[str]) -> dict[str, str]:
    """Map each expected file name to its name in the zip, or refuse.

    Either every file sits in the package's own folder (how upstream builds
    the zip) or every file sits at the top; anything else is refused."""
    for name in names:
        if (
            not name
            or name.startswith(("/", "\\"))
            or "\\" in name
            or "\x00" in name
            or ".." in name.split("/")
            or name.endswith("/")
            or len(name) > 200
        ):
            raise PackageError("bad_member", f"The package holds a file name that is not allowed ({name[:60]!r}).")
    if len(set(names)) != len(names):
        raise PackageError("bad_member", "The package lists the same file twice.")
    for prefix in ("", release.member_folder + "/"):
        expected = {prefix + member: member for member in PACKAGE_MEMBER_NAMES}
        if set(names) == set(expected):
            return {member: prefix + member for member in PACKAGE_MEMBER_NAMES}
    raise PackageError(
        "bad_member",
        "The package does not hold exactly FIRMWARE.BIN, README.txt, RELEASE_NOTES.txt and SHA256SUMS.txt.",
    )


def _read_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    if info.flag_bits & 0x1:
        raise PackageError("bad_member", "The package holds an encrypted file.")
    if info.is_dir() or stat.S_ISLNK(info.external_attr >> 16):
        raise PackageError("bad_member", "The package holds a link or a folder where a file belongs.")
    if info.file_size > limit:
        raise PackageError("too_large", f"{info.filename.rsplit('/', 1)[-1]} is larger than a firmware package should be.")
    with archive.open(info) as member:
        data = member.read(limit + 1)
    if len(data) > limit:
        raise PackageError("too_large", f"{info.filename.rsplit('/', 1)[-1]} is larger than a firmware package should be.")
    return data


def _other_model_magic(release: FirmwareRelease, image: bytes) -> FirmwareRelease | None:
    for other in RELEASES:
        if other.model != release.model and image.startswith(other.image_magic):
            return other
    return None


def verify_package(data: bytes, release: FirmwareRelease) -> bytes:
    """The checked ``FIRMWARE.BIN`` bytes of ``data``, a zip for ``release``.

    Raises ``PackageError`` (nothing has been written anywhere)."""
    if len(data) > PACKAGE_MAX_BYTES:
        raise PackageError("too_large", "The package is larger than a firmware package should be; nothing was used.")
    if _sha256(data) != release.package_sha256:
        raise PackageError(
            "bad_hash",
            f"The package does not match the {release.name} {release.version} package this version of JR-Bar "
            "knows (its checksum differs). Nothing was written to the device.",
        )
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as error:
        raise PackageError("bad_zip", "The package is not a readable zip file.") from error
    with archive:
        infos = archive.infolist()
        names = _member_names(release, [info.filename for info in infos])
        by_name = {info.filename: info for info in infos}
        image = _read_member(archive, by_name[names[IMAGE_FILE_NAME]], release.image_size)
        for member in PACKAGE_MEMBER_NAMES:
            if member != IMAGE_FILE_NAME:
                _read_member(archive, by_name[names[member]], REFERENCE_MAX_BYTES)
    return verify_image(image, release)


def verify_image(image: bytes, release: FirmwareRelease) -> bytes:
    """Check a bare ``FIRMWARE.BIN`` against the pinned size, header and hash."""
    other = _other_model_magic(release, image)
    if other is not None:
        raise PackageError(
            "wrong_model",
            f"This image is for the {other.name}, not the {release.name}. It was not used.",
        )
    if len(image) != release.image_size:
        raise PackageError("bad_size", "FIRMWARE.BIN is not the size this release has. It was not used.")
    if not image.startswith(release.image_magic):
        raise PackageError("bad_header", f"FIRMWARE.BIN does not start like a {release.name} image. It was not used.")
    if _sha256(image) != release.image_sha256:
        raise PackageError("bad_hash", "FIRMWARE.BIN does not match its checksum. It was not used.")
    return image


# --- the cache ------------------------------------------------------------------


def cache_directory(state_dir: Path) -> Path:
    return Path(state_dir) / CACHE_DIRECTORY


def cache_path(state_dir: Path, release: FirmwareRelease) -> Path:
    return cache_directory(state_dir) / release.package_name


def load_cached(state_dir: Path, release: FirmwareRelease) -> VerifiedPackage | None:
    """The cached package, checked again, or ``None`` (a bad one is removed)."""
    path = cache_path(state_dir, release)
    try:
        data = read_private_bytes(path, max_bytes=PACKAGE_MAX_BYTES)
    except (OSError, ValueError):
        return None
    try:
        return VerifiedPackage(release, verify_package(data, release), "cache")
    except PackageError:
        try:
            path.unlink()
        except OSError:
            pass
        return None


def is_cached(state_dir: Path, release: FirmwareRelease) -> bool:
    """Whether a package file is waiting (not re-verified; the update does that)."""
    try:
        return cache_path(state_dir, release).stat().st_size > 0
    except OSError:
        return False


def store_cached(state_dir: Path, release: FirmwareRelease, data: bytes) -> None:
    directory = ensure_private_directory(cache_directory(state_dir))
    atomic_private_write(directory / release.package_name, data)


# --- downloading ----------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PackageError("redirected", "The server tried to send the download somewhere else. Nothing was fetched.")


def _default_opener(request: urllib.request.Request, timeout: float) -> Any:
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler)
    return opener.open(request, timeout=timeout)


def check_package_url(release: FirmwareRelease) -> str:
    """The pinned URL, after making sure it is still the pinned one."""
    url = release.package_url
    parts = urllib.parse.urlsplit(url)
    if (
        parts.scheme != "https"
        or parts.hostname != PACKAGE_HOST
        or parts.port is not None
        or parts.username is not None
        or parts.query
        or parts.fragment
        or parts.path != release.package_path
        or not _PACKAGE_FILE.fullmatch(release.package_name)
        or any(part in ("", ".", "..") for part in parts.path.split("/")[1:])
    ):
        raise PackageError("bad_url", "The pinned download address is not the one JR-Bar allows. Nothing was fetched.")
    return url


def download_package(
    release: FirmwareRelease,
    *,
    opener: Opener | None = None,
    clock: Callable[[], float] = time.monotonic,
    progress: Progress | None = None,
    timeout: float = DOWNLOAD_TIMEOUT_SECONDS,
    deadline_seconds: float = DOWNLOAD_DEADLINE_SECONDS,
    max_bytes: int = PACKAGE_MAX_BYTES,
) -> bytes:
    """Fetch the package bytes (unverified): one GET, https, pinned host only."""
    url = check_package_url(release)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": _USER_AGENT, "Accept": "application/zip, application/octet-stream"},
        method="GET",
    )
    open_url = opener or _default_opener
    started = clock()
    try:
        response = open_url(request, timeout)
    except PackageError:
        raise
    except urllib.error.HTTPError as error:
        raise PackageError("http_error", f"The download server answered {error.code}. Nothing was written to the device.") from error
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        raise PackageError("network", "The download did not reach the server. Check the connection and try again; nothing was written to the device.") from error
    try:
        final = urllib.parse.urlsplit(str(response.geturl()))
        if final.scheme != "https" or final.hostname != PACKAGE_HOST or final.path != release.package_path:
            raise PackageError("redirected", "The download came from somewhere other than the pinned address. It was not used.")
        total: int | None = None
        header = response.headers.get("Content-Length") if getattr(response, "headers", None) else None
        if header is not None:
            try:
                total = int(header)
            except ValueError:
                total = None
        if total is not None and total > max_bytes:
            raise PackageError("too_large", "The download is larger than a firmware package should be. It was not used.")
        data = bytearray()
        while True:
            if clock() - started > deadline_seconds:
                raise PackageError("timeout", "The download took too long and was stopped. Nothing was written to the device.")
            try:
                chunk = response.read(_CHUNK)
            except (OSError, TimeoutError) as error:
                raise PackageError("network", "The download was interrupted. Try again; nothing was written to the device.") from error
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > max_bytes:
                raise PackageError("too_large", "The download is larger than a firmware package should be. It was not used.")
            if progress is not None:
                progress(len(data), total)
        return bytes(data)
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()
