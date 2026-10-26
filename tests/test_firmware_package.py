"""Firmware packages are untrusted data until they pass every check.

All packages here are small synthetic zips; the tests never touch the network
(the sandbox forbids it) and never write outside a temporary folder.
"""

from __future__ import annotations

import io
import urllib.error
import urllib.request
import zipfile
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar import firmware_package as package
from jrbar.firmware_package import PackageError
from tests.firmware_fakes import (
    DOT_MAGIC,
    PRO_MAGIC,
    make_image,
    make_release,
    make_zip,
    sha256,
)


def _release(**kwargs):
    return make_release("pro", "1.1.0", **kwargs)


def test_a_good_package_gives_back_its_image() -> None:
    release = _release()
    data = make_zip(release.package_name, make_image("pro"))
    assert package.verify_package(data, release) == make_image("pro")


def test_a_flat_zip_without_the_folder_is_also_accepted() -> None:
    image = make_image("pro")
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", image, folder=False)
    release = make_release("pro", image=image, package=data)
    assert package.verify_package(data, release) == image


def test_the_zip_hash_is_checked_before_the_zip_is_opened(monkeypatch: pytest.MonkeyPatch) -> None:
    release = _release()
    opened: list[object] = []
    monkeypatch.setattr(package.zipfile, "ZipFile", lambda *a, **k: opened.append(a) or None)
    with pytest.raises(PackageError) as caught:
        package.verify_package(b"not the pinned bytes", release)
    assert caught.value.code == "bad_hash"
    assert opened == []


def test_a_package_that_differs_by_one_byte_is_refused() -> None:
    release = _release()
    data = bytearray(make_zip(release.package_name, make_image("pro")))
    data[-30] ^= 0x01
    with pytest.raises(PackageError) as caught:
        package.verify_package(bytes(data), release)
    assert caught.value.code == "bad_hash"


def _pinned(data: bytes, image: bytes, model: str = "pro"):
    return make_release(model, image=image, package=data)


@pytest.mark.parametrize(
    "member",
    ["/etc/FIRMWARE.BIN", "../FIRMWARE.BIN", "sidepulse-pro-1.1.0-ota/../FIRMWARE.BIN", "C:\\FIRMWARE.BIN"],
)
def test_traversal_and_absolute_member_names_are_refused(member: str) -> None:
    image = make_image("pro")
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", image, names={"FIRMWARE.BIN": member})
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, _pinned(data, image))
    assert caught.value.code == "bad_member"


def test_a_package_with_an_extra_or_missing_member_is_refused() -> None:
    image = make_image("pro")
    extra = make_zip("sidepulse-pro-1.1.0-ota.zip", image, extra={"sidepulse-pro-1.1.0-ota/evil.sh": b"x"})
    with pytest.raises(PackageError) as caught:
        package.verify_package(extra, _pinned(extra, image))
    assert caught.value.code == "bad_member"
    missing = make_zip("sidepulse-pro-1.1.0-ota.zip", image, skip=("SHA256SUMS.txt",))
    with pytest.raises(PackageError) as caught:
        package.verify_package(missing, _pinned(missing, image))
    assert caught.value.code == "bad_member"


def test_members_split_between_the_folder_and_the_top_are_refused() -> None:
    image = make_image("pro")
    data = make_zip(
        "sidepulse-pro-1.1.0-ota.zip", image, names={"README.txt": "README.txt"}
    )
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, _pinned(data, image))
    assert caught.value.code == "bad_member"


def test_an_oversize_member_is_refused_before_it_is_read() -> None:
    image = make_image("pro")
    release_image = make_image("pro", size=len(image))
    big = make_image("pro", size=len(image) + 5000)
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", big)
    release = make_release("pro", image=release_image, package=data)
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, release)
    assert caught.value.code == "too_large"


def test_an_oversize_package_is_refused_unread() -> None:
    release = _release()
    with pytest.raises(PackageError) as caught:
        package.verify_package(bytes(package.PACKAGE_MAX_BYTES + 1), release)
    assert caught.value.code == "too_large"


def test_a_package_that_is_not_a_zip_is_refused() -> None:
    data = b"PK\x03\x04 not really"
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, _pinned(data, make_image("pro")))
    assert caught.value.code == "bad_zip"


def test_a_linked_member_is_refused() -> None:
    image = make_image("pro")
    buffer = io.BytesIO()
    prefix = "sidepulse-pro-1.1.0-ota/"
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(prefix + "FIRMWARE.BIN", image)
        for name in ("README.txt", "RELEASE_NOTES.txt"):
            archive.writestr(prefix + name, b"x")
        link = zipfile.ZipInfo(prefix + "SHA256SUMS.txt")
        link.external_attr = (0o120777 << 16)
        archive.writestr(link, "/etc/passwd")
    data = buffer.getvalue()
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, _pinned(data, image))
    assert caught.value.code == "bad_member"


def test_the_image_hash_is_checked_against_its_own_pin() -> None:
    image = make_image("pro")
    other = make_image("pro", fill=9)
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", other)
    release = replace(make_release("pro", image=image, package=data), image_sha256=sha256(image))
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, release)
    assert caught.value.code == "bad_hash"


def test_a_dot_image_is_refused_for_a_pro_release() -> None:
    dot_image = make_image("dot")
    assert dot_image.startswith(DOT_MAGIC)
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", dot_image)
    release = make_release("pro", image=dot_image, package=data)
    release = replace(release, image_magic=PRO_MAGIC)
    # The pins are consistent with the bytes; the header still says Dot.
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, replace(release, image_sha256=sha256(dot_image)))
    assert caught.value.code == "wrong_model"
    assert "SidePulse Dot" in caught.value.message


def test_a_header_of_no_known_model_is_refused() -> None:
    junk = b"ZZZZ" + bytes(2996)
    data = make_zip("sidepulse-pro-1.1.0-ota.zip", junk)
    release = make_release("pro", image=junk, package=data)
    with pytest.raises(PackageError) as caught:
        package.verify_package(data, release)
    assert caught.value.code == "bad_header"


def test_the_real_catalog_pins_what_the_hand_update_verified() -> None:
    from jrbar.device_firmware import RELEASES

    pro = next(item for item in RELEASES if item.model == "pro")
    dot = next(item for item in RELEASES if item.model == "dot")
    assert pro.package_sha256 == "1efc35498f837932938aaf1b3e4f2889549d09cfbf974ae1132cafb7768b6fac"
    assert pro.image_sha256 == "3104ed5b9ebb4e0bd35b2fba3083fe931f5e23d42a322f019a556c31f1a4a1ce"
    assert (pro.image_size, pro.image_magic) == (136_992, b"SDUP")
    assert dot.package_sha256 == "1d82c907dfb945f8714e9021afaf793a161eff13182967bcc5d63ebbc212cdb7"
    assert dot.image_sha256 == "f377f28e90f419ef83e67e352c3b7bd706e33c7e25ae925008c97a93b8afeb05"
    assert (dot.image_size, dot.image_magic) == (57_344, b"UF2\n")
    assert pro.package_url == (
        "https://raw.githubusercontent.com/inteliwear/sidepulse/"
        "6d55225fed20a82521b23d86a4df2c4a15dff295/firmware/v1.1.0/sidepulse-pro-1.1.0-ota.zip"
    )
    for release in RELEASES:
        assert release.member_folder == release.package_name.removesuffix(".zip")
        package.check_package_url(release)


# --- downloading -----------------------------------------------------------------------


class FakeResponse:
    def __init__(self, data: bytes, url: str, *, length: int | None = None, fail_after: int | None = None) -> None:
        self._buffer = io.BytesIO(data)
        self._url = url
        self.headers = {"Content-Length": str(len(data) if length is None else length)}
        self.closed = False
        self._fail_after = fail_after
        self._served = 0

    def geturl(self) -> str:
        return self._url

    def read(self, count: int) -> bytes:
        if self._fail_after is not None and self._served >= self._fail_after:
            raise OSError("connection reset")
        chunk = self._buffer.read(count)
        self._served += len(chunk)
        return chunk

    def close(self) -> None:
        self.closed = True


def _opener(response_factory, requests: list):
    def opener(request: urllib.request.Request, timeout: float):
        requests.append((request.full_url, request.get_method(), timeout, dict(request.header_items())))
        return response_factory(request)

    return opener


def test_a_download_is_one_get_to_the_pinned_https_address() -> None:
    release = _release()
    data = make_zip(release.package_name, make_image("pro"))
    requests: list = []
    progress: list = []
    fetched = package.download_package(
        release,
        opener=_opener(lambda request: FakeResponse(data, request.full_url), requests),
        progress=lambda done, total: progress.append((done, total)),
    )
    assert fetched == data
    [(url, method, timeout, headers)] = requests
    assert url == release.package_url and method == "GET" and timeout > 0
    assert url.startswith("https://raw.githubusercontent.com/")
    assert "Cookie" not in headers and "Authorization" not in headers
    assert progress[-1] == (len(data), len(data))


def test_a_pinned_address_that_is_not_the_allowed_one_is_never_fetched(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    release = _release()
    requests: list = []
    opener = _opener(lambda r: FakeResponse(b"", r.full_url), requests)
    for bad in (
        replace(release, package_dir="firmware/v1.1.0?x=1"),
        replace(release, package_name="../x.zip"),
        replace(release, package_dir="firmware/../../etc"),
        replace(release, package_name="x.zip#frag"),
    ):
        with pytest.raises(PackageError) as caught:
            package.download_package(bad, opener=opener)
        assert caught.value.code == "bad_url"
    from jrbar import device_firmware

    monkeypatch.setattr(device_firmware, "PACKAGE_HOST", "evil.example.com")
    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=opener)
    assert caught.value.code == "bad_url"
    assert requests == []


def test_a_response_from_another_host_is_refused_even_if_the_server_followed_a_redirect() -> None:
    release = _release()
    data = make_zip(release.package_name, make_image("pro"))
    with pytest.raises(PackageError) as caught:
        package.download_package(
            release,
            opener=_opener(lambda r: FakeResponse(data, "https://evil.example.com/x.zip"), []),
        )
    assert caught.value.code == "redirected"


def test_the_default_opener_does_not_follow_redirects() -> None:
    handler = package._NoRedirect()
    with pytest.raises(PackageError) as caught:
        handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example.com/")
    assert caught.value.code == "redirected"


def test_a_download_larger_than_the_cap_is_refused_by_header_and_by_count() -> None:
    release = _release()
    by_header = FakeResponse(b"x" * 10, release.package_url, length=package.PACKAGE_MAX_BYTES + 1)
    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=_opener(lambda r: by_header, []))
    assert caught.value.code == "too_large" and by_header.closed

    lying = FakeResponse(b"x" * (package.PACKAGE_MAX_BYTES + 100), release.package_url, length=5)
    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=_opener(lambda r: lying, []))
    assert caught.value.code == "too_large"


def test_a_slow_download_is_cut_off_on_the_injected_clock() -> None:
    release = _release()
    data = b"y" * 100_000
    ticks = iter(range(0, 1000, 10))
    with pytest.raises(PackageError) as caught:
        package.download_package(
            release,
            opener=_opener(lambda r: FakeResponse(data, r.full_url), []),
            clock=lambda: float(next(ticks)),
            deadline_seconds=25.0,
        )
    assert caught.value.code == "timeout"


def test_network_and_http_failures_say_nothing_was_written() -> None:
    release = _release()

    def refuse(request, timeout):
        raise urllib.error.URLError("offline")

    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=refuse)
    assert caught.value.code == "network" and "nothing was written" in caught.value.message.lower()

    def not_found(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)

    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=not_found)
    assert caught.value.code == "http_error"

    broken = FakeResponse(b"z" * 40_000, release.package_url, fail_after=20_000)
    with pytest.raises(PackageError) as caught:
        package.download_package(release, opener=_opener(lambda r: broken, []))
    assert caught.value.code == "network" and broken.closed


# --- the cache ------------------------------------------------------------------------------


def test_a_cached_package_is_private_and_reused(tmp_path: Path) -> None:
    release = _release()
    data = make_zip(release.package_name, make_image("pro"))
    assert not package.is_cached(tmp_path, release)
    package.store_cached(tmp_path, release, data)
    cached = package.cache_path(tmp_path, release)
    assert cached.read_bytes() == data
    assert cached.stat().st_mode & 0o777 == 0o600
    assert cached.parent.stat().st_mode & 0o777 == 0o700
    assert package.is_cached(tmp_path, release)
    reused = package.load_cached(tmp_path, release)
    assert reused is not None and reused.source == "cache" and reused.image == make_image("pro")


def test_a_tampered_cache_is_checked_again_and_dropped(tmp_path: Path) -> None:
    release = _release()
    data = make_zip(release.package_name, make_image("pro"))
    package.store_cached(tmp_path, release, data)
    path = package.cache_path(tmp_path, release)
    path.write_bytes(data[:100] + bytes([data[100] ^ 0xFF]) + data[101:])
    assert package.load_cached(tmp_path, release) is None
    assert not path.exists()


def test_synthetic_package_bytes_do_not_depend_on_wall_clock(monkeypatch):
    monkeypatch.setattr(zipfile.time, "localtime", lambda *_: (2026, 1, 1, 0, 0, 0, 3, 1, 0))
    first = make_zip("synthetic.zip", make_image())
    monkeypatch.setattr(zipfile.time, "localtime", lambda *_: (2026, 1, 2, 0, 0, 0, 4, 2, 0))
    assert make_zip("synthetic.zip", make_image()) == first
