"""Isolated Keychain reader. Background reads cannot enable authentication UI."""

from __future__ import annotations

import argparse
import ctypes
import sys

MAX_SECRET_BYTES = 256 * 1024
EXIT_OK = 0
EXIT_NOT_FOUND = 1
EXIT_UNAVAILABLE = 2
EXIT_INTERACTION_REQUIRED = 3
DENIED_STATUSES = frozenset({-128, -25293, -25308, -25315})


def _load_api():
    # Importing this binding loads Security, so only the isolated CLI does it.
    from keyring.backends.macOS import api
    api.set_interaction = api._sec.SecKeychainSetUserInteractionAllowed
    api.set_interaction.argtypes = (ctypes.c_ubyte,)
    api.set_interaction.restype = ctypes.c_int32
    api.release = api._found.CFRelease
    api.release.argtypes = (ctypes.c_void_p,)
    api.release.restype = None
    api.CFDataGetLength.restype = ctypes.c_ssize_t
    api.true = ctypes.c_void_p.in_dll(api._found, "kCFBooleanTrue")
    return api


def _read_secret(service: str, account: str | None = None, *, allow_prompt: bool = False,
                 api=None) -> tuple[int, str | None]:
    """Return a bounded exit code and secret, with no diagnostic credential data."""
    owned: list[ctypes.c_void_p] = []
    query = None
    data = ctypes.c_void_p()
    try:
        if not service or "\0" in service or (account is not None and "\0" in account):
            return 2, None
        api = _load_api() if api is None else api
        if not allow_prompt:
            status = api.set_interaction(False)
            if status != 0:
                return (3 if status in DENIED_STATUSES else 2), None

        def string(value: str) -> ctypes.c_void_p:
            ref = ctypes.c_void_p(api.create_cf(value))
            if not ref.value:
                raise ValueError
            owned.append(ref)
            return ref

        values = {
            "kSecClass": api.k_("kSecClassGenericPassword"),
            "kSecMatchLimit": api.k_("kSecMatchLimitOne"),
            "kSecAttrService": string(service),
            "kSecReturnData": api.true,
        }
        if account is not None:
            values["kSecAttrAccount"] = string(account)
        if not allow_prompt:
            values["kSecUseAuthenticationUI"] = api.k_("kSecUseAuthenticationUIFail")
        query = api.create_query(**values)
        if not query:
            return 2, None
        status = api.SecItemCopyMatching(query, ctypes.byref(data))
        if status != 0:
            return (1 if status == -25300 else 3 if status in DENIED_STATUSES else 2), None
        if not data.value:
            return 2, None
        length = api.CFDataGetLength(data)
        if not 0 < length <= MAX_SECRET_BYTES:
            return 2, None
        pointer = api.CFDataGetBytePtr(data)
        if not pointer:
            return 2, None
        secret = ctypes.string_at(pointer, length).decode("utf-8")
        return 0, secret
    except Exception:
        return 2, None
    finally:
        if api is not None:
            for ref in [data, query, *reversed(owned)]:
                if ref:
                    try:
                        api.release(ref)
                    except Exception:
                        pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError


def main(argv: list[str] | None = None) -> int:
    parser = _Parser(description="Read one Keychain item in an isolated process.")
    parser.add_argument("--service", required=True)
    parser.add_argument("--account")
    parser.add_argument("--allow-prompt", action="store_true")
    try:
        args = parser.parse_args(argv)
        code, secret = _read_secret(args.service, args.account, allow_prompt=args.allow_prompt)
        if code == 0 and secret is not None:
            sys.stdout.write(secret)
        else:
            sys.stderr.write({1: "keychain item not found\n", 3: "keychain interaction required\n"}
                             .get(code, "keychain read unavailable\n"))
        return code
    except Exception:
        sys.stderr.write("keychain read unavailable\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
