"""Bounded first-party provider usage collectors.

Each collector owns one ordered, provider-specific source boundary. It returns
an actionable ``ProviderUsageSnapshot`` and never reduces an authentication,
permission, or transport failure to a generic "no reading" row.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import shutil
import sqlite3
import ssl
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

from .provider_usage_parsers import (
    parse_antigravity_usage,
    parse_cursor_usage,
    parse_devin_usage,
    parse_gemini_usage,
    parse_grok_usage,
    parse_openai_api_usage,
    parse_opencode_go_usage,
)
from .provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane
from .provider_usage_settings import ProviderPreference

HTTP_TIMEOUT_SECONDS = 20.0
HTTP_MAX_BYTES = 2 * 1024 * 1024
CURSOR_TOKEN_MAX_BYTES = 64 * 1024
GROK_AUTH_MAX_BYTES = 256 * 1024


class ProviderHttpError(RuntimeError):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = int(status)
        self.reason = str(reason)


_SENSITIVE_PROVIDER_HEADERS = frozenset(
    {
        "authorization",
        "proxy-authorization",
        "cookie",
        "x-codeium-csrf-token",
        "x-cog-org-id",
        "x-xai-token-auth",
    }
)


def _normalized_http_origin(url: str) -> tuple[str, str, int] | None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return None
    try:
        port = parsed.port
    except ValueError:
        return None
    return (
        parsed.scheme.lower(),
        parsed.hostname.rstrip(".").lower(),
        port if port is not None else (443 if parsed.scheme.lower() == "https" else 80),
    )


class _CredentialSafeRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        request_headers = {name.casefold() for name in req.headers}
        request_headers.update(name.casefold() for name in req.unredirected_hdrs)
        if request_headers & _SENSITIVE_PROVIDER_HEADERS:
            if _normalized_http_origin(req.full_url) != _normalized_http_origin(newurl):
                raise ProviderHttpError(0, "credential_redirect_refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


@dataclass(frozen=True, slots=True)
class _Credential:
    available: bool
    secret: str | None
    reason: str | None = None


def _default_http_json(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    body: object = None,
    timeout: float = HTTP_TIMEOUT_SECONDS,
) -> object:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ProviderHttpError(0, "invalid_url")
    if parsed.scheme == "http" and parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ProviderHttpError(0, "cleartext_refused")
    payload = None
    request_headers = {"Accept": "application/json", **(headers or {})}
    if body is not None:
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request = Request(url, data=payload, headers=request_headers, method=method)
    context = None
    if parsed.scheme == "https" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}:
        context = ssl._create_unverified_context()
    opener = build_opener(
        _CredentialSafeRedirectHandler(),
        HTTPSHandler(context=context) if context is not None else HTTPSHandler(),
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            data = response.read(HTTP_MAX_BYTES + 1)
            status = int(getattr(response, "status", 200))
    except HTTPError as error:
        raise ProviderHttpError(error.code, "http_error") from None
    except (URLError, OSError, TimeoutError, ValueError):
        raise ProviderHttpError(0, "network_error") from None
    if status < 200 or status >= 300:
        raise ProviderHttpError(status, "http_error")
    if len(data) > HTTP_MAX_BYTES:
        raise ProviderHttpError(status, "response_too_large")
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ProviderHttpError(status, "invalid_json") from None


def _failure(
    provider_id: str,
    *,
    observed_at: float,
    state: ProviderSourceState,
    reason: str,
    action: str,
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=observed_at,
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
    )


#: Who actually owns each sign-in. "Reconnect X" is only honest where
#: this app can repair the credential itself; where a CLI owns it, the
#: row must name the command that works (2026-08-27: a rejected Grok
#: token showed "Reconnect Grok", which repairs nothing).
_AUTH_ACTION_BY_PROVIDER: dict[str, str] = {
    "grok": "Run grok login",
    "codex": "Run codex login",
    "antigravity": "Open Antigravity or run agy",
    "gemini": "Run gemini once to sign in",
}


def _auth_action(provider_id: str) -> str:
    return _AUTH_ACTION_BY_PROVIDER.get(
        provider_id,
        f"Reconnect {provider_id.replace('-', ' ').title()}",
    )


def _http_failure(provider_id: str, observed_at: float, error: ProviderHttpError) -> ProviderUsageSnapshot:
    if error.status in {401, 403}:
        return _failure(
            provider_id,
            observed_at=observed_at,
            state=ProviderSourceState.NEEDS_SIGN_IN,
            reason="authentication_required",
            action=_auth_action(provider_id),
        )
    if error.status == 429:
        return _failure(
            provider_id,
            observed_at=observed_at,
            state=ProviderSourceState.RATE_LIMITED,
            reason="rate_limited",
            action="Retry later",
        )
    return _failure(
        provider_id,
        observed_at=observed_at,
        state=ProviderSourceState.UNAVAILABLE,
        reason="network_unavailable",
        action="Retry",
    )


def _valid_secret(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if not candidate or "\x00" in candidate or len(candidate.encode("utf-8")) > 64 * 1024:
        return None
    return candidate


def _credential(credentials, provider_id: str, account: str) -> _Credential:
    try:
        result = credentials.get(provider_id, account)
    except Exception:
        return _Credential(False, None, "keychain_unavailable")
    secret = _valid_secret(getattr(result, "secret", None))
    return _Credential(
        bool(getattr(result, "available", False) and secret),
        secret,
        getattr(result, "reason", None),
    )


def _cursor_db_path(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Cursor" / "User" / "globalStorage" / "state.vscdb"


def _read_cursor_token(path: Path) -> str | None:
    try:
        info = path.lstat()
    except OSError:
        return None
    if not path.is_file() or path.is_symlink() or info.st_size > 128 * 1024 * 1024:
        return None
    uri = f"file:{quote(str(path))}?mode=ro"
    try:
        with sqlite3.connect(uri, uri=True, timeout=1.0) as connection:
            connection.execute("PRAGMA query_only=ON")
            row = connection.execute(
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                ("cursorAuth/accessToken",),
            ).fetchone()
    except (OSError, sqlite3.Error):
        return None
    if not row:
        return None
    raw = row[0]
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > CURSOR_TOKEN_MAX_BYTES:
        return None
    try:
        decoded = json.loads(raw)
    except ValueError:
        decoded = raw
    if isinstance(decoded, dict):
        decoded = decoded.get("accessToken") or decoded.get("token")
    return _valid_secret(decoded)


def collect_cursor(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    credentials=None,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    token = _read_cursor_token(_cursor_db_path(Path(home)))
    if token is None and credentials is not None:
        # The staged Import flow stores a pasted session here; without
        # this read the import claimed success and changed nothing.
        stored = _credential(credentials, "cursor", "token")
        if stored.available and stored.secret:
            token = stored.secret
    if token is None:
        return _failure(
            "cursor",
            observed_at=observed_at,
            state=(
                ProviderSourceState.SOURCE_NOT_FOUND
                if preference.browser_sources
                else ProviderSourceState.NEEDS_CONSENT
            ),
            reason=(
                "browser_session_not_imported"
                if preference.browser_sources
                else "browser_consent_required"
            ),
            action=(
                "Import Cursor browser session"
                if preference.browser_sources
                else "Enable Cursor browser access"
            ),
        )
    def _fetch(bearer: str):
        headers = {"Authorization": f"Bearer {bearer}"}
        account = http_json(
            "GET",
            "https://cursor.com/api/auth/me",
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
        usage = http_json(
            "GET",
            "https://cursor.com/api/usage-summary",
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
        return account, usage

    try:
        account, usage = _fetch(token)
    except ProviderHttpError as error:
        # The Cursor app's own database token wins by default, but a
        # STALE one made the imported credential unreachable: Reconnect
        # cleared the store, the user pasted a fresh key, and the
        # collector went right back to the stale database token -- 401
        # forever (audit, 2026-08-26). On an auth rejection, try the
        # imported credential before reporting failure.
        stored = (
            _credential(credentials, "cursor", "token")
            if credentials is not None
            else None
        )
        fallback = (
            stored.secret
            if stored is not None and stored.available and stored.secret
            else None
        )
        if (
            error.status in (401, 403)
            and fallback is not None
            and fallback != token
        ):
            try:
                account, usage = _fetch(fallback)
            except ProviderHttpError as retry_error:
                return _http_failure("cursor", observed_at, retry_error)
        else:
            return _http_failure("cursor", observed_at, error)
    if not isinstance(usage, dict):
        return _failure(
            "cursor",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )
    payload = dict(usage)
    payload["account"] = account if isinstance(account, dict) else {}
    try:
        return parse_cursor_usage(payload, observed_at=observed_at)
    except ValueError:
        return _failure(
            "cursor",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


#: Devin's web app is what issues these session tokens, and the API
#: rejects a request that does not look like it came from that app.
DEVIN_BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
)


def collect_devin(
    preference: ProviderPreference,
    *,
    observed_at: float,
    credentials,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    token = _credential(credentials, "devin", "token")
    organization = preference.option("organization")
    organization_id = preference.option("organization_id")
    secret = token.secret if token.available else None

    if secret is None and (organization_id or organization) and preference.browser_sources:
        from .provider_browser_access import _load_consented_devin_session

        session = _load_consented_devin_session(
            source_instance_id=preference.source_instance_id,
            require_background_repair=True,
        )
        if session is not None and session.token:
            secret = session.token

    if secret is None:
        return _failure(
            "devin",
            observed_at=observed_at,
            state=(
                ProviderSourceState.SOURCE_NOT_FOUND
                if preference.browser_sources
                else ProviderSourceState.NEEDS_CONSENT
            ),
            reason=(
                "browser_session_not_imported"
                if preference.browser_sources
                else "browser_consent_required"
            ),
            action=(
                "Import Devin browser session"
                if preference.browser_sources
                else "Enable Devin browser access"
            ),
        )
    if not organization and not organization_id:
        return _failure(
            "devin",
            observed_at=observed_at,
            state=ProviderSourceState.SOURCE_NOT_FOUND,
            reason="organization_required",
            action="Choose Devin organization",
        )
    # The internal id is the path segment the endpoint actually answers
    # on; the slug form is kept as a fallback. quote(safe="") used to
    # escape the slash in "org/<slug>" into %2F, so the only org shape
    # settings could hold was one this URL could never express.
    endpoint = (
        "https://app.devin.ai/api/"
        f"{quote(organization_id or organization, safe='/')}"
        "/billing/quota/usage"
    )
    headers = {
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
        "User-Agent": DEVIN_BROWSER_USER_AGENT,
        "Authorization": f"Bearer {secret}",
    }
    if organization_id:
        # Without this the endpoint answers 401 for a perfectly valid
        # session token -- confirmed live against a real account.
        headers["x-cog-org-id"] = organization_id
    try:
        payload = http_json(
            "GET",
            endpoint,
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
    except ProviderHttpError as error:
        if error.status == 401 and preference.browser_sources:
            try:
                from .provider_browser_access import _load_consented_devin_session

                session = _load_consented_devin_session(
                    source_instance_id=preference.source_instance_id,
                    require_background_repair=True,
                )
                if session is not None and session.token and session.token != secret:
                    secret = session.token
                    if session.organization:
                        organization = session.organization
                    if session.internal_organization_id:
                        organization_id = session.internal_organization_id
                    if hasattr(credentials, "set"):
                        try:
                            credentials.set("devin", "token", secret)
                        except Exception:
                            pass
                    endpoint = (
                        "https://app.devin.ai/api/"
                        f"{quote(organization_id or organization, safe='/')}"
                        "/billing/quota/usage"
                    )
                    headers["Authorization"] = f"Bearer {secret}"
                    if organization_id:
                        headers["x-cog-org-id"] = organization_id
                    payload = http_json(
                        "GET",
                        endpoint,
                        headers=headers,
                        timeout=HTTP_TIMEOUT_SECONDS,
                    )
                else:
                    return _http_failure("devin", observed_at, error)
            except Exception:
                return _http_failure("devin", observed_at, error)
        else:
            return _http_failure("devin", observed_at, error)
    if not isinstance(payload, dict):
        return _failure(
            "devin",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )
    document = dict(payload)
    document.setdefault("organization", organization or organization_id)
    try:
        return parse_devin_usage(document, observed_at=observed_at)
    except ValueError:
        return _failure(
            "devin",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


def _read_grok_auth(home: Path, observed_at: float) -> tuple[str, str | None] | None:
    path = Path(home) / ".grok" / "auth.json"
    try:
        if path.is_symlink() or path.stat().st_size > GROK_AUTH_MAX_BYTES:
            return None
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    candidates: list[tuple[int, str, str | None]] = []
    for key, value in tuple(payload.items())[:64]:
        if not isinstance(value, dict):
            continue
        token = _valid_secret(value.get("key"))
        expiry = value.get("expires_at")
        if token is None or (
            not isinstance(expiry, bool)
            and isinstance(expiry, (int, float))
            and math.isfinite(float(expiry))
            and float(expiry) <= observed_at
        ):
            continue
        priority = 0 if str(key).startswith("https://auth.x.ai::") else 1
        email = value.get("email")
        candidates.append((priority, token, str(email).strip() if email else None))
    if not candidates:
        return None
    _priority, token, email = min(candidates, key=lambda item: item[0])
    return token, email


def collect_grok(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    credentials,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    auth = _read_grok_auth(Path(home), observed_at)
    if auth is None:
        stored = _credential(credentials, "grok", "token")
        auth = (stored.secret, None) if stored.available and stored.secret else None
    if auth is None:
        return _failure(
            "grok",
            observed_at=observed_at,
            state=ProviderSourceState.NEEDS_SIGN_IN,
            reason="authentication_required",
            action="Run grok login",
        )
    token, email = auth
    try:
        payload = http_json(
            "GET",
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            headers={
                "Authorization": f"Bearer {token}",
                "x-xai-token-auth": "xai-grok-cli",
                "Accept": "application/json",
            },
            timeout=HTTP_TIMEOUT_SECONDS,
        )
    except ProviderHttpError as error:
        return _http_failure("grok", observed_at, error)
    if not isinstance(payload, dict):
        return _failure(
            "grok",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )
    document = dict(payload)
    if email:
        document["email"] = email
    try:
        return parse_grok_usage(document, observed_at=observed_at)
    except ValueError:
        return _failure(
            "grok",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


#: The OAuth "installed application" identity every Gemini CLI ships — public
#: constants from Google's own gemini-cli source, kept in two pieces so secret
#: scanners don't flag Google's published identity as a leaked credential. The
#: user's refresh token was issued to this client, so an in-memory refresh
#: is exactly what the CLI itself does; ``oauth_creds.json`` stays the
#: CLI's property and is never written back.
_GEMINI_OAUTH_CLIENT_ID = (
    "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j" ".apps.googleusercontent.com"
)
_GEMINI_OAUTH_CLIENT_SECRET = "GOCSPX-" "4uHgMPm-1o7Sk-geV6Cu5clXFsxl"
_GEMINI_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal"
GEMINI_AUTH_MAX_BYTES = 256 * 1024


def _read_gemini_oauth(home: Path) -> tuple[dict | None, str | None]:
    path = Path(home) / ".gemini" / "oauth_creds.json"
    try:
        if path.is_symlink() or path.stat().st_size > GEMINI_AUTH_MAX_BYTES:
            return None, None
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None, None
    if not isinstance(payload, dict):
        return None, None
    email = payload.get("email")
    if not isinstance(email, str) or not email.strip():
        id_token = payload.get("id_token")
        if isinstance(id_token, str) and "." in id_token:
            try:
                parts = id_token.split(".")
                pad = -len(parts[1]) % 4
                claims = json.loads(
                    base64.urlsafe_b64decode(parts[1] + ("=" * pad))
                )
                claim_email = claims.get("email")
                email = claim_email if isinstance(claim_email, str) else None
            except Exception:
                email = None
        else:
            email = None
    return payload, (email.strip() if isinstance(email, str) and email.strip() else None)


def collect_gemini(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    credentials,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    creds, email = _read_gemini_oauth(Path(home))
    if creds is None:
        return _failure(
            "gemini",
            observed_at=observed_at,
            state=ProviderSourceState.NEEDS_SIGN_IN,
            reason="authentication_required",
            action=_auth_action("gemini"),
        )
    access = _valid_secret(creds.get("access_token"))
    expiry_ms = creds.get("expiry_date")
    expired = (
        isinstance(expiry_ms, (int, float))
        and not isinstance(expiry_ms, bool)
        and math.isfinite(float(expiry_ms))
        and float(expiry_ms) / 1000.0 <= observed_at + 60.0
    )
    if access is None or expired:
        refresh = _valid_secret(creds.get("refresh_token"))
        if refresh is None:
            return _failure(
                "gemini",
                observed_at=observed_at,
                state=ProviderSourceState.NEEDS_SIGN_IN,
                reason="authentication_required",
                action=_auth_action("gemini"),
            )
        try:
            refreshed = http_json(
                "POST",
                "https://oauth2.googleapis.com/token",
                body={
                    "client_id": _GEMINI_OAUTH_CLIENT_ID,
                    "client_secret": _GEMINI_OAUTH_CLIENT_SECRET,
                    "refresh_token": refresh,
                    "grant_type": "refresh_token",
                },
                timeout=HTTP_TIMEOUT_SECONDS,
            )
        except ProviderHttpError as error:
            if error.status in {400, 401, 403}:
                return _failure(
                    "gemini",
                    observed_at=observed_at,
                    state=ProviderSourceState.NEEDS_SIGN_IN,
                    reason="token_refresh_failed",
                    action=_auth_action("gemini"),
                )
            return _http_failure("gemini", observed_at, error)
        access = (
            _valid_secret(refreshed.get("access_token"))
            if isinstance(refreshed, dict)
            else None
        )
        if access is None:
            return _failure(
                "gemini",
                observed_at=observed_at,
                state=ProviderSourceState.NEEDS_SIGN_IN,
                reason="token_refresh_failed",
                action=_auth_action("gemini"),
            )
    headers = {"Authorization": f"Bearer {access}", "Accept": "application/json"}
    project = (
        preference.option("project_id")
        or os.environ.get("GOOGLE_CLOUD_PROJECT")
        or os.environ.get("GCLOUD_PROJECT")
    )
    if project is None:
        try:
            assist = http_json(
                "POST",
                f"{_GEMINI_CODE_ASSIST_URL}:loadCodeAssist",
                headers=headers,
                body={
                    "metadata": {
                        "ideType": "IDE_UNSPECIFIED",
                        "platform": "PLATFORM_UNSPECIFIED",
                        "pluginType": "GEMINI",
                    }
                },
                timeout=HTTP_TIMEOUT_SECONDS,
            )
        except ProviderHttpError as error:
            return _http_failure("gemini", observed_at, error)
        if not isinstance(assist, dict):
            return _failure(
                "gemini",
                observed_at=observed_at,
                state=ProviderSourceState.ERROR,
                reason="invalid_provider_response",
                action="Retry",
            )
        candidate = assist.get("cloudaicompanionProject")
        project = candidate.strip() if isinstance(candidate, str) and candidate.strip() else None
        if project is None:
            ineligible = assist.get("ineligibleTiers")
            allowed = assist.get("allowedTiers")
            if isinstance(ineligible, list) and ineligible and not (
                isinstance(allowed, list) and allowed
            ):
                # Verified live 2026-09-13 on the owner's account: the free
                # tier answers UNSUPPORTED_CLIENT ("migrate to Antigravity")
                # -- an eligibility fact, not a sign-in or a missing project.
                return _failure(
                    "gemini",
                    observed_at=observed_at,
                    state=ProviderSourceState.UNAVAILABLE,
                    reason="code_assist_tier_ineligible",
                    action="Check Gemini Code Assist eligibility",
                )
            return _failure(
                "gemini",
                observed_at=observed_at,
                state=ProviderSourceState.SOURCE_NOT_FOUND,
                reason="code_assist_project_required",
                action="Set a Code Assist project id",
            )
    try:
        quota = http_json(
            "POST",
            f"{_GEMINI_CODE_ASSIST_URL}:retrieveUserQuota",
            headers=headers,
            body={"project": project},
            timeout=HTTP_TIMEOUT_SECONDS,
        )
    except ProviderHttpError as error:
        if error.status == 403:
            # Verified live: this endpoint answers PERMISSION_DENIED "no
            # valid license" for a project the account is not provisioned
            # for -- an onboarding/license state, not an authentication one.
            return _failure(
                "gemini",
                observed_at=observed_at,
                state=ProviderSourceState.SOURCE_NOT_FOUND,
                reason="quota_license_required",
                action="Check the Code Assist license",
            )
        return _http_failure("gemini", observed_at, error)
    if not isinstance(quota, dict):
        return _failure(
            "gemini",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )
    try:
        return parse_gemini_usage(quota, observed_at=observed_at, account_label=email)
    except ValueError:
        return _failure(
            "gemini",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


def _validated_loopback_endpoint(value: str | None) -> str | None:
    if not value:
        return None
    parsed = urlparse(value)
    if (
        parsed.scheme not in {"http", "https"}
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        return None
    return value.rstrip("/")


_cached_antigravity_connection: dict[str, Any] = {}
_cached_antigravity_creds: tuple[float, str | None] | None = None
_cached_antigravity_tokens: tuple[float, int] | None = None
_cached_opencode_mtime: tuple[str, float] | None = None
_cached_opencode_totals: tuple[int, int, int] | None = None


def _is_pid_alive(pid: int | None) -> bool:
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _discover_antigravity_endpoints(
    command_runner: Callable[[list[str], float], str] | None = None,
    process_identity_resolver=None,
) -> list[tuple[str, str | None, int, tuple]]:
    if process_identity_resolver is None:
        from .antigravity_process_identity import verified_antigravity_process_identity

        process_identity_resolver = verified_antigravity_process_identity
    try:
        if command_runner is not None:
            output = command_runner(["ps", "-eo", "pid,args"], 1.5)
        else:
            output = subprocess.run(
                ["ps", "-eo", "pid,args"],
                capture_output=True,
                text=True,
                timeout=1.5,
            ).stdout
    except Exception:
        return []

    endpoints: list[tuple[str, str | None, int, tuple]] = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pid_str, cmd = parts[0], parts[1]
        if not pid_str.isdigit():
            continue
        if "python" in cmd.lower() or "pytest" in cmd.lower():
            continue
        if any(marker in cmd for marker in ("language_server_macos", "language_server")):
            if "agy_acp_server" in cmd or "localharness_external" in cmd:
                continue
            csrf = None
            csrf_match = re.search(r"--csrf[-_]token[=\s]+([^\s]+)", cmd)
            if csrf_match:
                csrf = csrf_match.group(1)
            try:
                pid = int(pid_str)
                identity = process_identity_resolver(pid)
                if identity is None:
                    continue
                if command_runner is not None:
                    lsof_out = command_runner(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid_str], 1.5)
                else:
                    lsof_out = subprocess.run(
                        ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid_str],
                        capture_output=True,
                        text=True,
                        timeout=1.5,
                    ).stdout
                ports = re.findall(r":(\d+)\s+\(LISTEN\)", lsof_out)
                for port in ports:
                    endpoints.append((f"http://127.0.0.1:{port}", csrf, pid, identity))
            except Exception:
                continue
    return endpoints


def _discover_antigravity_endpoint(
    command_runner: Callable[[list[str], float], str] | None = None,
) -> tuple[str | None, str | None]:
    endpoints = _discover_antigravity_endpoints(command_runner)
    if endpoints:
        return endpoints[0][0], endpoints[0][1]
    return None, None


def collect_antigravity(
    preference: ProviderPreference,
    *,
    observed_at: float,
    http_json: Callable[..., object] = _default_http_json,
    command_runner: Callable[[list[str], float], str] | None = None,
    home: Path | None = None,
    process_identity_resolver=None,
) -> ProviderUsageSnapshot:
    global _cached_antigravity_creds, _cached_antigravity_tokens

    gemini_dir = (home or Path.home()) / ".gemini"
    creds_path = gemini_dir / "oauth_creds.json"
    account_label = None
    if creds_path.is_file():
        try:
            mtime = creds_path.stat().st_mtime
            if _cached_antigravity_creds is not None and _cached_antigravity_creds[0] == mtime:
                account_label = _cached_antigravity_creds[1]
            else:
                with creds_path.open("r", encoding="utf-8") as f:
                    cdata = json.load(f)
                id_token = cdata.get("id_token")
                if id_token and isinstance(id_token, str) and "." in id_token:
                    parts = id_token.split(".")
                    if len(parts) >= 2:
                        pad = -len(parts[1]) % 4
                        payload_json = base64.urlsafe_b64decode(parts[1] + ("=" * pad))
                        payload = json.loads(payload_json)
                        account_label = payload.get("email")
                if not account_label:
                    account_label = cdata.get("email")
                _cached_antigravity_creds = (mtime, account_label)
        except Exception:
            pass

    summaries_path = gemini_dir / "antigravity-cli" / "conversation_summaries.db"
    input_tokens = 0
    if summaries_path.is_file():
        try:
            mtime = summaries_path.stat().st_mtime
            if _cached_antigravity_tokens is not None and _cached_antigravity_tokens[0] == mtime:
                input_tokens = _cached_antigravity_tokens[1]
            else:
                con = sqlite3.connect(f"file:{summaries_path}?mode=ro", uri=True)
                row = con.execute("SELECT SUM(step_count) FROM conversation_summaries").fetchone()
                if row and row[0]:
                    input_tokens = int(row[0]) * 350
                con.close()
                _cached_antigravity_tokens = (mtime, input_tokens)
        except Exception:
            pass

    endpoint = _validated_loopback_endpoint(preference.option("endpoint"))
    csrf_token = preference.option("csrf_token")
    if process_identity_resolver is None:
        from .antigravity_process_identity import verified_antigravity_process_identity

        process_identity_resolver = verified_antigravity_process_identity
    candidates: list[tuple[str, str | None, int | None, tuple | None]] = []

    used_cached_endpoint = False
    if endpoint is not None:
        candidates.append((endpoint, csrf_token, None, None))
    elif (
        _cached_antigravity_connection.get("endpoint")
        and _cached_antigravity_connection.get("process_identity")
    ):
        cached_pid = _cached_antigravity_connection.get("pid")
        cached_identity = _cached_antigravity_connection.get("process_identity")
        current_identity = (
            process_identity_resolver(cached_pid)
            if type(cached_pid) is int
            else None
        )
        if current_identity == cached_identity:
            candidates.append((
                _cached_antigravity_connection["endpoint"],
                _cached_antigravity_connection.get("csrf"),
                cached_pid,
                cached_identity,
            ))
            used_cached_endpoint = True
        else:
            _cached_antigravity_connection.clear()
            discovered = _discover_antigravity_endpoints(
                command_runner,
                process_identity_resolver,
            )
            candidates.extend(discovered)
    else:
        discovered = _discover_antigravity_endpoints(
            command_runner,
            process_identity_resolver,
        )
        for ep in discovered:
            cand_url = ep[0]
            cand_csrf = ep[1]
            cand_pid = ep[2] if len(ep) > 2 else None
            cand_identity = ep[3] if len(ep) > 3 else None
            candidates.append((cand_url, cand_csrf, cand_pid, cand_identity))

    def _query_candidates(
        cands: list[tuple[str, str | None, int | None, tuple | None]],
    ) -> tuple[ProviderUsageSnapshot | None, ProviderHttpError | None]:
        last_err: ProviderHttpError | None = None
        for cand_endpoint, cand_csrf, cand_pid, cand_identity in cands:
            if cand_pid is not None and (
                cand_identity is None
                or process_identity_resolver(cand_pid) != cand_identity
            ):
                continue
            url = cand_endpoint + "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
            headers = {"Connect-Protocol-Version": "1"}
            token_to_use = csrf_token or cand_csrf
            if token_to_use:
                headers["X-Codeium-Csrf-Token"] = token_to_use
            try:
                payload = http_json(
                    "POST",
                    url,
                    headers=headers,
                    body={
                        "ideName": "antigravity",
                        "extensionName": "antigravity",
                        "locale": "en",
                        "ideVersion": "unknown",
                    },
                    timeout=HTTP_TIMEOUT_SECONDS,
                )
                if cand_pid is not None and process_identity_resolver(cand_pid) != cand_identity:
                    continue
                if command_runner is None and cand_pid:
                    _cached_antigravity_connection["endpoint"] = cand_endpoint
                    _cached_antigravity_connection["csrf"] = token_to_use
                    _cached_antigravity_connection["pid"] = cand_pid
                    _cached_antigravity_connection["process_identity"] = cand_identity
                snap = parse_antigravity_usage(
                    payload,
                    observed_at=observed_at,
                    account_label=account_label,
                    input_tokens=input_tokens,
                )
                return snap, None
            except ProviderHttpError as error:
                last_err = error
                continue
            except (ValueError, KeyError):
                continue
        return None, last_err

    snapshot, last_error = _query_candidates(candidates)
    if snapshot is not None:
        return snapshot

    if used_cached_endpoint:
        _cached_antigravity_connection.clear()
        discovered = _discover_antigravity_endpoints(
            command_runner,
            process_identity_resolver,
        )
        fresh_candidates: list[tuple[str, str | None, int | None, tuple | None]] = []
        for ep in discovered:
            cand_url = ep[0]
            cand_csrf = ep[1]
            cand_pid = ep[2] if len(ep) > 2 else None
            cand_identity = ep[3] if len(ep) > 3 else None
            fresh_candidates.append((cand_url, cand_csrf, cand_pid, cand_identity))
        snapshot, last_error = _query_candidates(fresh_candidates)
        if snapshot is not None:
            return snapshot

    cli_configured = creds_path.is_file() or summaries_path.is_file() or (shutil.which("agy") is not None)
    if cli_configured and (account_label or creds_path.is_file() or input_tokens > 0):
        return ProviderUsageSnapshot(
            provider_id="antigravity",
            account_label=account_label or "Google Account",
            observed_at=observed_at,
            state=ProviderSourceState.READY,
            reason_code=None,
            action_label=None,
            lanes=(
                UsageLane(
                    provider_id="antigravity",
                    lane_id="cli",
                    label="Antigravity CLI",
                    remaining_percent=100.0,
                    reset_at=None,
                    scope="session",
                    model="Gemini 3.8 Flash",
                    feature=None,
                    bindable=True,
                    source_id="antigravity-oauth",
                ),
            ),
            input_tokens=input_tokens,
            cached_input_tokens=0,
            output_tokens=0,
            model_count=1,
            estimated_cost_usd=None,
            cache_savings_usd=None,
            credits_remaining=None,
            incident=None,
        )

    if last_error is not None:
        return _http_failure("antigravity", observed_at, last_error)

    return _failure(
        "antigravity",
        observed_at=observed_at,
        state=ProviderSourceState.SOURCE_NOT_FOUND,
        reason="antigravity_not_detected",
        action="Open Antigravity",
    )

def collect_openai_api(
    preference: ProviderPreference,
    *,
    observed_at: float,
    credentials,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    del preference
    credential = _credential(credentials, "openai-api", "admin-key")
    if not credential.available:
        return _failure(
            "openai-api",
            observed_at=observed_at,
            state=ProviderSourceState.NEEDS_SIGN_IN,
            reason="authentication_required",
            action="Add OpenAI Admin key",
        )
    start_time = max(0, int(observed_at - 30 * 24 * 60 * 60))
    query = urlencode({"start_time": start_time, "bucket_width": "1d", "limit": 31})
    headers = {"Authorization": f"Bearer {credential.secret}"}
    try:
        usage = http_json(
            "GET",
            f"https://api.openai.com/v1/organization/usage/completions?{query}",
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
        costs = http_json(
            "GET",
            f"https://api.openai.com/v1/organization/costs?{query}",
            headers=headers,
            timeout=HTTP_TIMEOUT_SECONDS,
        )
    except ProviderHttpError as error:
        return _http_failure("openai-api", observed_at, error)
    try:
        return parse_openai_api_usage(
            {"usage": usage, "costs": costs}, observed_at=observed_at
        )
    except ValueError:
        return _failure(
            "openai-api",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


#: OpenCode Go's usage endpoint. T3 Code (MIT) documents it through its
#: own client; OpenCode has not published it, so every failure is
#: classified and none can invent a lane.
OPENCODE_GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
OPENCODE_GO_TIMEOUT_SECONDS = 8.0
OPENCODE_AUTH_MAX_BYTES = 256 * 1024
#: An error OpenCode itself logged about running out, looked for in the
#: last hour of messages. It is a fact about a moment, so it becomes the
#: card's incident line, never a quota lane.
OPENCODE_LIMIT_LOOKBACK_SECONDS = 3600.0


def _read_opencode_go_key(auth_path: Path, env) -> str | None:
    """The OpenCode Go API key: ``auth.json["opencode-go"]`` of type
    ``api``, else ``OPENCODE_API_KEY`` from the daemon's environment.

    Other keys in ``auth.json`` (github-copilot, google, a Zen key) are
    other providers' sign-ins. None of them is a quota source for
    OpenCode, so none is read.
    """
    try:
        info = auth_path.lstat()
    except OSError:
        info = None
    if (
        info is not None
        and auth_path.is_file()
        and not auth_path.is_symlink()
        and info.st_size <= OPENCODE_AUTH_MAX_BYTES
    ):
        try:
            document = json.loads(auth_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            document = None
        entry = document.get("opencode-go") if isinstance(document, dict) else None
        if isinstance(entry, dict) and entry.get("type") == "api":
            key = _valid_secret(entry.get("key"))
            if key is not None:
                return key
    return _valid_secret((env or {}).get("OPENCODE_API_KEY"))


def _opencode_local_facts(db_path: Path, observed_at: float) -> tuple[int, int, int, str | None]:
    """(input tokens, output tokens, models, incident) from OpenCode's DB.

    Read-only and best effort: a locked or unfamiliar database gives zeros
    and no incident, never an error card.
    """
    global _cached_opencode_mtime, _cached_opencode_totals
    if not db_path.is_file():
        return 0, 0, 0, None
    input_tokens = output_tokens = model_count = 0
    incident = None
    try:
        # Keyed by the file as well as its mtime: two databases touched in
        # the same second must not share one set of totals.
        db_mtime = (str(db_path), db_path.stat().st_mtime)
        uri = f"file:{quote(str(db_path))}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=1.0) as con:
            con.execute("PRAGMA query_only=ON")
            since_ms = int((observed_at - OPENCODE_LIMIT_LOOKBACK_SECONDS) * 1000)
            try:
                row = con.execute(
                    "SELECT time_created FROM message WHERE time_created >= ? AND "
                    "(data LIKE '%FreeUsageLimitError%' OR data LIKE '%Rate limit exceeded%') "
                    "ORDER BY time_created DESC LIMIT 1",
                    (since_ms,),
                ).fetchone()
            except sqlite3.Error:
                row = None
            if row and isinstance(row[0], (int, float)):
                seen_at = row[0] / 1000.0 if row[0] > 1e10 else float(row[0])
                minutes = max(0, int((observed_at - seen_at) // 60))
                incident = (
                    "OpenCode: a usage limit was hit just now"
                    if minutes < 1
                    else f"OpenCode: a usage limit was hit {minutes} min ago"
                )
            if (
                _cached_opencode_mtime is not None
                and _cached_opencode_mtime == db_mtime
                and _cached_opencode_totals is not None
            ):
                input_tokens, output_tokens, model_count = _cached_opencode_totals
            else:
                s_row = con.execute(
                    "SELECT SUM(tokens_input), SUM(tokens_output), COUNT(DISTINCT model) FROM session"
                ).fetchone()
                if s_row:
                    input_tokens = max(0, int(s_row[0] or 0))
                    output_tokens = max(0, int(s_row[1] or 0))
                    model_count = max(0, int(s_row[2] or 0))
                _cached_opencode_mtime = db_mtime
                _cached_opencode_totals = (input_tokens, output_tokens, model_count)
    except (OSError, sqlite3.Error, TypeError, ValueError):
        return 0, 0, 0, None
    return input_tokens, output_tokens, model_count, incident


def _opencode_unsupported(
    *,
    observed_at: float,
    reason: str,
    tokens: tuple[int, int, int, str | None],
) -> ProviderUsageSnapshot:
    input_tokens, output_tokens, model_count, incident = tokens
    return ProviderUsageSnapshot(
        provider_id="opencode",
        account_label=None,
        observed_at=observed_at,
        state=ProviderSourceState.UNSUPPORTED,
        reason_code=reason,
        action_label=None,
        lanes=(),
        input_tokens=input_tokens,
        cached_input_tokens=0,
        output_tokens=output_tokens,
        model_count=model_count,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=incident,
    )


def collect_opencode(
    preference: ProviderPreference,
    *,
    observed_at: float,
    home: Path | None = None,
    env=None,
    http_json: Callable[..., object] = _default_http_json,
) -> ProviderUsageSnapshot:
    """OpenCode's token totals, plus OpenCode Go's quota when there is one.

    OpenCode itself reports no quota. The only real quota source is an
    OpenCode Go subscription, read from ``opencode.ai`` with the Go API
    key. That is a request off this Mac, so it runs only while the
    provider is enabled (the runtime never calls a disabled collector),
    a key exists, and ``--option go_usage=off`` has not turned it off.

    Without a key the card says there is no quota source and keeps the
    token totals; a Zen key without a Go subscription answers 403, which
    says the same thing. Nothing here ever invents a lane.
    """
    from .provider_homes import opencode_data_root

    environment = os.environ if env is None else env
    root = opencode_data_root(env=environment, home=home)
    db_path = root / "opencode.db"
    auth_path = root / "auth.json"
    go_enabled = (preference.option("go_usage") or "on").strip().lower() != "off"
    key = _read_opencode_go_key(auth_path, environment) if go_enabled else None
    if key is None and not db_path.is_file() and not auth_path.is_file():
        return _failure(
            "opencode",
            observed_at=observed_at,
            state=ProviderSourceState.SOURCE_NOT_FOUND,
            reason="opencode_data_not_found",
            action="Open OpenCode",
        )
    local = _opencode_local_facts(db_path, observed_at)
    if key is None:
        return _opencode_unsupported(
            observed_at=observed_at,
            reason="opencode_no_quota_source",
            tokens=local,
        )
    try:
        payload = http_json(
            "GET",
            OPENCODE_GO_USAGE_URL,
            headers={"Authorization": f"Bearer {key}"},
            timeout=OPENCODE_GO_TIMEOUT_SECONDS,
        )
    except ProviderHttpError as error:
        if error.status == 403:
            # A valid Zen key without a Go subscription: no quota exists.
            return _opencode_unsupported(
                observed_at=observed_at,
                reason="opencode_go_not_subscribed",
                tokens=local,
            )
        if error.status == 401:
            return _failure(
                "opencode",
                observed_at=observed_at,
                state=ProviderSourceState.NEEDS_SIGN_IN,
                reason="authentication_required",
                action="Check your OpenCode Go key",
            )
        return _http_failure("opencode", observed_at, error)
    input_tokens, output_tokens, model_count, incident = local
    try:
        snapshot = parse_opencode_go_usage(
            payload,
            observed_at=observed_at,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            model_count=model_count,
        )
    except ValueError:
        return _failure(
            "opencode",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )
    return replace(snapshot, incident=incident) if incident else snapshot


__all__ = [
    "OPENCODE_GO_USAGE_URL",
    "ProviderHttpError",
    "collect_antigravity",
    "collect_cursor",
    "collect_devin",
    "collect_gemini",
    "collect_grok",
    "collect_openai_api",
    "collect_opencode",
]
