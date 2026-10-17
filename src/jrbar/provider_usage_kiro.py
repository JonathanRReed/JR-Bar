"""Read Kiro's CLI-owned usage API without refreshing or writing credentials.

Protocol studied in CodexBar, MIT, commit
6480977b47f6e4ffd5dcaae1cb0c7fdf34ee449e. Independently implemented;
no upstream code is included. Bonus/trial spend is not separable in this
API, so a response with bonuses does not establish a monthly percentage.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sqlite3
import stat
from contextlib import closing
from dataclasses import replace
from pathlib import Path

from .provider_usage_collectors import ProviderHttpError, _default_http_json
from .provider_usage_parsers import _snapshot
from .provider_usage_platform import ProviderSourceState, UsageLane, failure_snapshot

_ENDPOINTS = {"us-east-1": "https://codewhisperer.us-east-1.amazonaws.com/",
              "eu-central-1": "https://q.eu-central-1.amazonaws.com/"}
_SOURCE = "kiro-cli-api"
_MAX_IDENTITY_BYTES = 65536


class _IdentityError(ValueError):
    pass


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TypeError("invalid quota number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ValueError("invalid quota number")
    return number


def _reset(value):
    number = _number(value)
    if not 1_000_000_000 <= number <= 4_102_444_800:
        raise ValueError("invalid reset seconds")
    return number


def _lane(name, label, used, limit, reset):
    return UsageLane("kiro", name, label, max(0, 100 * (1 - used / limit)), reset,
                     "account", None, "coding", True, _SOURCE)


def parse_kiro_usage(payload, *, observed_at):
    """Keep plan and overage credit allowances separate, with reported resets."""
    if not isinstance(payload, dict) or not isinstance(payload.get("usageBreakdownList"), list):
        raise TypeError("missing usage breakdown")
    credits = [row for row in payload["usageBreakdownList"]
               if isinstance(row, dict) and row.get("resourceType") == "CREDIT"]
    if len(credits) != 1:
        raise ValueError("expected one credit breakdown")
    row = credits[0]
    total, used = (_number(row.get(key)) for key in ("usageLimitWithPrecision", "currentUsageWithPrecision"))
    overage_value = row.get("currentOveragesWithPrecision")
    overage = _number(0 if overage_value is None else overage_value)
    if overage > used:
        raise ValueError("overage exceeds usage")
    row_reset = row.get("nextDateReset")
    reset = _reset(payload.get("nextDateReset") if row_reset is None else row_reset)
    bonuses = row.get("bonuses")
    if bonuses is None:
        bonuses = []
    if not isinstance(bonuses, list):
        raise TypeError("invalid bonuses")
    plan_used = used - overage
    if not bonuses and plan_used > total:
        raise ValueError("plan usage exceeds allowance")
    lanes = []
    if total > 0 and not bonuses:
        lanes.append(_lane("monthly", "Monthly credits", plan_used, total, reset))
    configuration = payload.get("overageConfiguration")
    if configuration is None:
        configuration = {}
    if not isinstance(configuration, dict):
        raise TypeError("invalid overage configuration")
    enabled = configuration.get("overageStatus")
    if enabled is not None and not isinstance(enabled, str):
        raise ValueError("invalid overage status")
    if enabled and enabled.upper() == "ENABLED" and row.get("overageCapWithPrecision") is not None:
        cap = _number(row["overageCapWithPrecision"])
        if cap > 0:
            lanes.append(_lane("overage", "Overage credits", overage, cap, reset))
    # Overage cost is not the monthly allowance. Only explicitly USD charges
    # can enter the model's USD field; other currencies stay unconverted.
    currency = row.get("currency")
    if currency is None:
        currency = "USD"
    if not isinstance(currency, str) or re.fullmatch(r"[A-Z]{3}", currency) is None:
        raise ValueError("invalid currency")
    cost = _number(row["overageCharges"]) if row.get("overageCharges") is not None else None
    if row.get("overageRate") is not None:
        _number(row["overageRate"])
    return _snapshot("kiro", observed_at=observed_at, lanes=tuple(lanes),
                     estimated_cost_usd=cost if currency == "USD" else None)


def kiro_database_path(*, home=None, environment=None):
    environment = os.environ if environment is None else environment
    override = environment.get("KIRO_DATA_DIR")
    if override is not None:
        if not isinstance(override, str) or not override.strip():
            raise _IdentityError("invalid CLI directory")
        directory = Path(override.strip()).expanduser()
        if not directory.is_absolute():
            raise _IdentityError("CLI directory must be absolute")
    else:
        directory = (Path.home() if home is None else Path(home)) / "Library/Application Support/kiro-cli"
    return directory / "data.sqlite3"


def _identity(database):
    path = Path(database)
    if not path.is_absolute() or path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise _IdentityError("unsafe CLI database path")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise _IdentityError("CLI database is not a file")
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.25)) as connection:
        connection.set_progress_handler(lambda: 1, 100000)
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        values = []
        for table, key, field in (("auth_kv", "kirocli:odic:token", "access_token"),
                                  ("state", "api.codewhisperer.profile", "arn")):
            rows = connection.execute(
                f"SELECT substr(value, 1, ?) FROM {table} WHERE key = ? LIMIT 2",
                (_MAX_IDENTITY_BYTES + 1, key)).fetchall()
            if len(rows) != 1 or not isinstance(rows[0][0], str) or len(rows[0][0]) > _MAX_IDENTITY_BYTES:
                raise _IdentityError("missing CLI identity")
            data = json.loads(rows[0][0])
            value = data.get(field) if isinstance(data, dict) else None
            if not isinstance(value, str) or not value or len(value) > _MAX_IDENTITY_BYTES:
                raise _IdentityError("invalid CLI identity")
            if any(not 33 <= ord(char) < 127 for char in value):
                raise _IdentityError("invalid CLI identity")
            values.append(value)
    token, arn = values
    parts = arn.split(":", 5)
    if (len(parts) != 6 or parts[:3] != ["arn", "aws", "codewhisperer"]
            or parts[3] not in _ENDPOINTS or not re.fullmatch(r"profile/[A-Za-z0-9._/-]+", parts[5])):
        raise _IdentityError("unsupported profile")
    return token, arn, _ENDPOINTS[parts[3]]


def collect_kiro(preference, *, observed_at, home=None, environment=None, database_path=None,
                 http_json=_default_http_json):
    """Read the default CLI profile only after explicit provider usage consent."""
    instance = preference.source_instance_id

    def failure(state, reason, action="Retry Kiro usage"):
        return replace(failure_snapshot("kiro", observed_at=observed_at, state=state,
                                        reason=reason, action=action), source_instance_id=instance)

    if not preference.enabled:
        return failure(ProviderSourceState.DISABLED, "disabled", "Enable Kiro usage")
    if not preference.usage_consented:
        return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kiro usage")
    if instance != "default":
        return failure(ProviderSourceState.UNSUPPORTED, "cli_default_account_only", "Use the default Kiro CLI account")
    try:
        # Tests must name a synthetic home or database, never resolve real auth.
        if os.environ.get("PYTEST_CURRENT_TEST") and home is None and database_path is None:
            raise _IdentityError("tests need an explicit CLI database")
        database = Path(database_path) if database_path is not None else kiro_database_path(home=home, environment=environment)
        identity = _identity(database)
    except (OSError, ValueError, sqlite3.Error):
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_unavailable", "Run kiro-cli login")
    token, arn, endpoint = identity
    discriminator = "kiro-profile-credential:" + hashlib.sha256(
        json.dumps([arn, token, str(database.resolve())], separators=(",", ":")).encode()).hexdigest()

    def context_error():
        try:
            if _identity(database) != identity:
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_changed", "Run kiro-cli login")
        except (OSError, ValueError, sqlite3.Error):
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_changed", "Run kiro-cli login")
        try:
            if database_path is None and kiro_database_path(home=home, environment=environment) != database:
                return failure(ProviderSourceState.ERROR, "source_changed")
        except (OSError, ValueError):
            return failure(ProviderSourceState.ERROR, "source_changed")
        if preference.source_instance_id != instance:
            return failure(ProviderSourceState.ERROR, "source_changed")
        if not preference.enabled or not preference.usage_consented:
            return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kiro usage")
        return None

    def stable_failure(state, reason, action="Retry Kiro usage"):
        changed = context_error()
        if changed is not None:
            return changed
        return replace(failure(state, reason, action), account_discriminator=discriminator)

    try:
        payload = http_json("POST", endpoint, headers={"Content-Type": "application/x-amz-json-1.0",
            "X-Amz-Target": "AmazonCodeWhispererService.GetUsageLimits", "Authorization": "Bearer " + token},
            body={"profileArn": arn}, timeout=10)
        result = parse_kiro_usage(payload, observed_at=observed_at)
        changed = context_error()
        if changed is not None:
            return changed
        if not result.lanes:
            return failure(ProviderSourceState.UNSUPPORTED, "no_separable_quota",
                           "Kiro does not expose a separable plan allowance")
        return replace(result, source_instance_id=instance, account_discriminator=discriminator)
    except ProviderHttpError as error:
        if error.status in {401, 403}:
            return stable_failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Run kiro-cli login")
        if error.status == 429:
            return stable_failure(ProviderSourceState.RATE_LIMITED, "rate_limited")
        if error.reason in {"invalid_json", "response_too_large"}:
            return stable_failure(ProviderSourceState.ERROR, "invalid_response")
        return stable_failure(ProviderSourceState.UNAVAILABLE, "request_failed")
    except (OSError, sqlite3.Error):
        return stable_failure(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_changed", "Run kiro-cli login")
    except (ValueError, TypeError, OverflowError):
        return stable_failure(ProviderSourceState.ERROR, "invalid_response")
