"""Factory billing windows from an explicitly connected credential."""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import replace
from datetime import datetime
from urllib.parse import urlencode

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


def collect_factory(preference, *, observed_at, credentials, http_json=_default_http_json) -> ProviderUsageSnapshot:
    """Read only the connected profile after its usage consent is enabled."""
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
    from .factory_session import SESSION_LOCK, WORKOS_CLIENT_IDS, decode_session, fingerprint, save_if_current
    session = None
    session_fingerprint = None
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
    key = _credential(credentials, "factory", "api-key") if session is None else None
    if session is None and (not key.available or any(ord(char) < 32 or ord(char) == 127 for char in key.secret or "")):
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Connect Factory browser session")
    headers = {"Authorization": f"Bearer {session.get('access_token', '') if session is not None else key.secret}", "Accept": "application/json",
               "Content-Type": "application/json", "Origin": "https://app.factory.ai",
               "Referer": "https://app.factory.ai/", "x-factory-client": "web-app"}
    try:
        if session is not None:
            refreshed = False

            def renew():
                nonlocal session_fingerprint
                preferred = session.get("client_id", WORKOS_CLIENT_IDS[0])
                clients = (preferred, *(client for client in WORKOS_CLIENT_IDS if client != preferred))
                for index, client_id in enumerate(clients):
                    try:
                        response = http_json("POST", "https://api.workos.com/user_management/authenticate",
                            headers={"Accept": "application/json", "Content-Type": "application/json"},
                            body={"client_id": client_id, "grant_type": "refresh_token",
                                  "refresh_token": session["refresh_token"],
                                  **({"organization_id": session["organization_id"]} if session.get("organization_id") else {})})
                        break
                    except ProviderHttpError as error:
                        if error.status not in {400, 401} or index == len(clients) - 1:
                            raise
                if not isinstance(response, dict):
                    raise ValueError("invalid refresh response")
                candidate = {**session, "access_token": response.get("access_token"), "client_id": client_id}
                if response.get("refresh_token") is not None:
                    candidate["refresh_token"] = response["refresh_token"]
                decode_session(json.dumps(candidate))
                if not save_if_current(credentials, session_fingerprint, candidate):
                    raise ProviderHttpError(401, "web_session_changed")
                session_fingerprint = fingerprint(json.dumps(candidate, separators=(",", ":"), sort_keys=True))
                session.update(candidate)
                headers["Authorization"] = "Bearer " + session["access_token"]

            if not session.get("access_token"):
                renew()
                refreshed = True
            try:
                auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            except ProviderHttpError as error:
                if error.status != 401 or refreshed:
                    raise
                renew()
                refreshed = True
                auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            auth = _authenticated_identity(auth, session.get("access_token"))
            identity = _identity(auth)[0]
            org = _text(auth.get("organization", {}).get("id")) if isinstance(auth, dict) and isinstance(auth.get("organization"), dict) else None
            if identity is None or org is None:
                auth = None
                return failure(ProviderSourceState.ERROR, "account_identity_unavailable", "Retry Factory usage")
            if (session.get("identity", identity) != identity
                    or session.get("organization_id", org) != org):
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_account_changed", "Reconnect Factory browser session")
            session.update(identity=identity, organization_id=org)
            if not save_if_current(credentials, session_fingerprint, session):
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Reconnect Factory browser session")
        else:
            auth = http_json("GET", f"{_BASE}/app/auth/me", headers=headers)
            auth = _authenticated_identity(auth, key.secret)
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
        result = parse_factory_usage(payload, observed_at=observed_at, auth=auth)
        if session is not None:
            with SESSION_LOCK:
                current = _credential(credentials, "factory", "web-session")
            expected = fingerprint(json.dumps(session, separators=(",", ":"), sort_keys=True))
            if not current.available or fingerprint(current.secret) != expected:
                auth = None
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Reconnect Factory browser session")
        return replace(result, source_instance_id=getattr(preference, "source_instance_id", "default"))
    except ProviderHttpError as error:
        if error.status == 401 or (session is not None and error.status == 400):
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required",
                           "Reconnect Factory browser session" if session is not None else "Add Factory API key")
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
