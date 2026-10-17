"""Synthetic CoreFoundation calls only. Never load Security or read a Keychain."""

import ctypes

import pytest

from jrbar import keychain_read as reader


class API:
    def __init__(self, *, status=0, interaction_status=0, payload=b"synthetic-secret"):
        self.status = status
        self.interaction_status = interaction_status
        self.payload = payload
        self.buffer = ctypes.create_string_buffer(payload)
        self.length = len(payload)
        self.events = []
        self.released = []
        self.strings = []
        self.values = None
        self.true = ctypes.c_void_p(10)

    def set_interaction(self, allowed):
        self.events.append(("interaction", allowed))
        return self.interaction_status

    def k_(self, key):
        return {"kSecClassGenericPassword": ctypes.c_void_p(11),
                "kSecMatchLimitOne": ctypes.c_void_p(12),
                "kSecUseAuthenticationUIFail": ctypes.c_void_p(13)}[key]

    def create_cf(self, value):
        self.events.append(("string", value))
        self.strings.append(value)
        return 100 + len(self.strings)

    def create_query(self, **values):
        self.events.append(("query",))
        self.values = values
        return 200

    def SecItemCopyMatching(self, query, output):
        self.events.append(("copy",))
        if self.status == 0:
            ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(300)
        return self.status

    def CFDataGetLength(self, data):
        return self.length

    def CFDataGetBytePtr(self, data):
        self.events.append(("bytes",))
        return ctypes.addressof(self.buffer)

    def release(self, ref):
        self.released.append(ref.value if isinstance(ref, ctypes.c_void_p) else ref)


def test_background_disables_legacy_ui_before_query_and_sets_modern_no_ui():
    api = API()
    assert reader._read_secret("synthetic-service", api=api) == (reader.EXIT_OK, "synthetic-secret")
    assert api.events[0] == ("interaction", False)
    assert api.values["kSecUseAuthenticationUI"].value == 13
    assert api.values["kSecReturnData"] is api.true
    assert isinstance(api.values["kSecAttrService"], ctypes.c_void_p)
    assert "kSecAttrAccount" not in api.values
    assert api.released == [300, 200, 101]


def test_foreground_is_explicit_and_owns_account_and_service_strings():
    api = API()
    assert reader._read_secret("synthetic-service", "synthetic-account", allow_prompt=True, api=api)[0] == 0
    assert not any(event[0] == "interaction" for event in api.events)
    assert "kSecUseAuthenticationUI" not in api.values
    assert api.values["kSecAttrAccount"].value == 102
    assert api.strings == ["synthetic-service", "synthetic-account"]
    assert api.released == [300, 200, 102, 101]


@pytest.mark.parametrize("status,expected", [(-25308, 3), (-128, 3), (-25293, 3), (-25315, 3), (-50, 2)])
def test_interaction_setter_refusal_never_queries(status, expected):
    api = API(interaction_status=status)
    assert reader._read_secret("synthetic-service", api=api) == (expected, None)
    assert api.events == [("interaction", False)]
    assert api.released == []


@pytest.mark.parametrize("status,expected", [(-25300, 1), (-25308, 3), (-128, 3), (-25293, 3), (-25315, 3), (-50, 2)])
def test_query_statuses_are_bounded_and_resources_released(status, expected):
    api = API(status=status)
    assert reader._read_secret("synthetic-service", api=api) == (expected, None)
    assert api.released == [200, 101]


@pytest.mark.parametrize("length", [0, -1, reader.MAX_SECRET_BYTES + 1, 2 ** 40])
def test_invalid_data_bounds_never_access_bytes(length):
    api = API()
    api.length = length
    assert reader._read_secret("synthetic-service", api=api) == (2, None)
    assert ("bytes",) not in api.events
    assert api.released == [300, 200, 101]


def test_maximum_data_size_is_accepted_and_invalid_utf8_is_refused():
    api = API(payload=b"x" * reader.MAX_SECRET_BYTES)
    code, secret = reader._read_secret("synthetic-service", api=api)
    assert code == 0 and len(secret) == reader.MAX_SECRET_BYTES
    assert api.released == [300, 200, 101]
    bad = API(payload=b"\xff")
    assert reader._read_secret("synthetic-service", api=bad) == (2, None)
    assert bad.released == [300, 200, 101]


def test_query_creation_failure_releases_owned_strings():
    api = API()
    api.create_query = lambda **_values: None
    assert reader._read_secret("synthetic-service", "synthetic-account", api=api) == (2, None)
    assert api.released == [102, 101]


def test_exception_after_query_releases_all_owned_resources():
    api = API()

    def refuse(_data):
        raise RuntimeError("synthetic-secret must not become diagnostic output")

    api.CFDataGetLength = refuse
    assert reader._read_secret("synthetic-service", api=api) == (2, None)
    assert api.released == [300, 200, 101]


def test_cli_default_is_no_prompt_and_only_success_has_secret_stdout(monkeypatch, capsys):
    calls = []

    def read(service, account, *, allow_prompt):
        calls.append((service, account, allow_prompt))
        return 0, "synthetic-secret"

    monkeypatch.setattr(reader, "_read_secret", read)
    assert reader.main(["--service", "synthetic-service"]) == 0
    assert calls == [("synthetic-service", None, False)]
    assert capsys.readouterr() == ("synthetic-secret", "")
    assert reader.main(["--service", "synthetic-service", "--account", "synthetic-account", "--allow-prompt"]) == 0
    assert calls[-1] == ("synthetic-service", "synthetic-account", True)


@pytest.mark.parametrize("code", [1, 2, 3])
def test_cli_failures_have_static_output(monkeypatch, capsys, code):
    monkeypatch.setattr(reader, "_read_secret", lambda *_args, **_kwargs: (code, None))
    assert reader.main(["--service", "synthetic-service"]) == code
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err.startswith("keychain ")
    assert "synthetic-service" not in output.err


def test_cli_argument_failure_does_not_echo_values_or_load_api(monkeypatch, capsys):
    monkeypatch.setattr(reader, "_load_api", lambda: pytest.fail("loaded Security"))
    assert reader.main(["--unexpected", "synthetic-secret"]) == 2
    assert capsys.readouterr() == ("", "keychain read unavailable\n")
