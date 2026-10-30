"""Factory billing windows from an explicitly connected credential."""

from __future__ import annotations

import hashlib
import json
import math
import time
from dataclasses import replace
from datetime import datetime
from urllib.parse import urlencode

from .browser_session_import import BrowserSessionReadError
from .provider_usage_collectors import ProviderHttpError, _credential, _default_http_json
from .provider_usage_parsers import _snapshot
from .provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane, failure_snapshot

_BASE = "https://api.factory.ai/api"


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("invalid Factory number")
    if not math.isfinite(value) or value < 0:
        raise ValueError("invalid Factory number")
    return float(value)


def _text(value):
    return value.strip() if isinstance(value, str) and 0 < len(value.strip()) <= 200 else None


def _identity(auth):
    if not isinstance(auth, dict):
        return None, None
    user = auth.get("userProfile")
    org = auth.get("organization")
    user = user if isinstance(user, dict) else {}
    org = org if isinstance(org, dict) else {}
    uid, oid = _text(user.get("id")), _text(org.get("id"))
    discriminator = None
    if uid and oid:
        raw = json.dumps(["factory", uid, oid], separators=(",", ":"))
        discriminator = "factory:" + hashlib.sha256(raw.encode()).hexdigest()
    subscription = org.get("subscription")
    subscription = subscription if isinstance(subscription, dict) else {}
    plan = subscription.get("orbSubscription")
    plan = plan.get("plan") if isinstance(plan, dict) else None
    plan = _text(plan.get("name")) if isinstance(plan, dict) else None
    return discriminator, plan or _text(subscription.get("factoryTier"))


def _authenticated_identity(auth, bearer):
    if not isinstance(auth, dict):
        return auth
    user = auth.get("userProfile")
    if not isinstance(user, dict):
        return auth
    if user.get("id") is not None:
        return auth
    from .factory_session import _jwt_claim

    subject = _jwt_claim(bearer, "sub")
    if subject is None:
        return auth
    return {**auth, "userProfile": {**user, "id": subject}}


def _reset(window, now):
    seconds = window.get("secondsRemaining")
    if seconds is not None:
        seconds = _number(seconds)
        if seconds > 0:
            return now + seconds
    value = window.get("windowEnd")
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("Factory reset requires timezone") from None
            return _number(parsed.timestamp())
    epoch = _number(value)
    return epoch / 1000 if epoch > 1e12 else epoch


def _lane(lane_id, label, used, reset, scope, source="factory-billing-limits"):
    return UsageLane("factory", lane_id, label, max(0, 100 - used), reset,
                     scope, None, None, scope != "core", source)


def parse_factory_usage(payload, *, observed_at: float, auth: object | None = None) -> ProviderUsageSnapshot:
    """Decode observed allowances without inferring a reset or a plan."""
    if not isinstance(payload, dict):
        raise ValueError("invalid Factory response")
    mode = payload.get("usesTokenRateLimitsBilling")
    lanes = []
    if mode is True:
        limits = payload.get("limits")
        if not isinstance(limits, dict) or not isinstance(limits.get("standard"), dict):
            raise ValueError("missing Factory limits")
        for pool in ("standard", "core"):
            windows = limits.get(pool)
            if windows is None and pool == "core":
                continue
            if not isinstance(windows, dict):
                raise ValueError("invalid Factory pool")
            for field, suffix, label in (("fiveHour", "5h", "5-hour"),
                                         ("weekly", "7d", "7-day"),
                                         ("monthly", "30d", "Monthly")):
                window = windows.get(field)
                if not isinstance(window, dict):
                    raise ValueError("missing Factory window")
                used = _number(window.get("usedPercent"))
                lanes.append(_lane(f"{pool}-{suffix}", f"{pool.title()} {label}", used,
                                   _reset(window, observed_at), pool))
    elif mode is False:
        usage = payload.get("usage")
        if not isinstance(usage, dict):
            raise ValueError("missing Factory legacy usage")
        end = usage.get("endDate")
        reset = _reset({"windowEnd": end}, observed_at)
        for pool in ("standard", "premium"):
            value = usage.get(pool)
            if value is None:
                continue
            if not isinstance(value, dict):
                raise ValueError("invalid Factory legacy pool")
            if value.get("usedRatio") is not None:
                used = _number(value["usedRatio"]) * 100
            else:
                total = _number(value.get("totalAllowance"))
                if total <= 0:
                    raise ValueError("invalid Factory allowance")
                used = _number(value.get("orgTotalTokensUsed")) / total * 100
            lanes.append(_lane(f"{pool}-billing", f"{pool.title()} billing period", used,
                               reset, f"organization-{pool}", "factory-subscription-usage"))
        if not lanes:
            raise ValueError("missing Factory legacy pools")
    else:
        raise ValueError("missing Factory billing mode")
    discriminator, plan = _identity(auth)
    return _snapshot("factory", observed_at=observed_at, lanes=tuple(lanes),
                     account_plan=plan, account_discriminator=discriminator)


def _factory_headers(secret):
    return {"Authorization": f"Bearer {secret}", "Accept": "application/json",
            "Content-Type": "application/json", "Origin": "https://app.factory.ai",
            "Referer": "https://app.factory.ai/", "x-factory-client": "web-app"}


def _billing_usage(auth, headers, *, observed_at, http_json):
    if not isinstance(auth, dict):
        raise ValueError("invalid auth response")
    payload = http_json("GET", f"{_BASE}/billing/limits", headers=headers)
    if isinstance(payload, dict) and payload.get("usesTokenRateLimitsBilling") is False:
        query = {"useCache": "true"}
        user = auth.get("userProfile")
        user_id = _text(user.get("id")) if isinstance(user, dict) else None
        if user_id is not None:
            query["userId"] = user_id
        legacy = http_json("GET", f"{_BASE}/organization/subscription/usage?{urlencode(query)}", headers=headers)
        if not isinstance(legacy, dict):
            raise ValueError("invalid legacy response")
        payload = {**legacy, "usesTokenRateLimitsBilling": False}
    return parse_factory_usage(payload, observed_at=observed_at, auth=auth)


def validate_factory_api_key(secret, *, http_json=None):
    """Probe only the supplied key after the person's explicit Save action."""
    from .core_server import CommandError

    http_json = http_json or _default_http_json
    headers = _factory_headers(secret)
    try:
        auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
        auth = _authenticated_identity(auth, secret)
        if _identity(auth)[0] is None:
            raise ValueError("missing account identity")
        _billing_usage(auth, headers, observed_at=time.time(), http_json=http_json)
    except ProviderHttpError as error:
        code = {401: "authentication_required", 403: "usage_access_denied",
                429: "rate_limited"}.get(error.status, "network_unavailable")
        if error.reason in {"invalid_json", "response_too_large"}:
            code = "invalid_response"
        raise CommandError(code, "Factory key could not be validated") from None
    except (ValueError, TypeError, OverflowError):
        raise CommandError("invalid_response", "Factory returned an unreadable usage response") from None
    except Exception:
        raise CommandError("network_unavailable", "Factory could not be reached") from None


def collect_factory(preference, *, observed_at, credentials, http_json=_default_http_json, _fallback_attempted=False) -> ProviderUsageSnapshot:
    """Serialize one instance's token rotation and account reading."""
    from .factory_refresh import collection_lock

    instance = getattr(preference, "source_instance_id", "default")
    with collection_lock(instance):
        return _collect_factory(preference, observed_at=observed_at, credentials=credentials,
                                http_json=http_json, _fallback_attempted=_fallback_attempted)


def _collect_factory(preference, *, observed_at, credentials, http_json, _fallback_attempted):
    from .factory_refresh import (
        FactoryCredentialUnavailable,
        FactoryRenewalFailure,
        FactoryRenewalRejected,
        FactorySessionChanged,
        access_expired,
        renew,
    )
    def failure(state, reason, action):
        result = failure_snapshot("factory", observed_at=observed_at, state=state,
                                  reason=reason, action=action)
        return replace(result, source_instance_id=getattr(preference, "source_instance_id", "default"),
                       account_discriminator=_identity(auth)[0])

    auth = None
    if not preference.enabled:
        return failure(ProviderSourceState.DISABLED, "disabled", "Enable Factory usage")
    if not preference.usage_consented:
        return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Factory usage")
    from .factory_session import (
        SESSION_LOCK,
        background_repair_allowed,
        decode_session,
        fingerprint,
        read_browser_session,
        save_if_current,
    )
    session = None
    session_fingerprint = None
    key = _credential(credentials, "factory", "api-key")
    if key.available and any(ord(char) < 32 or ord(char) == 127 for char in key.secret):
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Add Factory API key")
    if not key.available:
        try:
            with SESSION_LOCK:
                web = credentials.get("factory", "web-session")
        except Exception:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_unavailable", "Reconnect Factory browser session")
        if web.available:
            try:
                session = decode_session(web.secret)
                session_fingerprint = fingerprint(web.secret)
            except ValueError:
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "invalid_web_session", "Reconnect Factory browser session")
        elif getattr(web, "reason", None) not in {None, "credential_not_found"}:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_unavailable", "Reconnect Factory browser session")
        if session is None:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Add Factory API key")
        if not session.get("access_token") and session["consent_version"] != 2:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "browser_token_unavailable", "Add Factory API key")
    headers = _factory_headers(session.get("access_token", "") if session is not None else key.secret)
    try:
        if session is not None:
            may_read_browser = session["consent_version"] == 1 and background_repair_allowed(
                session, source_instance_id=getattr(preference, "source_instance_id", "default")
            )

            def sync_browser_access():
                if not may_read_browser:
                    return False
                try:
                    current = read_browser_session(session["browser"], session["profile"], include_organization=False)
                except (OSError, ValueError, BrowserSessionReadError):
                    return False
                if current is None or not current.get("access_token"):
                    return False
                changed = current["access_token"] != session.get("access_token")
                session["access_token"] = current["access_token"]
                headers["Authorization"] = "Bearer " + session["access_token"]
                return changed

            renewed = _fallback_attempted
            if not renewed and session["consent_version"] == 2 and access_expired(session.get("access_token"), observed_at):
                session, session_fingerprint = renew(session, session_fingerprint, credentials, http_json, now=observed_at,
                    source_instance_id=getattr(preference, "source_instance_id", "default"))
                headers["Authorization"] = "Bearer " + session["access_token"]
                renewed = True
            else:
                sync_browser_access()
            try:
                auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            except ProviderHttpError as error:
                if error.status != 401:
                    raise
                if session["consent_version"] == 2 and not renewed:
                    session, session_fingerprint = renew(session, session_fingerprint, credentials, http_json, now=observed_at,
                    source_instance_id=getattr(preference, "source_instance_id", "default"))
                    headers["Authorization"] = "Bearer " + session["access_token"]
                    renewed = True
                elif not sync_browser_access():
                    raise
                auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            auth = _authenticated_identity(auth, session.get("access_token"))
            identity = _identity(auth)[0]
            org = _text(auth.get("organization", {}).get("id")) if isinstance(auth, dict) and isinstance(auth.get("organization"), dict) else None
            if identity is None or org is None:
                auth = None
                return failure(ProviderSourceState.ERROR, "account_identity_unavailable", "Retry Factory usage")
            # A WorkOS organization (org_…) from the sign-in token is a different
            # namespace from Factory's own; only Factory IDs are comparable here.
            saved_org = session.get("organization_id", org)
            comparable = not (isinstance(saved_org, str) and saved_org.startswith("org_"))
            if (session.get("identity", identity) != identity
                    or (comparable and saved_org != org)):
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_account_changed", "Reconnect Factory browser session")
            session.update(identity=identity, organization_id=org)
            if not save_if_current(credentials, session_fingerprint, session):
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Reconnect Factory browser session")
        else:
            auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            auth = _authenticated_identity(auth, key.secret)
        try:
            result = _billing_usage(auth, headers, observed_at=observed_at, http_json=http_json)
        except ProviderHttpError as error:
            if error.status != 401 or session is None or session["consent_version"] != 2 or renewed or _fallback_attempted:
                raise
            # Start again with auth/me after renewal, never reuse another account's identity.
            encoded = json.dumps(session, separators=(",", ":"), sort_keys=True)
            renew(session, fingerprint(encoded), credentials, http_json, now=observed_at,
                  source_instance_id=getattr(preference, "source_instance_id", "default"))
            return _collect_factory(preference, observed_at=observed_at, credentials=credentials,
                                    http_json=http_json, _fallback_attempted=True)
        if session is not None:
            with SESSION_LOCK:
                current = _credential(credentials, "factory", "web-session")
            expected = fingerprint(json.dumps(session, separators=(",", ":"), sort_keys=True))
            if not current.available or fingerprint(current.secret) != expected:
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Reconnect Factory browser session")
        return replace(result, source_instance_id=getattr(preference, "source_instance_id", "default"))
    except FactoryRenewalRejected as error:
        return failure(ProviderSourceState.NEEDS_SIGN_IN, error.reason, "Reconnect Factory browser session")
    except FactoryRenewalFailure as error:
        state = ProviderSourceState.RATE_LIMITED if error.status == 429 else ProviderSourceState.UNAVAILABLE
        return failure(state, error.reason, "Retry Factory usage")
    except FactoryCredentialUnavailable:
        auth = None
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_unavailable", "Connect Factory")
    except FactorySessionChanged:
        auth = None
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Connect Factory")
    except ProviderHttpError as error:
        if error.status == 401 and session is not None:
            # A key may have been saved while this browser request was in flight.
            if not _fallback_attempted and _credential(credentials, "factory", "api-key").available:
                return collect_factory(preference, observed_at=observed_at, credentials=credentials,
                                       http_json=http_json, _fallback_attempted=True)
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "browser_session_expired", "Reconnect Factory browser session")
        if error.status == 401:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Add Factory API key")
        if error.status == 400:
            return failure(ProviderSourceState.ERROR, "request_rejected", "Retry Factory usage")
        if error.status == 403:
            return failure(ProviderSourceState.UNAVAILABLE, "usage_access_denied", "Reconnect Factory browser session" if session is not None else "Check Factory key access")
        if error.status == 429:
            return failure(ProviderSourceState.RATE_LIMITED, "rate_limited", "Retry later")
        if error.reason in {"invalid_json", "response_too_large"}:
            return failure(ProviderSourceState.ERROR, "invalid_response", "Retry Factory usage")
        return failure(ProviderSourceState.UNAVAILABLE, "network_unavailable", "Retry Factory usage")
    except (ValueError, TypeError, OverflowError):
        return failure(ProviderSourceState.ERROR, "invalid_response", "Retry Factory usage")
    except Exception:
        return failure(ProviderSourceState.UNAVAILABLE, "network_unavailable", "Retry Factory usage")
