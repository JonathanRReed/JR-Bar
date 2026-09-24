"""CLIProxyAPI as a usage hub, off by default and loopback only.

CLIProxyAPI (router-for-me/CLIProxyAPI, MIT) signs in to Claude and Codex
accounts and proxies requests for them. Its management API can list those
accounts (``GET /v0/management/auth-files``) and make a request on an
account's behalf with the account's own token filled in by the proxy
(``POST /v0/management/api-call`` with ``Authorization: Bearer $TOKEN$``).
T3 Code (MIT) reads usage this way; this is our own implementation of the
same idea, so an account only the proxy signs in to still gets a card.

What it will and will not do:

- it runs only while ``cliproxy_hub.enabled`` is on, against a loopback
  URL (anything else is refused before a connection is made), at most
  once per ``min_interval_seconds`` (five minutes or more);
- the management key lives in the Keychain
  (``jrbar providers credential set cliproxy management --stdin``), never
  in settings; without it the hub says so and asks for nothing;
- it calls ``auth-files``, ``api-call`` and, on CLIProxyAPI 7.3 or later,
  the read-only ``quota/providers`` and ``quota/fetch``. It never calls
  ``reset-quota``, ``quota/reset`` or a reset-credit ``consume``: those
  change the person's quota, and ``_management`` refuses them outright;
- a hub account that is the same account this Mac already reads (the
  same Codex account id, the same Claude email) is left out, so nothing
  is counted twice;
- lanes come from our own parsers, so only the known 5-hour and weekly
  windows can drive the lights; everything else is detail.

Each hub account becomes a snapshot under its provider with the instance
``cliproxy:<first 12 hex of sha256(auth_index)>``.
"""

from __future__ import annotations

import hashlib
import json
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane
from .usage_source_settings import normalize_cliproxy_hub

HUB_SOURCE_ID = "cliproxy"
KEYCHAIN_PROVIDER = "cliproxy"
KEYCHAIN_ACCOUNT = "management"
MANAGEMENT_PREFIX = "/v0/management/"
#: The only management paths the hub may touch.
ALLOWED_PATHS = frozenset({"auth-files", "api-call", "quota/providers", "quota/fetch"})
#: Words that mark a quota-changing request inside an api-call URL
#: (redeeming a Codex reset credit is ``.../rate-limit-reset-credits/consume``;
#: listing the credits is a plain read and allowed).
_FORBIDDEN_WORDS = ("consume", "reset-quota", "quota/reset")
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CODEX_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
HUB_TIMEOUT_SECONDS = 15.0
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ACCOUNTS = 16
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
#: CLIProxyAPI's names for providers JR-Bar knows, for the quota API.
_QUOTA_PROVIDER_IDS = {"gemini": "gemini", "gemini-cli": "gemini", "antigravity": "antigravity"}


class HubError(RuntimeError):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = int(status)
        self.reason = reason


def validated_hub_url(value: object) -> str | None:
    """The hub's base URL when it is plain http(s) on this Mac; else None."""
    if not isinstance(value, str) or not value.strip():
        return None
    parsed = urlparse(value.strip())
    if (
        parsed.scheme not in {"http", "https"}
        or parsed.hostname not in _LOOPBACK_HOSTS
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        return None
    return value.strip().rstrip("/")


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HubError(code, "redirect_refused")


def _default_transport(method: str, url: str, *, headers: dict[str, str], body: object, timeout: float) -> object:
    payload = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = Request(url, data=payload, headers={"Accept": "application/json", **headers}, method=method)
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    opener = build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            data = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        raise HubError(error.code, "http_error") from None
    except (URLError, OSError, TimeoutError, ValueError):
        raise HubError(0, "network_error") from None
    if len(data) > MAX_RESPONSE_BYTES:
        raise HubError(200, "response_too_large")
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise HubError(200, "invalid_json") from None


def _forbidden(text: str) -> bool:
    lowered = text.lower()
    return any(word in lowered for word in _FORBIDDEN_WORDS)


def instance_for(auth_index: str) -> str:
    return "cliproxy:" + hashlib.sha256(auth_index.encode("utf-8")).hexdigest()[:12]


@dataclass(frozen=True, slots=True)
class HubAccount:
    auth_index: str
    provider: str
    email: str | None
    chatgpt_account_id: str | None
    plan: str | None

    @property
    def instance(self) -> str:
        return instance_for(self.auth_index)


class HubClient:
    """The management API, with the refusals built in."""

    def __init__(self, base_url: str, key: str, *, transport=_default_transport) -> None:
        self.base_url = base_url
        self._key = key
        self._transport = transport

    def _management(self, method: str, path: str, body: object = None) -> object:
        if path not in ALLOWED_PATHS or "reset" in path:
            raise HubError(0, "path_refused")
        return self._transport(
            method,
            f"{self.base_url}{MANAGEMENT_PREFIX}{path}",
            headers={"Authorization": f"Bearer {self._key}"},
            body=body,
            timeout=HUB_TIMEOUT_SECONDS,
        )

    def accounts(self) -> list[HubAccount]:
        document = self._management("GET", "auth-files")
        files = document.get("files") if isinstance(document, dict) else None
        if not isinstance(files, list):
            raise HubError(200, "invalid_auth_files")
        accounts = []
        for item in files[:256]:
            if not isinstance(item, dict) or item.get("disabled") is True:
                continue
            index = item.get("auth_index", item.get("authIndex"))
            provider = item.get("provider")
            if not isinstance(index, str) or not index or not isinstance(provider, str):
                continue
            token = item.get("id_token") if isinstance(item.get("id_token"), dict) else {}
            email = item.get("email")
            accounts.append(
                HubAccount(
                    index,
                    provider.strip().lower(),
                    email.strip() if isinstance(email, str) and email.strip() else None,
                    token.get("chatgpt_account_id") if isinstance(token.get("chatgpt_account_id"), str) else None,
                    token.get("chatgpt_plan_type") if isinstance(token.get("chatgpt_plan_type"), str) else None,
                )
            )
        return accounts

    def api_call(self, account: HubAccount, url: str) -> tuple[int, str]:
        """A GET on the account's behalf; the proxy fills in its token."""
        if _forbidden(url):
            raise HubError(0, "path_refused")
        if account.provider == "codex":
            header = {"Authorization": "Bearer $TOKEN$", "OpenAI-Beta": "codex-1", "Originator": "Codex Desktop"}
            if account.chatgpt_account_id:
                header["Chatgpt-Account-Id"] = account.chatgpt_account_id
        else:
            header = {"Authorization": "Bearer $TOKEN$", "anthropic-beta": "oauth-2025-04-20"}
        response = self._management(
            "POST", "api-call", {"auth_index": account.auth_index, "method": "GET", "url": url, "header": header}
        )
        if not isinstance(response, dict):
            raise HubError(200, "invalid_api_call")
        status = response.get("status_code", response.get("statusCode"))
        body = response.get("body")
        if isinstance(status, bool) or not isinstance(status, int) or not isinstance(body, str):
            raise HubError(200, "invalid_api_call")
        return status, body

    def quota_api_available(self) -> bool:
        """CLIProxyAPI 7.3+ answers ``quota/providers``; older ones 404."""
        try:
            document = self._management("GET", "quota/providers")
        except HubError:
            return False
        return isinstance(document, dict) and isinstance(document.get("providers"), list)

    def fetch_quota(self, account: HubAccount) -> object:
        return self._management("POST", "quota/fetch", {"auth_index": account.auth_index, "provider": account.provider})


# --- turning hub answers into snapshots -------------------------------------


def _failure(provider_id: str, instance: str, *, now: float, state, reason: str, action: str, label=None):
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=label,
        observed_at=now,
        state=state,
        reason_code=reason,
        action_label=action,
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        source_instance_id=instance,
    )


def _hub_lanes(snapshot: ProviderUsageSnapshot) -> ProviderUsageSnapshot:
    lanes = tuple(replace(lane, source_id=HUB_SOURCE_ID) for lane in snapshot.lanes)
    return replace(snapshot, lanes=lanes)


def _codex_windows(document: object) -> tuple[list[dict], str | None]:
    if not isinstance(document, dict):
        raise ValueError("invalid Codex usage")
    limits = document.get("rate_limit")
    windows = []
    if isinstance(limits, dict):
        for label, key in (("primary", "primary_window"), ("secondary", "secondary_window")):
            entry = limits.get(key)
            if not isinstance(entry, dict):
                continue
            seconds = entry.get("limit_window_seconds")
            windows.append(
                {
                    "label": label,
                    "used_percent": entry.get("used_percent"),
                    "window_minutes": seconds / 60.0 if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) else None,
                    "resets_at": entry.get("reset_at"),
                }
            )
    plan = document.get("plan_type")
    return windows, plan if isinstance(plan, str) and plan.strip() else None


def _account_snapshot(client: HubClient, account: HubAccount, now: float) -> ProviderUsageSnapshot:
    from .claude_quota import windows_from_payload
    from .provider_usage_parsers import parse_claude_usage, parse_codex_usage

    url = CODEX_USAGE_URL if account.provider == "codex" else CLAUDE_USAGE_URL
    status, body = client.api_call(account, url)
    if status in (401, 403):
        return _failure(
            account.provider,
            account.instance,
            now=now,
            state=ProviderSourceState.NEEDS_SIGN_IN,
            reason="cliproxy_account_signed_out",
            action="Sign this account in again in CLIProxyAPI",
            label=account.email,
        )
    if status == 429:
        return _failure(
            account.provider, account.instance, now=now, state=ProviderSourceState.RATE_LIMITED,
            reason="rate_limited", action="Retry later", label=account.email,
        )
    if not 200 <= status < 300:
        return _failure(
            account.provider, account.instance, now=now, state=ProviderSourceState.UNAVAILABLE,
            reason="cliproxy_provider_refused", action="Retry", label=account.email,
        )
    document = json.loads(body)
    if account.provider == "codex":
        windows, plan = _codex_windows(document)
        snapshot = parse_codex_usage(
            windows=windows,
            observed_at=now,
            account_label=account.email,
            account_plan=plan or account.plan,
            source_id=HUB_SOURCE_ID,
        )
        credits = _reset_credit_count(client, account, now)
        if credits is not None:
            _RESET_CREDITS[account.instance] = credits
    else:
        snapshot = _hub_lanes(
            parse_claude_usage(windows=windows_from_payload(document), observed_at=now, account_label=account.email)
        )
    return replace(snapshot, source_instance_id=account.instance)


#: Available Codex reset credits per hub account, counted read-only (the
#: redeem endpoint is never called). Read by the usage projection's detail.
_RESET_CREDITS: dict[str, int] = {}


def _reset_credit_count(client: HubClient, account: HubAccount, now: float) -> int | None:
    """How many unexpired Codex reset credits the account holds; None when
    the list could not be read. A credits outage never hides the windows."""
    try:
        status, body = client.api_call(account, CODEX_CREDITS_URL)
        if not 200 <= status < 300:
            return None
        document = json.loads(body)
    except (HubError, ValueError):
        return None
    credits = document.get("credits") if isinstance(document, dict) else None
    if not isinstance(credits, list):
        return None
    from datetime import datetime

    count = 0
    for credit in credits[:256]:
        if not isinstance(credit, dict):
            continue
        if credit.get("reset_type") != "codex_rate_limits" or credit.get("status") != "available":
            continue
        try:
            expires = datetime.fromisoformat(str(credit.get("expires_at")).replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if expires > now:
            count += 1
    return count


def reset_credits(instance: str) -> int | None:
    return _RESET_CREDITS.get(instance)


def _quota_snapshot(client: HubClient, account: HubAccount, provider_id: str, now: float):
    """A 7.3+ quota answer as detail lanes: never bindable, since the hub's
    names are not our provider catalog's."""
    document = client.fetch_quota(account)
    groups = document.get("groups") if isinstance(document, dict) else None
    if not isinstance(groups, list):
        return None
    from .provider_usage_parsers import _reset_epoch, _slug

    lanes: list[UsageLane] = []
    for group in groups[:16]:
        if not isinstance(group, dict):
            continue
        name = group.get("displayName", group.get("display_name"))
        name = name if isinstance(name, str) and name.strip() else "Quota"
        for bucket in (group.get("buckets") or [])[:16]:
            if not isinstance(bucket, dict):
                continue
            fraction = bucket.get("remainingFraction", bucket.get("remaining_fraction"))
            if isinstance(fraction, bool) or not isinstance(fraction, (int, float)):
                continue
            window = bucket.get("window") if isinstance(bucket.get("window"), str) else ""
            label = f"{name} {window}".strip()[:120]
            lane_id = _slug(f"hub-{label}", f"hub-{len(lanes) + 1}")
            if any(lane.lane_id == lane_id for lane in lanes):
                continue
            lanes.append(
                UsageLane(
                    provider_id=provider_id,
                    lane_id=lane_id,
                    label=label,
                    remaining_percent=max(0.0, min(100.0, float(fraction) * 100.0)),
                    reset_at=_reset_epoch(bucket.get("resetTime", bucket.get("reset_time"))),
                    scope="all",
                    model=None,
                    feature=None,
                    bindable=False,
                    source_id=HUB_SOURCE_ID,
                )
            )
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=account.email,
        observed_at=now,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=tuple(lanes[:64]),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        source_instance_id=account.instance,
    )


# --- local identities (the dedupe) ------------------------------------------


@dataclass(frozen=True, slots=True)
class LocalIdentities:
    codex_account_id: str | None = None
    claude_email: str | None = None

    def owns(self, account: HubAccount) -> bool:
        if account.provider == "codex":
            return bool(self.codex_account_id and account.chatgpt_account_id == self.codex_account_id)
        if account.provider == "claude":
            return bool(
                self.claude_email
                and account.email
                and account.email.strip().lower() == self.claude_email.strip().lower()
            )
        return False


def local_identities(home: Path | None = None) -> LocalIdentities:
    """This Mac's own Codex account id and Claude email, from the CLIs'
    own files (no Keychain, no prompt)."""
    base = Path.home() if home is None else Path(home)
    codex_id = None
    try:
        from .credentials import read_codex_tokens
        from .provider_homes import primary_codex_sessions

        tokens = read_codex_tokens(primary_codex_sessions(home=base).parent / "auth.json")
        codex_id = getattr(tokens, "account_id", None)
    except Exception:
        codex_id = None
    email = None
    try:
        from .private_io import read_private_text

        document = json.loads(read_private_text(base / ".claude.json", max_bytes=8 * 1024 * 1024))
        account = document.get("oauthAccount") if isinstance(document, dict) else None
        if isinstance(account, dict) and isinstance(account.get("emailAddress"), str):
            email = account["emailAddress"]
    except (OSError, ValueError):
        email = None
    return LocalIdentities(codex_id, email)


# --- the collector ----------------------------------------------------------


def _hub_status(now: float, *, state, reason: str, action: str) -> tuple[ProviderUsageSnapshot, ...]:
    """The hub's own trouble, as one card: Claude, instance ``cliproxy``."""
    return (_failure("claude", "cliproxy", now=now, state=state, reason=reason, action=action),)


def collect_hub(
    settings: Mapping[str, Any] | object,
    *,
    now: float,
    key_reader: Callable[[], str | None],
    identities: LocalIdentities | None = None,
    transport=_default_transport,
) -> tuple[ProviderUsageSnapshot, ...]:
    """Every hub account's snapshot, or the hub's own trouble; () when off."""
    config = normalize_cliproxy_hub(settings if isinstance(settings, Mapping) else getattr(settings, "cliproxy_hub", None))
    if not config["enabled"]:
        return ()
    base = validated_hub_url(config["url"])
    if base is None:
        return _hub_status(
            now, state=ProviderSourceState.ERROR, reason="cliproxy_url_not_loopback",
            action="Use a 127.0.0.1 or localhost URL for CLIProxyAPI",
        )
    key = key_reader()
    if not key:
        return _hub_status(
            now, state=ProviderSourceState.NEEDS_CONSENT, reason="cliproxy_key_missing",
            action="Run jrbar providers credential set cliproxy management --stdin",
        )
    client = HubClient(base, key, transport=transport)
    try:
        accounts = client.accounts()
    except HubError as error:
        if error.status in (401, 403):
            return _hub_status(
                now, state=ProviderSourceState.NEEDS_SIGN_IN, reason="cliproxy_key_rejected",
                action="Check the CLIProxyAPI management key",
            )
        if error.status == 404:
            return _hub_status(
                now, state=ProviderSourceState.UNAVAILABLE, reason="cliproxy_management_off",
                action="Set secret-key in CLIProxyAPI's config",
            )
        return _hub_status(
            now, state=ProviderSourceState.UNAVAILABLE, reason="cliproxy_unreachable", action="Retry",
        )
    mine = identities if identities is not None else local_identities()
    snapshots: list[ProviderUsageSnapshot] = []
    quota_api: bool | None = None
    for account in accounts[:MAX_ACCOUNTS]:
        if mine.owns(account):
            continue
        try:
            if account.provider in ("claude", "codex"):
                snapshots.append(_account_snapshot(client, account, now))
            elif account.provider in _QUOTA_PROVIDER_IDS:
                if quota_api is None:
                    quota_api = client.quota_api_available()
                if not quota_api:
                    continue
                snapshot = _quota_snapshot(client, account, _QUOTA_PROVIDER_IDS[account.provider], now)
                if snapshot is not None:
                    snapshots.append(snapshot)
        except (HubError, ValueError, TypeError):
            provider_id = account.provider if account.provider in ("claude", "codex") else None
            if provider_id is not None:
                snapshots.append(
                    _failure(
                        provider_id, account.instance, now=now, state=ProviderSourceState.UNAVAILABLE,
                        reason="cliproxy_read_failed", action="Retry", label=account.email,
                    )
                )
    seen: set[tuple[str, str]] = set()
    unique = []
    for snapshot in snapshots:
        if snapshot.identity in seen:
            continue
        seen.add(snapshot.identity)
        unique.append(snapshot)
    return tuple(unique)


def keychain_key_reader(credentials: object = None) -> Callable[[], str | None]:
    def read() -> str | None:
        store = credentials
        if store is None:
            from .provider_credential_store import ProviderCredentialStore

            store = ProviderCredentialStore()
        try:
            result = store.get(KEYCHAIN_PROVIDER, KEYCHAIN_ACCOUNT)
        except Exception:
            return None
        secret = getattr(result, "secret", None)
        if not getattr(result, "available", False) or not isinstance(secret, str) or not secret.strip():
            return None
        return secret.strip()

    return read


class HubSource:
    """The hub for the usage runtime: collected at most once per
    ``min_interval_seconds``, the last answer served in between."""

    def __init__(
        self,
        *,
        settings_loader: Callable[[], object] | None = None,
        key_reader: Callable[[], str | None] | None = None,
        transport=_default_transport,
        identities: Callable[[], LocalIdentities] | None = None,
    ) -> None:
        self._settings_loader = settings_loader
        self._key_reader = key_reader or keychain_key_reader()
        self._transport = transport
        self._identities = identities or local_identities
        self._lock = threading.Lock()
        self._last_at: float | None = None
        self._last: tuple[ProviderUsageSnapshot, ...] = ()

    def _settings(self) -> object:
        if self._settings_loader is not None:
            return self._settings_loader()
        from .settings import load_settings

        return load_settings()

    def __call__(self, now: float, *, force: bool = False) -> tuple[ProviderUsageSnapshot, ...]:
        settings = self._settings()
        config = normalize_cliproxy_hub(getattr(settings, "cliproxy_hub", settings if isinstance(settings, Mapping) else None))
        if not config["enabled"]:
            with self._lock:
                self._last, self._last_at = (), None
            return ()
        with self._lock:
            fresh = self._last_at is not None and now - self._last_at < config["min_interval_seconds"]
            if fresh and not force:
                return self._last
        snapshots = collect_hub(
            config, now=now, key_reader=self._key_reader, identities=self._identities(), transport=self._transport
        )
        with self._lock:
            self._last, self._last_at = snapshots, now
        return snapshots


__all__ = [
    "ALLOWED_PATHS",
    "HUB_SOURCE_ID",
    "HubAccount",
    "HubClient",
    "HubError",
    "HubSource",
    "LocalIdentities",
    "collect_hub",
    "instance_for",
    "keychain_key_reader",
    "local_identities",
    "reset_credits",
    "validated_hub_url",
]
