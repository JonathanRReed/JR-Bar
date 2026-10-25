"""Kimi Code quotas, separate from Moonshot Open Platform balances."""
from __future__ import annotations

import base64
import hashlib
import json
import math
import platform
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from .provider_auth_paths import kimi_code_home
from .provider_usage_collectors import ProviderHttpError, _credential, _default_http_json
from .provider_usage_parsers import _snapshot
from .provider_usage_platform import ProviderSourceState, UsageLane, failure_snapshot


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    return number if math.isfinite(number) and number >= 0 else None


def _count(value):
    if isinstance(value, str):
        try:
            value = int(value)
        except ValueError:
            return None
    number = _number(value)
    return number if number is not None and number.is_integer() else None


def _reset(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        stamp = parsed.timestamp() if parsed.tzinfo else None
        return stamp if stamp is not None and math.isfinite(stamp) and stamp >= 0 else None
    except (ValueError, OverflowError, OSError):
        return None


def _detail(value):
    if not isinstance(value, dict):
        return None
    limit, used, remaining = (_count(value.get(field)) for field in ("limit", "used", "remaining"))
    if limit is None or limit <= 0:
        return None
    if used is None:
        if remaining is None or remaining > limit:
            return None
        used = limit - remaining
    reset = next((value.get(key) for key in ("resetTime", "resetAt", "reset_time", "reset_at")
                  if value.get(key) is not None), None)
    return max(0.0, 100 - used / limit * 100), _reset(reset)


def _minutes(window):
    if not isinstance(window, dict):
        return None
    count = _count(window.get("duration"))
    multiplier = {"TIME_UNIT_MINUTE": 1, "TIME_UNIT_HOUR": 60, "TIME_UNIT_DAY": 1440}.get(window.get("timeUnit"))
    return count * multiplier if count and multiplier else None


def parse_kimi_usage(payload, *, observed_at: float, source_id: str = "kimi-code-api"):
    """Keep reported windows only. Unknown reset clocks remain unknown."""
    if not isinstance(payload, dict):
        raise ValueError("invalid Kimi Code response")
    legacy = {"weekly": _detail(payload.get("usage"))}
    limits = payload.get("limits")
    if isinstance(limits, list):
        for item in limits:
            if isinstance(item, dict) and _minutes(item.get("window")) == 300:
                legacy["five-hour"] = _detail(item.get("detail"))
                break
    pools = payload.get("usages")
    pools = pools if isinstance(pools, dict) else {}
    lanes = []
    for lane_id, label, field in (("five-hour", "5-hour", "limit_5h"),
                                   ("weekly", "Weekly", "limit_7d"),
                                   ("monthly", "Monthly total", "limit_month_total")):
        pool = pools.get(field)
        ratio = _number(pool.get("used_ratio")) if isinstance(pool, dict) else None
        reading = (max(0.0, 100 - min(1.0, ratio) * 100), _reset(pool.get("reset_time"))) if ratio is not None else None
        counted = legacy.get(lane_id)
        if reading is None:
            reading = counted
        elif counted and counted[1] is not None and reading[1] is not None:
            if abs(counted[1] - reading[1]) <= 2 and counted[0] < reading[0]:
                reading = counted
        if reading is not None:
            lanes.append(UsageLane("kimi", lane_id, label, reading[0], reading[1],
                                   "account", None, "coding", True, source_id))
    if not lanes:
        raise ValueError("no observed Kimi Code quota")
    user = payload.get("user")
    member = user.get("membership") if isinstance(user, dict) else None
    level = member.get("level") if isinstance(member, dict) else None
    plan = level.strip() if isinstance(level, str) and 0 < len(level.strip()) <= 200 else None
    if plan == "LEVEL_UNSPECIFIED":
        plan = None
    if payload.get("version") in (None, "GOODS_VERSION_V1"):
        plan = {"LEVEL_FREE": "Adagio", "LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato",
                "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro"}.get(plan, plan)
    return _snapshot("kimi", observed_at=observed_at, lanes=tuple(lanes), account_plan=plan)


def _secret(value):
    return isinstance(value, str) and 0 < len(value) <= 65536 and all(32 <= ord(c) < 127 for c in value)


def _read_local(path, maximum):
    """A bounded read of a regular CLI file, without following symlinks."""
    import os
    import stat
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("invalid CLI file")
        with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as stream:
            result = stream.read(maximum + 1)
        if len(result) > maximum:
            raise ValueError("invalid CLI file")
        return result
    finally:
        os.close(fd)


def _cli(home, now):
    root = kimi_code_home(Path(home))
    if root.is_symlink() or (root / "credentials").is_symlink():
        return None
    try:
        payload = json.loads(_read_local(root / "credentials" / "kimi-code.json", 65536))
        token, expiry = payload.get("access_token"), payload.get("expires_at")
        if isinstance(expiry, str):
            expiry = float(expiry)
        expiry = _number(expiry)
        device = _read_local(root / "device_id", 1024).strip()
        if not _secret(token) or not _secret(device) or expiry is None or expiry <= now + 60:
            return None
        def ascii_header(value):
            return "".join(c if 32 <= ord(c) < 127 else "_" for c in value)[:200]
        version = platform.mac_ver()[0] or platform.release()
        return token, {"User-Agent": "JR-Bar", "X-Msh-Platform": "kimi_code_cli",
                       "X-Msh-Version": "development", "X-Msh-Device-Id": device,
                       "X-Msh-Device-Name": "JR-Bar",
                       "X-Msh-Device-Model": ascii_header(f"{platform.system()} {version} {platform.machine()}"),
                       "X-Msh-Os-Version": ascii_header(version)}
    except (OSError, ValueError, TypeError, AttributeError, UnicodeError):
        return None


def _web_headers(token):
    headers = {}
    parts = token.split(".")
    if len(parts) != 3:
        return headers
    try:
        raw = base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
        claims = json.loads(raw)
        if isinstance(claims, dict):
            for claim, header in (("device_id", "x-msh-device-id"),
                                  ("ssid", "x-msh-session-id"), ("sub", "x-traffic-id")):
                value = claims.get(claim)
                if _secret(value) and len(value) <= 200:
                    headers[header] = value
    except (ValueError, UnicodeError):
        pass
    return headers


def collect_kimi(preference, *, observed_at: float, credentials, http_json=_default_http_json, home=None):
    """Read consented Code API, saved web token, or the default China CLI session."""
    instance = getattr(preference, "source_instance_id", "default")
    option = getattr(preference, "option", lambda name: None)
    region, source = option("region") or "china", option("source") or "auto"

    def failure(state, reason, action):
        return replace(failure_snapshot("kimi", observed_at=observed_at, state=state, reason=reason, action=action),
                       source_instance_id=instance)

    if not preference.enabled:
        return failure(ProviderSourceState.DISABLED, "disabled", "Enable Kimi Code usage")
    if not preference.usage_consented:
        return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kimi Code usage")
    if region not in {"china", "international"} or source not in {"auto", "api", "web", "cli"}:
        return failure(ProviderSourceState.ERROR, "invalid_configuration", "Check Kimi Code source")
    token, identity_headers, selected = None, {}, source
    cli_identity = None
    if source in {"auto", "api"}:
        key = _credential(credentials, "kimi", "api-key")
        if key.available:
            token, selected = key.secret, "api"
    if token is None and source in {"auto", "web"}:
        web = _credential(credentials, "kimi", "web-session")
        if web.available:
            token, selected = web.secret, "web"
    if token is None and source in {"auto", "cli"} and instance == "default" and region == "china":
        cli = _cli(Path.home() if home is None else home, observed_at)
        if cli:
            cli_identity = cli
            token, identity_headers = cli
            selected = "cli"
    if not _secret(token):
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Connect Kimi Code")
    # This is credential provenance, not a provider-verified account ID.
    identity = hashlib.sha256(f"{region}\0{selected}\0{token}".encode()).hexdigest()
    discriminator = "kimi:credential:" + identity

    def context_error():
        if not preference.enabled:
            return failure(ProviderSourceState.DISABLED, "disabled", "Enable Kimi Code usage")
        if not preference.usage_consented:
            return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kimi Code usage")
        current_option = getattr(preference, "option", lambda name: None)
        if (getattr(preference, "source_instance_id", "default"),
                current_option("region") or "china", current_option("source") or "auto") != (instance, region, source):
            return failure(ProviderSourceState.ERROR, "source_changed", "Check Kimi Code source")
        if source == "auto" and selected != "api" and _credential(credentials, "kimi", "api-key").available:
            return failure(ProviderSourceState.ERROR, "source_changed", "Check Kimi Code source")
        if source == "auto" and selected == "cli" and _credential(credentials, "kimi", "web-session").available:
            return failure(ProviderSourceState.ERROR, "source_changed", "Check Kimi Code source")
        if selected in {"api", "web"}:
            current = _credential(credentials, "kimi", "api-key" if selected == "api" else "web-session")
            if not current.available or current.secret != token:
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "credential_changed", "Reconnect Kimi Code")
        elif _cli(Path.home() if home is None else home, observed_at) != cli_identity:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "credential_changed", "Run kimi login")
        return None

    def stable_failure(state, reason, action):
        changed = context_error()
        if changed is not None:
            return changed
        return replace(failure(state, reason, action), account_discriminator=discriminator)

    suffix = "com" if region == "china" else "ai"
    headers = {"Accept": "application/json", "Authorization": "Bearer " + token, **identity_headers}
    try:
        if selected == "web":
            origin = f"https://www.kimi.{suffix}"
            headers.update({"Content-Type": "application/json", "Cookie": "kimi-auth=" + token,
                            "Origin": origin, "Referer": origin + "/code/console",
                            "connect-protocol-version": "1", "x-msh-platform": "web",
                            "x-language": "en-US", "Accept-Language": "en-US,en;q=0.9",
                            **_web_headers(token)})
            payload = http_json("POST", origin + "/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages",
                                headers=headers, body={"scope": ["FEATURE_CODING"]})
            usages = payload.get("usages") if isinstance(payload, dict) else None
            coding = next((item for item in usages if isinstance(item, dict) and item.get("scope") == "FEATURE_CODING"), None) if isinstance(usages, list) else None
            if coding is None:
                raise ValueError("missing coding quota")
            payload = {"usage": coding.get("detail"), "limits": coding.get("limits")}
        else:
            payload = http_json("GET", f"https://api.kimi.{suffix}/coding/v1/usages", headers=headers)
        changed = context_error()
        if changed is not None:
            return changed
        result = parse_kimi_usage(payload, observed_at=observed_at,
                                  source_id="kimi-code-web" if selected == "web" else "kimi-code-api")
        return replace(result, source_instance_id=instance, account_discriminator=discriminator)
    except ProviderHttpError as error:
        if error.status in {401, 403}:
            changed = context_error()
            if changed is not None:
                return changed
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Reconnect Kimi Code")
        if error.status == 429:
            return stable_failure(ProviderSourceState.RATE_LIMITED, "rate_limited", "Retry later")
        if error.reason in {"invalid_json", "response_too_large"}:
            return stable_failure(ProviderSourceState.ERROR, "invalid_response", "Retry Kimi Code usage")
        return stable_failure(ProviderSourceState.UNAVAILABLE, "network_unavailable", "Retry Kimi Code usage")
    except (ValueError, TypeError, OverflowError):
        return stable_failure(ProviderSourceState.ERROR, "invalid_response", "Retry Kimi Code usage")
