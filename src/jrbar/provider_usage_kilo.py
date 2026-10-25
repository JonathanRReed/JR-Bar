"""Read Kilo credits with CLI auth or an explicitly stored API key."""
from __future__ import annotations

import hashlib
import json
import math
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

from .provider_auth_paths import kilo_auth_path
from .provider_usage_collectors import ProviderHttpError, _credential, _default_http_json
from .provider_usage_parsers import _snapshot
from .provider_usage_platform import ProviderSourceState, UsageLane, failure_snapshot

_PROCEDURES = ("user.getCreditBlocks", "kiloPass.getState", "user.getAutoTopUpPaymentMethod")
_URL = "https://app.kilo.ai/api/trpc/" + ",".join(_PROCEDURES) + "?" + urlencode({
    "batch": "1", "input": json.dumps({str(i): {"json": None} for i in range(3)}, separators=(",", ":"))})


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (float, int, str)):
        raise ValueError("invalid Kilo number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ValueError("invalid Kilo number")
    return number


def _payload(entry):
    if not isinstance(entry, dict):
        raise ValueError("invalid Kilo entry")
    if "error" in entry:
        error = entry["error"]
        error = error.get("json", error) if isinstance(error, dict) else {}
        data = error.get("data", {}) if isinstance(error, dict) else {}
        code = str(data.get("code", error.get("code", ""))).lower() if isinstance(data, dict) else ""
        if code in {"unauthorized", "forbidden"}:
            raise ProviderHttpError(401, "authentication_required")
        raise ValueError("Kilo procedure failed")
    result = entry.get("result")
    if not isinstance(result, dict):
        raise ValueError("missing Kilo result")
    data = result.get("data", result)
    return data.get("json", data) if isinstance(data, dict) else data


def _lane(name, label, total, used, reset=None):
    remaining = 0 if total == 0 else max(0, min(100, 100 * (1 - used / total)))
    return UsageLane("kilo", name, label, remaining, reset, "account", None, None, True, "kilo-api")


def _reset(value):
    if value is None:
        return None
    if isinstance(value, str) and not value.replace(".", "", 1).isdigit():
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Kilo reset requires timezone")
        return _number(parsed.timestamp())
    epoch = _number(value)
    return epoch / 1000 if epoch > 10000000000 else epoch



def _contexts(payload):
    """Visit only named Kilo billing containers, at most two levels deep."""
    if not isinstance(payload, dict):
        return []
    contexts = [payload]
    frontier = [payload]
    for _ in range(2):
        next_level = []
        for context in frontier:
            for key in ("data", "credits", "creditBalance", "pass", "state", "subscription", "plan", "usage"):
                value = context.get(key)
                if isinstance(value, dict):
                    next_level.append(value)
        contexts.extend(next_level)
        frontier = next_level
    return contexts


def _first(contexts, keys):
    for context in contexts:
        for key in keys:
            if context.get(key) is not None:
                return _number(context[key])
    return None


def _money(contexts, cents, micro, plain):
    for keys, divisor in ((cents, 100), (micro, 1000000), (plain, 1)):
        value = _first(contexts, keys.split())
        if value is not None:
            return value / divisor
    return None


def _complete(total, used, remaining):
    if total is None and used is not None and remaining is not None:
        total = used + remaining
    if used is None and total is not None and remaining is not None:
        used = max(0, total - remaining)
    if remaining is None and total is not None and used is not None:
        remaining = max(0, total - used)
    if any(value is not None and not math.isfinite(value) for value in (total, used, remaining)):
        raise ValueError("Kilo allowance overflow")
    return total, used, remaining


def _generic_pass(payload):
    contexts = _contexts(payload)
    total = _money(contexts, "amountCents totalCents planAmountCents monthlyAmountCents limitCents includedCents valueCents",
        "amount_mUsd total_mUsd planAmount_mUsd limit_mUsd included_mUsd value_mUsd",
        "amount total limit included value creditsTotal totalCredits planAmount")
    used = _money(contexts, "usedCents spentCents consumedCents usedAmountCents consumedAmountCents",
        "used_mUsd spent_mUsd consumed_mUsd usedAmount_mUsd",
        "used spent consumed usage creditsUsed usedAmount consumedAmount")
    remaining = _money(contexts, "remainingCents remainingAmountCents availableCents leftCents balanceCents",
        "remaining_mUsd available_mUsd left_mUsd balance_mUsd",
        "remaining available left balance creditsRemaining remainingAmount availableAmount")
    # Validate stated bonus values even though only the stated total defines this allowance.
    _money(contexts, "bonusCents bonusAmountCents includedBonusCents bonusRemainingCents",
        "bonus_mUsd bonusAmount_mUsd", "bonus bonusAmount bonusCredits includedBonus")
    total, used, remaining = _complete(total, used, remaining)
    reset = next((context[key] for context in contexts for key in (
        "resetAt", "resetsAt", "nextResetAt", "renewAt", "renewsAt", "nextRenewalAt",
        "currentPeriodEnd", "periodEndsAt", "expiresAt", "expiryAt") if context.get(key) is not None), None)
    plan = next((context[key].strip() for context in contexts for key in (
        "planName", "tier", "tierName", "passName", "subscriptionName")
        if isinstance(context.get(key), str) and context[key].strip() and len(context[key]) <= 200), None)
    if plan is None and isinstance(payload, dict):
        for path in (("plan", "name"), ("subscription", "plan", "name"), ("subscription", "name"),
                     ("pass", "name"), ("state", "name"), ("state",)):
            value = payload
            for key in path:
                value = value.get(key) if isinstance(value, dict) else None
            if isinstance(value, str) and value.strip() and len(value) <= 200:
                plan = value.strip()
                break
    return total, used, reset, plan

def parse_kilo_usage(payload, *, observed_at):
    """Keep balances separate from allowances and use only stated resets."""
    if isinstance(payload, dict):
        entries = [payload.get(str(i)) for i in range(3)]
    elif isinstance(payload, list) and 2 <= len(payload) <= 3:
        entries = payload
    else:
        raise ValueError("invalid Kilo batch")
    credits, passes = _payload(entries[0]), _payload(entries[1])
    if not isinstance(credits, dict):
        raise ValueError("missing Kilo credits")
    lanes = []
    remaining = None
    contexts = _contexts(credits)
    blocks = next((context["creditBlocks"] for context in contexts if "creditBlocks" in context), None)
    if blocks is not None:
        if not isinstance(blocks, list):
            raise ValueError("invalid Kilo blocks")
        if blocks:
            if not all(isinstance(block, dict) for block in blocks):
                raise ValueError("invalid Kilo block")
            balances = [block.get("balance_mUsd") for block in blocks]
            totals = [block.get("amount_mUsd") for block in blocks]
            for value in balances + totals:
                if value is not None:
                    _number(value)
            if all(value is not None for value in balances):
                remaining = sum(_number(value) / 1000000 for value in balances)
            if all(value is not None for value in totals) and remaining is not None:
                total = sum(_number(value) / 1000000 for value in totals)
                if not math.isfinite(total) or not math.isfinite(remaining):
                    raise ValueError("Kilo credit overflow")
                lanes.append(_lane("credits", "Credits", total, max(0, total - remaining)))
    if not lanes:
        generic_blocks = next((context["blocks"] for context in contexts if "blocks" in context), [])
        if not isinstance(generic_blocks, list) or not all(isinstance(block, dict) for block in generic_blocks):
            raise ValueError("invalid Kilo generic blocks")
        if generic_blocks:
            # Each listed block must describe the same credit unit and a complete
            # allowance. A partial list must never look like the account total.
            values = []
            if any(not isinstance(block.get(key), (str, type(None)))
                   for block in generic_blocks for key in ("unit", "currency")):
                raise ValueError("invalid Kilo credit units")
            units = {(block.get("unit"), block.get("currency")) for block in generic_blocks}
            if len(units) != 1:
                raise ValueError("incompatible Kilo credit units")
            for block in generic_blocks:
                if any(key.endswith(("Cents", "_mUsd")) for key in block):
                    raise ValueError("unsupported Kilo credit units")
                block_used = _first([block], "used usedCredits consumed spent creditsUsed".split())
                block_total = _first([block], "total totalCredits creditsTotal limit".split())
                block_remaining = _first([block], "remaining remainingCredits creditsRemaining".split())
                complete = _complete(block_total, block_used, block_remaining)
                if any(value is None for value in complete):
                    raise ValueError("incomplete Kilo credit block")
                values.append(complete)
            total, used, generic_remaining = (sum(parts) for parts in zip(*values))
        else:
            used = _first(contexts, "used usedCredits consumed spent creditsUsed".split())
            total = _first(contexts, "total totalCredits creditsTotal limit".split())
            generic_remaining = _first(contexts, "remaining remainingCredits creditsRemaining".split())
        total, used, generic_remaining = _complete(total, used, generic_remaining)
        if remaining is None:
            remaining = generic_remaining
        if total is not None and used is not None:
            lanes.append(_lane("credits", "Credits", total, used))
    if remaining is None and credits.get("totalBalance_mUsd") is not None:
        remaining = _number(credits["totalBalance_mUsd"]) / 1000000
    if remaining is None and not lanes:
        raise ValueError("missing Kilo balance")
    plan = None
    if isinstance(passes, dict):
        subscription = passes.get("subscription")
        if subscription is None and any(key in passes for key in ("currentPeriodUsageUsd", "currentPeriodBaseCreditsUsd", "currentPeriodBonusCreditsUsd", "tier")):
            subscription = passes
        if isinstance(subscription, dict):
            tier = subscription.get("tier")
            if isinstance(tier, str) and tier.strip() and len(tier) <= 200:
                plan = tier.strip()
            used, base = subscription.get("currentPeriodUsageUsd"), subscription.get("currentPeriodBaseCreditsUsd")
            if used is not None and base is not None:
                total = _number(base) + _number(subscription.get("currentPeriodBonusCreditsUsd", 0))
                if not math.isfinite(total):
                    raise ValueError("Kilo pass overflow")
                reset = next((subscription[key] for key in ("nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt") if subscription.get(key) is not None), None)
                lanes.append(_lane("pass", "Kilo Pass", total, _number(used), _reset(reset)))
        else:
            total, used, reset, plan = _generic_pass(passes)
            if total is not None and used is not None:
                lanes.append(_lane("pass", "Kilo Pass", total, used, _reset(reset)))
    elif passes is not None:
        raise ValueError("invalid Kilo pass")
    return _snapshot("kilo", observed_at=observed_at, lanes=tuple(lanes), credits_remaining=remaining, account_plan=plan)


def _cli_token(home):
    path = kilo_auth_path(home)
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
            return None
        with path.open("rb") as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            return None
        value = json.loads(raw).get("kilo", {}).get("access")
        return _token(value)
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def _token(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or len(value) > 65536 or any(ord(char) < 32 or ord(char) == 127 for char in value):
        return None
    return value


def collect_kilo(preference, *, observed_at, credentials, home=None, http_json=_default_http_json):
    """Read the personal account after consent, without refreshing credentials."""
    source_instance_id = preference.source_instance_id

    def failure(state, reason, action="Retry Kilo usage"):
        return replace(failure_snapshot("kilo", observed_at=observed_at, state=state,
            reason=reason, action=action), source_instance_id=source_instance_id)
    if not preference.enabled:
        return failure(ProviderSourceState.DISABLED, "disabled", "Enable Kilo usage")
    if not preference.usage_consented:
        return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kilo usage")
    # Named source instances use their own stored credential, never the default CLI account.
    token = _cli_token(Path.home() if home is None else Path(home)) if preference.source_instance_id == "default" else None
    initial_source = (preference.source_instance_id, tuple(getattr(preference, "options", ())))
    cli_token = token
    if token is None:
        key = _credential(credentials, "kilo", "api-key")
        token = _token(key.secret) if key.available else None
    if token is None:
        return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Run kilo auth login or add Kilo API key")
    try:
        options = dict(initial_source[1])
        organization = options.get("organization_id")
        headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if organization is not None:
            if not isinstance(organization, str) or not organization.strip() or len(organization) > 200 or any(ord(char) < 32 or ord(char) == 127 for char in organization):
                raise ValueError("invalid Kilo organization")
            headers["X-KILOCODE-ORGANIZATIONID"] = organization.strip()
    except (ValueError, TypeError):
        return failure(ProviderSourceState.ERROR, "invalid_response")
    provenance = json.dumps(["kilo", "cli" if cli_token else "api-key", initial_source[0], organization, token], separators=(",", ":"))
    discriminator = "kilo-provenance:" + hashlib.sha256(provenance.encode()).hexdigest()

    def context_error():
        if not preference.enabled:
            return failure(ProviderSourceState.DISABLED, "disabled", "Enable Kilo usage")
        if not preference.usage_consented:
            return failure(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kilo usage")
        if initial_source != (preference.source_instance_id, tuple(getattr(preference, "options", ()))):
            return failure(ProviderSourceState.ERROR, "source_changed")
        current_cli = (_cli_token(Path.home() if home is None else Path(home))
                       if source_instance_id == "default" else None)
        if cli_token is None:
            if current_cli is not None:
                return failure(ProviderSourceState.ERROR, "source_changed")
            current = _credential(credentials, "kilo", "api-key")
            if not current.available or _token(current.secret) != token:
                return failure(ProviderSourceState.NEEDS_SIGN_IN, "credential_changed", "Update Kilo API key")
        elif current_cli != cli_token:
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_changed", "Run kilo auth login")
        return None

    def stable_failure(state, reason, action="Retry Kilo usage"):
        changed = context_error()
        if changed is not None:
            return changed
        return replace(failure(state, reason, action), account_discriminator=discriminator)

    try:
        result = parse_kilo_usage(http_json("GET", _URL, headers=headers), observed_at=observed_at)
        if organization is not None:
            result = replace(result, lanes=tuple(replace(lane, scope="organization") for lane in result.lanes))
        changed = context_error()
        if changed is not None:
            return changed
        return replace(result, source_instance_id=preference.source_instance_id, account_discriminator=discriminator)
    except ProviderHttpError as error:
        if error.status in {401, 403}:
            changed = context_error()
            if changed is not None:
                return changed
            return failure(ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Run kilo auth login or update Kilo API key")
        if error.status == 429:
            return stable_failure(ProviderSourceState.RATE_LIMITED, "rate_limited", "Retry later")
        if error.reason in {"invalid_json", "response_too_large"}:
            return stable_failure(ProviderSourceState.ERROR, "invalid_response")
        return stable_failure(ProviderSourceState.UNAVAILABLE, "network_unavailable")
    except (ValueError, TypeError, OverflowError):
        return stable_failure(ProviderSourceState.ERROR, "invalid_response")
    except Exception:
        return stable_failure(ProviderSourceState.UNAVAILABLE, "network_unavailable")
