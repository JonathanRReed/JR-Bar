"""Native Codex and Claude quota plus local token accounting."""

from __future__ import annotations

import dataclasses
import hashlib
import math
import sys
import threading
from collections.abc import Callable, Iterable
from dataclasses import replace
from pathlib import Path

from .provider_usage_parsers import parse_claude_usage, parse_codex_usage
from .provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
)
from .provider_usage_platform import failure_snapshot as _failure
from .provider_usage_settings import ProviderPreference


def _credential(credentials, provider_id: str, account: str) -> str | None:
    try:
        result = credentials.get(provider_id, account)
    except Exception:
        return None
    value = getattr(result, "secret", None)
    if not getattr(result, "available", False) or not isinstance(value, str):
        return None
    value = value.strip()
    if not value or "\x00" in value or len(value.encode("utf-8")) > 64 * 1024:
        return None
    return value


#: How long one quota refresh may spend reading transcripts when no earlier
#: scan has left totals in a cache. A very large history is read over several
#: refreshes (each continues from where the last stopped) instead of holding
#: one provider fetch for minutes; the token figures are a floor until then.
LOCAL_SCAN_PASS_SECONDS = 8.0


def _default_provider_local_scan(
    provider_id: str,
    home: Path,
    observed_at: float,
    *,
    read_account: bool = True,
) -> dict[str, object] | None:
    """Use JR-Bar's bounded transcript scanner for exactly one provider.

    ``read_account`` false skips Codex's ``auth.json``, the only sign-in this
    scan would otherwise read for the account label.
    """
    try:
        from . import usage_stats
        from .providers import negotiated_provider_sources
    except ImportError:
        return None
    source = next(
        (
            item
            for item in negotiated_provider_sources()
            if item.source_key.provider_id == provider_id
            and item.source_key.capability_id == "transcript_usage"
            and item.observation_invocation_allowed
        ),
        None,
    )
    if source is None:
        return None
    from .provider_homes import (
        _home_cache_path,
        configured_extra_homes,
        extra_scan_roots,
        primary_claude_projects,
        primary_codex_sessions,
    )

    # CODEX_HOME / CLAUDE_CONFIG_DIR first, then ~/.codex or ~/.claude.
    root = (
        primary_codex_sessions(home=home)
        if provider_id == "codex"
        else primary_claude_projects(home=home)
    )
    cache = Path(home) / ".local" / "state" / "jrbar" / "provider-usage-cache.json"
    # The period the Usage Center's token figures cover: today and the 29
    # local days before it. Both card paths (this scan and the cache reader)
    # take it from the same place, so they cannot drift apart.
    since = usage_stats.card_window_start(observed_at)
    try:
        result, totals = usage_stats._scan_provider_usage_with_totals(
            source,
            root,
            cache,
            since_epoch=since,
            now=observed_at,
            budget=usage_stats.ScanBudget(LOCAL_SCAN_PASS_SECONDS),
        )
        # Token totals count every home of this provider (provider_extra_homes),
        # each real folder once; the quota evidence stays the primary account's.
        extras = extra_scan_roots(
            provider_id,
            home=home,
            extras=configured_extra_homes().get(provider_id, ()),
        )
        if extras:
            parts = [totals]
            for extra in extras:
                _extra_result, extra_totals = usage_stats._scan_provider_usage_with_totals(
                    source,
                    extra,
                    _home_cache_path(cache, extra),
                    since_epoch=since,
                    now=observed_at,
                    budget=usage_stats.ScanBudget(LOCAL_SCAN_PASS_SECONDS),
                )
                parts.append(extra_totals)
            merged = usage_stats._merge_usage_totals(tuple(parts))
            merged.codex_rate_limit_evidence = totals.codex_rate_limit_evidence
            merged.codex_rate_limit_observed_at = totals.codex_rate_limit_observed_at
            totals = merged
            result = usage_stats._provider_result(source.source_key, totals)
    except Exception:
        return None
    records = tuple(
        record for record in getattr(totals, "records", ()) if record[0] == provider_id
    )
    document: dict[str, object] = {
        "input_tokens": int(getattr(result, "input_tokens", 0)),
        "cached_input_tokens": int(getattr(result, "cached_input_tokens", 0)),
        "output_tokens": int(getattr(result, "output_tokens", 0)),
        "model_count": len(
            {usage_stats.base_model_key(record[2]) for record in records if len(record) > 2}
        ),
        "estimated_cost_usd": getattr(result, "covered_cost_estimate_usd", None),
        "cache_savings_usd": getattr(
            result,
            "covered_cache_savings_estimate_usd",
            None,
        ),
    }
    if provider_id == "codex":
        document["windows_observed_at"] = getattr(
            totals, "codex_rate_limit_observed_at", None
        )
        document["windows"] = [
            dict(window)
            for window in tuple(getattr(totals, "codex_rate_limit_evidence", ()))[:64]
            if isinstance(window, dict)
        ]
        if read_account:
            try:
                from .credentials import read_codex_tokens

                tokens = read_codex_tokens(Path(home) / ".codex" / "auth.json")
            except Exception:
                tokens = None
            if tokens is not None and getattr(tokens, "account_id", None):
                document["account_label"] = str(tokens.account_id)
    return document


def _default_codex_local_scan(home: Path, observed_at: float) -> dict[str, object] | None:
    cached = _cached_codex_local_scan(home, observed_at)
    if isinstance(cached, dict):
        return cached
    return _default_provider_local_scan("codex", home, observed_at)


def _default_claude_local_scan(home: Path, observed_at: float) -> dict[str, object] | None:
    # Quota is the time-sensitive value on this plane. The Profile graph owns
    # cold transcript scans on demand, so an automatic quota refresh may use
    # the last bounded local aggregate but must never walk the full Claude
    # history before asking the live endpoint.
    return _cached_claude_local_scan(home, observed_at)


def _cached_codex_local_scan(home: Path, observed_at: float) -> dict[str, object] | None:
    return _cached_provider_local_scan("codex", home, observed_at)


def _cached_claude_local_scan(
    home: Path,
    observed_at: float,
    *,
    extra_homes: Iterable[str] | None = None,
) -> dict[str, object] | None:
    return _cached_provider_local_scan(
        "claude", home, observed_at, extra_homes=extra_homes
    )


#: The small token results already worked out, keyed on the cache files they
#: were read from. A quota refresh runs every couple of minutes; without this
#: each one would read the cache again and rebuild the same totals.
#: A refusal (``None``: the cache does not reach back far enough yet) is
#: remembered too, or every refresh would read the cache just to find the
#: same answer.
_LOCAL_TOKENS_MEMO_LIMIT = 16
_local_tokens_memo: dict[tuple, dict[str, object] | None] = {}
_local_tokens_memo_lock = threading.Lock()
_NOT_REMEMBERED: dict[str, object] = {}


def _cache_stamp(path: Path) -> tuple[str, int, int, int] | None:
    try:
        info = path.lstat()
    except OSError:
        return None
    return (str(path), info.st_mtime_ns, info.st_size, info.st_ino)


def _local_token_totals(
    provider_id: str,
    source_key,
    primary_cache: dict,
    extra_paths: tuple[Path, ...],
    window_start: float,
) -> dict[str, object] | None:
    """The last 30 days of one provider, once each, across every home's cache.

    Each cache carries ``daily``: the per-day, per-model totals its last scan
    worked out from every message or turn it saw, each counted once, however
    many records the month held and however much of them the cache's entries
    could keep. The window is whole local days (``card_window_start``), so
    the days are summed as they stand.

    A cache whose ``daily`` starts after the window is not whole for it (it
    was never scanned, or not for a month). Claude needs the whole window and
    answers nothing then. Codex counts the days its caches do cover and no
    more, because its quota evidence lives in the same cache and must not be
    lost.
    """
    from . import usage_stats

    clamp = provider_id == "codex"
    primary = usage_stats.cache_card_days(primary_cache, provider_id)
    homes = []
    if primary is None:
        if not clamp:
            return None
    else:
        homes.append(primary)
    for path in extra_paths:
        cache = usage_stats._load_cache(path, source_key)
        extra = usage_stats.cache_card_days(cache, provider_id) if cache else None
        if extra is None:
            if not clamp:
                # A home no scan has covered yet: half a total is worse than none.
                return None
            continue
        homes.append(extra)
    start = window_start
    floor = max((card.since for card in homes), default=window_start)
    if floor > start:
        if not clamp:
            return None
        start = floor
    input_tokens = 0
    cached_input_tokens = 0
    output_tokens = 0
    model_ids: set[str] = set()
    priced_records = 0
    total_records = 0
    cost = 0.0
    savings = 0.0
    for card in homes:
        totals = usage_stats.card_totals(card, start, provider_id)
        input_tokens += totals.input_tokens
        cached_input_tokens += totals.cached_input_tokens
        output_tokens += totals.output_tokens
        model_ids.update(totals.models)
        priced_records += totals.priced_records
        total_records += totals.total_records
        cost += totals.estimated_cost_usd
        savings += totals.estimated_cache_savings_usd
    # A dollar figure is published only when every counted record was priced;
    # otherwise it would be a silent floor.
    fully_priced = total_records > 0 and priced_records == total_records
    return {
        "input_tokens": input_tokens,
        "cached_input_tokens": cached_input_tokens,
        "output_tokens": output_tokens,
        "model_count": len(model_ids),
        "estimated_cost_usd": cost if fully_priced else None,
        "cache_savings_usd": savings if fully_priced else None,
    }


#: Log lines already written, so a fault that repeats on every quota refresh
#: is said once.
_noted_once: set[str] = set()
_noted_once_lock = threading.Lock()


def _note_once(key: str, message: str) -> None:
    with _noted_once_lock:
        if key in _noted_once:
            return
        _noted_once.add(key)
    # stderr, never stdout: a command printing JSON shares this code.
    print(f"usage: {message}", file=sys.stderr, flush=True)


def _extra_cache_roots(
    provider_id: str,
    home: Path,
    extra_homes: Iterable[str] | None,
) -> tuple[Path, ...] | None:
    """The extra account homes to add, or ``None`` when they cannot be listed.

    ``None`` is not "no extra homes": the caller decides what an unknown set
    means (Claude publishes no total, Codex keeps its primary home).
    """
    try:
        from .provider_homes import configured_extra_homes, extra_scan_roots

        configured = (
            configured_extra_homes().get(provider_id, ())
            if extra_homes is None
            else tuple(extra_homes)
        )
        return extra_scan_roots(provider_id, home=home, extras=configured)
    except Exception as error:
        cause = error.__class__.__name__
        if provider_id == "codex":
            _note_once(
                provider_id,
                f"codex extra homes could not be listed ({cause}); "
                "the token card counts the primary home",
            )
        else:
            _note_once(
                provider_id,
                f"{provider_id} extra homes could not be listed ({cause}); "
                "the token card shows nothing rather than a total that may leave a home out",
            )
        return None


def _cached_provider_local_scan(
    provider_id: str,
    home: Path,
    observed_at: float,
    *,
    extra_homes: Iterable[str] | None = None,
    read_account: bool = True,
) -> dict[str, object] | None:
    """Read one provider's bounded usage cache without a transcript walk.

    The current quota UI needs the newest percentage quickly. Walking the full
    transcript tree on every refresh can take tens of seconds on large local
    histories, which stalls publication of a newer live rate-limit reading.

    Every scan writes the card's own per-day totals into its cache, for the
    last 30 days whatever range the scan was asked for, so this reads a few
    dozen numbers however busy the month was and never the per-file entries.
    It counts the last 30 days once each, across the primary home and every
    extra home, and never more than the caches cover.

    ``extra_homes`` names the extra account homes to add; left out, it is the
    saved ``provider_extra_homes`` setting.
    """
    try:
        from . import usage_stats
        from .provider_homes import _home_cache_path
        from .providers import negotiated_provider_sources
        from .state_paths import default_state_dir
    except ImportError:
        return None
    source = next(
        (
            item
            for item in negotiated_provider_sources()
            if item.source_key.provider_id == provider_id
            and item.source_key.capability_id == "transcript_usage"
            and item.observation_invocation_allowed
        ),
        None,
    )
    if source is None:
        return None
    source_key = source.source_key
    graph_cache = default_state_dir(home) / "usage-scan-cache.json"
    cold_cache = Path(home) / ".local" / "state" / "jrbar" / "provider-usage-cache.json"
    extra_roots = _extra_cache_roots(provider_id, home, extra_homes)
    if extra_roots is None:
        if provider_id != "codex":
            # Claude's total is every home or nothing: the primary home
            # alone is the half total the card refuses to show.
            return None
        extra_roots = ()
    candidates = (
        (
            usage_stats.provider_cache_path(graph_cache, source_key),
            tuple(
                usage_stats.provider_cache_path(_home_cache_path(graph_cache, root), source_key)
                for root in extra_roots
            ),
        ),
        (
            cold_cache,
            tuple(_home_cache_path(cold_cache, root) for root in extra_roots),
        ),
    )
    window_start = usage_stats.card_window_start(observed_at)
    for cache_path, extra_paths in candidates:
        if not isinstance(cache_path, Path):
            continue
        extra_paths = tuple(path for path in extra_paths if isinstance(path, Path))
        stamps = tuple(_cache_stamp(path) for path in (cache_path, *extra_paths))
        memo_key = (provider_id, stamps, window_start)
        cache: dict | None = None
        windows: tuple[dict[str, object], ...] = ()
        newest_window_marker: tuple[float, str] | None = None
        if provider_id == "codex":
            # The quota evidence rides in the same cache, so it is read on
            # every refresh, remembered totals or not.
            cache = usage_stats._load_cache(cache_path, source_key)
            files = cache.get("files")
            if not (
                isinstance(files, dict)
                and isinstance(cache.get("sessions"), list)
                and isinstance(cache.get("models"), list)
                and isinstance(cache.get("dedupes"), list)
            ):
                continue
            for key, entry in tuple(files.items())[: usage_stats.USAGE_CACHE_MAX_FILES]:
                if not isinstance(key, str) or not isinstance(entry, dict):
                    continue
                raw_mtime = entry.get("mtime")
                raw_windows = entry.get("rate_limit_windows")
                if (
                    isinstance(raw_mtime, (int, float))
                    and not isinstance(raw_mtime, bool)
                    and isinstance(raw_windows, list)
                ):
                    admitted = tuple(
                        dict(window)
                        for window in raw_windows[:64]
                        if isinstance(window, dict)
                    )
                    marker = (float(raw_mtime), key)
                    if admitted and (
                        newest_window_marker is None or marker > newest_window_marker
                    ):
                        windows = admitted
                        newest_window_marker = marker
        with _local_tokens_memo_lock:
            totals = _local_tokens_memo.get(memo_key, _NOT_REMEMBERED)
        if totals is _NOT_REMEMBERED:
            if cache is None:
                cache = usage_stats._load_cache(cache_path, source_key)
            if not cache:
                continue
            totals = _local_token_totals(
                provider_id, source_key, cache, extra_paths, window_start
            )
            with _local_tokens_memo_lock:
                while len(_local_tokens_memo) >= _LOCAL_TOKENS_MEMO_LIMIT:
                    _local_tokens_memo.pop(next(iter(_local_tokens_memo)))
                _local_tokens_memo[memo_key] = totals
        if totals is None:
            continue
        if (
            (provider_id != "codex" or not windows)
            and totals["input_tokens"] == 0
            and totals["cached_input_tokens"] == 0
            and totals["output_tokens"] == 0
            and totals["model_count"] == 0
        ):
            continue
        document: dict[str, object] = dict(totals)
        if provider_id == "codex":
            document["windows"] = [dict(window) for window in windows]
            if newest_window_marker is not None:
                document["windows_observed_at"] = newest_window_marker[0]
            if read_account:
                try:
                    from .credentials import read_codex_tokens

                    tokens = read_codex_tokens(Path(home) / ".codex" / "auth.json")
                except Exception:
                    tokens = None
                if tokens is not None and getattr(tokens, "account_id", None):
                    document["account_label"] = str(tokens.account_id)
        return document
    return None


def _default_claude_quota_fetch(access_token: str) -> list[dict]:
    from .claude_quota import fetch_windows

    return fetch_windows(access_token=access_token)


#: Codex quota is only ever as fresh as the newest rollout the CLI wrote.
#: Past this, a reading is reported as STALE rather than as the current
#: number: usage burned on another machine, in the web app, or through a
#: surface that writes no rollout is invisible here, and silence is not
#: evidence that nothing changed. Reported live as "why does it say 48
#: percent, it should be around 96" -- the 48 was three days old.
CODEX_READING_STALE_SECONDS = 6 * 3600.0


def _codex_reading_freshness(
    snapshot: ProviderUsageSnapshot,
    evidence_observed_at: object,
    *,
    observed_at: float,
) -> ProviderUsageSnapshot:
    """Mark a Codex snapshot stale when its evidence has stopped moving."""
    if (
        not isinstance(evidence_observed_at, (int, float))
        or isinstance(evidence_observed_at, bool)
        or not math.isfinite(float(evidence_observed_at))
    ):
        return snapshot
    age = float(observed_at) - float(evidence_observed_at)
    if age <= CODEX_READING_STALE_SECONDS or not snapshot.lanes:
        return snapshot
    hours = age / 3600.0
    since = f"{hours / 24.0:.0f}d" if hours >= 48.0 else f"{hours:.0f}h"
    # "run Codex to refresh" was said to a user who HAD just run Codex --
    # opened it, poked around, quit. The evidence only moves when a turn
    # COMPLETES, so the instruction has to say so.
    return dataclasses.replace(
        snapshot,
        # `observed_at` stays the poll; the numbers were read when the newest
        # rollout was written, so the card can say how old they really are.
        read_at=max(0.0, min(float(evidence_observed_at), float(observed_at))),
        state=ProviderSourceState.STALE,
        reason_code="local_reading_stale",
        action_label=(
            f"Last read {since} ago — finish one Codex prompt to refresh"
        ),
    )


def _codex_plan(
    local_facts: dict[str, object],
    live: object,
    *,
    home: Path,
    read_auth: bool = True,
) -> str | None:
    """The ChatGPT plan this Codex account is on, as OpenAI states it.

    Three sources, all first-party, in falling order of freshness: the live
    ``account/rateLimits/read`` (``rateLimits.planType``), whatever the local
    scan carried off a rollout (``plan_type``), and the ``chatgpt_plan_type``
    claim in Codex's own ``auth.json`` id_token. Which windows the account
    HAS follows from the plan, so this is recorded as a fact rather than
    inferred backwards from which lanes happened to arrive.
    """
    if isinstance(live, dict):
        plan = live.get("plan")
        if isinstance(plan, str) and plan.strip():
            return plan.strip()[:64]
    plan = local_facts.get("plan_type")
    if isinstance(plan, str) and plan.strip():
        return plan.strip()[:64]
    if not read_auth:
        return None
    try:
        from .credentials import read_codex_tokens

        tokens = read_codex_tokens(Path(home) / ".codex" / "auth.json")
    except Exception:
        return None
    plan = getattr(tokens, "plan_type", None)
    return plan.strip()[:64] if isinstance(plan, str) and plan.strip() else None


def collect_codex(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    local_scanner: Callable[[Path, float], dict[str, object] | None] = _default_codex_local_scan,
    live_probe: Callable[[], dict | None] | None = None,
    read_auth: bool = True,
) -> ProviderUsageSnapshot:
    default_instance = getattr(preference, "source_instance_id", "default") == "default"
    live = live_probe() if callable(live_probe) else None
    if isinstance(live, dict) and local_scanner is _default_codex_local_scan:
        facts = _cached_codex_local_scan(Path(home), observed_at)
    else:
        facts = local_scanner(Path(home), observed_at)
    if not isinstance(facts, dict) and not isinstance(live, dict):
        return _failure(
            "codex",
            observed_at=observed_at,
            state=ProviderSourceState.SOURCE_NOT_FOUND,
            reason="local_usage_not_found",
            action="Use Codex once or sign in",
        )
    local_facts = facts if isinstance(facts, dict) else {}
    local_totals = local_facts if default_instance else {}
    windows = local_facts.get("windows")
    if not isinstance(windows, (list, tuple)):
        windows = ()
    source_id = "codex-rollouts"
    observed_evidence_at = local_facts.get("windows_observed_at")
    account_plan = _codex_plan(local_facts, live, home=Path(home), read_auth=read_auth)
    if isinstance(live, dict):
        live_windows = live.get("windows")
        live_windows = (
            tuple(window for window in live_windows if isinstance(window, dict))
            if isinstance(live_windows, (list, tuple))
            else ()
        )
        if live_windows:
            # The live read enumerates every limit family the account has, so
            # for the families it covered it is the WHOLE truth -- including
            # which windows a family does NOT have. A rollout is a snapshot of
            # one family taken at whatever moment a turn ended; letting a
            # stale one back in is how a window the account no longer has (or
            # never had) survived as a lane that could not move.
            covered = {
                window.get("limit_id")
                for window in live_windows
                if isinstance(window.get("limit_id"), str)
            }
            windows = (
                *live_windows,
                *(
                    window
                    for window in windows
                    if isinstance(window, dict)
                    and window.get("limit_id") not in covered
                    # A rollout that names no family at all predates the
                    # tagging and cannot be told apart from the account's
                    # own; the live read outranks it.
                    and isinstance(window.get("limit_id"), str)
                ),
            )
            observed_evidence_at = observed_at
            source_id = "codex-app-server"
        else:
            used = live.get("used_percent")
            if isinstance(used, (int, float)) and not isinstance(used, bool):
                live_minutes = live.get("window_minutes")
                if not isinstance(live_minutes, (int, float)) or isinstance(
                    live_minutes, bool
                ):
                    live_minutes = None
                live_window = {
                    "label": "primary",
                    "used_percent": float(used),
                    "resets_at": live.get("resets_at"),
                    "window_minutes": live_minutes,
                }
                windows = (
                    live_window,
                    *(
                        window
                        for window in windows
                        if not (
                            isinstance(window, dict)
                            and live_minutes is not None
                            and window.get("window_minutes") == live_minutes
                        )
                    ),
                )
                observed_evidence_at = observed_at
                source_id = "codex-app-server"
    try:
        snapshot = parse_codex_usage(
            windows=windows,
            observed_at=observed_at,
            input_tokens=max(0, int(local_totals.get("input_tokens", 0))),
            cached_input_tokens=max(0, int(local_totals.get("cached_input_tokens", 0))),
            output_tokens=max(0, int(local_totals.get("output_tokens", 0))),
            model_count=max(0, int(local_totals.get("model_count", 0))),
            estimated_cost_usd=local_totals.get("estimated_cost_usd"),
            cache_savings_usd=local_totals.get("cache_savings_usd"),
            account_label=(
                str(local_facts["account_label"])
                if local_facts.get("account_label") is not None
                else None
            ),
            account_plan=account_plan,
            source_id=source_id,
        )
        credits = live.get("reset_credits") if isinstance(live, dict) else None
        if isinstance(credits, int) and not isinstance(credits, bool):
            # A count only: JR-Bar never redeems a reset credit.
            snapshot = replace(snapshot, reset_credits=credits)
        return _codex_reading_freshness(
            snapshot, observed_evidence_at, observed_at=observed_at
        )
    except (TypeError, ValueError):
        return _failure(
            "codex",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_local_usage",
            action="Retry",
        )


def _codex_rollouts_scan(home: Path, observed_at: float) -> dict[str, object] | None:
    """Codex's own rollout files and JR-Bar's scan cache, and nothing that
    holds a sign-in."""
    cached = _cached_provider_local_scan("codex", home, observed_at, read_account=False)
    if isinstance(cached, dict):
        return cached
    return _default_provider_local_scan("codex", home, observed_at, read_account=False)


def collect_codex_local_only(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    local_scanner: Callable[[Path, float], dict[str, object] | None] = _codex_rollouts_scan,
) -> ProviderUsageSnapshot:
    """What Codex shows with its usage read off: the numbers its own rollout
    files recorded, read from this Mac. No `codex app-server`, no `auth.json`.

    A Mac with no rollouts yet has nothing to show, and says "usage off"
    rather than "source not found" because turning the read on is the fix.
    """
    snapshot = collect_codex(
        preference,
        home=home,
        observed_at=observed_at,
        local_scanner=local_scanner,
        live_probe=None,
        read_auth=False,
    )
    if snapshot.state is ProviderSourceState.SOURCE_NOT_FOUND:
        from .provider_usage_consent import usage_off_snapshot

        return usage_off_snapshot(
            "codex",
            observed_at=observed_at,
            source_instance_id=getattr(preference, "source_instance_id", "default"),
        )
    return snapshot


def _with_local_usage(
    snapshot: ProviderUsageSnapshot,
    local: dict[str, object] | None,
) -> ProviderUsageSnapshot:
    if not isinstance(local, dict):
        return snapshot
    try:
        return replace(
            snapshot,
            input_tokens=max(0, int(local.get("input_tokens", 0))),
            cached_input_tokens=max(0, int(local.get("cached_input_tokens", 0))),
            output_tokens=max(0, int(local.get("output_tokens", 0))),
            model_count=max(0, int(local.get("model_count", 0))),
            estimated_cost_usd=local.get("estimated_cost_usd"),
            cache_savings_usd=local.get("cache_savings_usd"),
        )
    except (TypeError, ValueError):
        return snapshot


#: How long the OAuth endpoint rests after it failed while Claude Code's
#: status line can stand in: a 429 is how one STAYS rate limited if asked
#: again at once. Keyed by the failure's reason.
_OAUTH_REST_SECONDS = {
    "rate_limited": 600.0,
    "authentication_required": 1800.0,
    "claude_keychain_access_lost": 1800.0,
    "usage_permission_missing": 1800.0,
    "usage_connection_required": 1800.0,
    "network_unavailable": 120.0,
    "invalid_provider_response": 300.0,
}
_oauth_rest_until: dict[tuple[str, str], tuple[float, str | None, str | None]] = {}
_oauth_rest_lock = threading.Lock()


def clear_claude_auth_rest(*, source_instance_id: str = "default") -> None:
    """A reconnect can probe again; a rate-limit cooldown still applies."""
    with _oauth_rest_lock:
        for key, rest in tuple(_oauth_rest_until.items()):
            if key[1] == source_instance_id and rest[2] != "rate_limited":
                _oauth_rest_until.pop(key, None)


def _claude_credential_identity(credentials: object) -> str | None:
    token = _credential(credentials, "claude", "oauth-token")
    return hashlib.sha256(token.encode()).hexdigest() if token is not None else None


def _fetch_claude_with_reloaded_token(
    quota_fetcher: Callable[[str], list[dict]],
    access_token: str,
    credentials: object,
    home: Path,
    observed_at: float,
    source_instance_id: str,
) -> list[dict]:
    """Retry one rejected access token only when a consented reread replaces it."""
    try:
        return quota_fetcher(access_token)
    except Exception as error:
        if source_instance_id != "default" or (
            "unauthorized" not in str(error) and "needs_sign_in" not in str(error)
        ):
            raise
        from .provider_reconnect import sync_claude_credential_in_background

        try:
            sync_claude_credential_in_background(
                credentials, home=Path(home), now=observed_at, source_instance_id=source_instance_id
            )
        except Exception:
            pass
        current = _credential(credentials, "claude", "oauth-token")
        if current is None or current == access_token:
            raise
    return quota_fetcher(current)


def _default_statusline_reader(observed_at: float):
    from .claude_statusline_source import current_reading

    return current_reading(observed_at)


def _statusline_stand_in(
    failure: ProviderUsageSnapshot,
    *,
    reading,
    local: dict[str, object] | None,
    observed_at: float,
    home: Path,
    account_plan: str | None = None,
    account_discriminator: str | None = None,
) -> ProviderUsageSnapshot:
    """Claude Code's own status line reading in place of a failed OAuth
    read (claude_statusline_source): its lanes say where they came from,
    and the token totals are the local scan's."""
    from .claude_statusline_source import snapshot_from_reading

    if reading is None:
        return _with_local_usage(failure, local)
    values = local or {}
    try:
        return snapshot_from_reading(
            reading,
            observed_at=observed_at,
            account_plan=account_plan,
            account_discriminator=account_discriminator,
            input_tokens=max(0, int(values.get("input_tokens", 0))),
            cached_input_tokens=max(0, int(values.get("cached_input_tokens", 0))),
            output_tokens=max(0, int(values.get("output_tokens", 0))),
            model_count=max(0, int(values.get("model_count", 0))),
            estimated_cost_usd=values.get("estimated_cost_usd"),
            cache_savings_usd=values.get("cache_savings_usd"),
        )
    except (TypeError, ValueError):
        return _with_local_usage(failure, local)


def collect_claude(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    credentials,
    quota_fetcher: Callable[[str], list[dict]] = _default_claude_quota_fetch,
    local_scanner: Callable[[Path, float], dict[str, object] | None] = _default_claude_local_scan,
    statusline_reader: Callable[[float], object] | None = None,
) -> ProviderUsageSnapshot:
    # Claude Code's status line describes the account signed in on this Mac,
    # so it can only stand in for the default instance.
    default_instance = getattr(preference, "source_instance_id", "default") == "default"
    instance = getattr(preference, "source_instance_id", "default")
    try:
        from .claude_quota import account_facts_from_claude_config

        account_plan, account_discriminator = (
            account_facts_from_claude_config(Path(home))
            if default_instance
            else (None, None)
        )
    except Exception:
        account_plan = None
        account_discriminator = None
    local = local_scanner(Path(home), observed_at) if default_instance else None
    reader = _default_statusline_reader if statusline_reader is None else statusline_reader
    try:
        reading = reader(observed_at) if default_instance else None
    except Exception:
        reading = None
    rest_key = (str(Path(home)), instance)
    with _oauth_rest_lock:
        rest = _oauth_rest_until.get(rest_key)
    if (default_instance and reading is not None and rest is not None
            and observed_at < rest[0] and rest[2] == "authentication_required"):
        from .provider_reconnect import sync_claude_credential_in_background

        sync_claude_credential_in_background(credentials, home=Path(home), now=observed_at)
    identity = _claude_credential_identity(credentials)
    with _oauth_rest_lock:
        rest = _oauth_rest_until.get(rest_key)
        if rest is not None and identity != rest[1] and rest[2] != "rate_limited":
            _oauth_rest_until.pop(rest_key, None)
            rest = None
    if reading is not None and rest is not None and observed_at < rest[0]:
        # OAuth failed a moment ago and is resting; the status line is fresh.
        return _statusline_stand_in(
            _failure(
                "claude",
                observed_at=observed_at,
                state=ProviderSourceState.RATE_LIMITED,
                reason="rate_limited",
                action="Retry later",
            ),
            reading=reading,
            local=local,
            observed_at=observed_at,
            home=Path(home),
            account_plan=account_plan,
            account_discriminator=account_discriminator,
        )
    snapshot = _collect_claude_oauth(
        home=home,
        observed_at=observed_at,
        credentials=credentials,
        quota_fetcher=quota_fetcher,
        local=local,
        account_plan=account_plan,
        account_discriminator=account_discriminator,
        source_instance_id=instance,
    )
    snapshot = replace(
        snapshot,
        account_plan=snapshot.account_plan or account_plan,
        account_discriminator=account_discriminator,
    )
    if snapshot.state is ProviderSourceState.READY:
        with _oauth_rest_lock:
            _oauth_rest_until.pop(rest_key, None)
        return snapshot
    if reading is None:
        return snapshot
    identity = _claude_credential_identity(credentials)
    with _oauth_rest_lock:
        _oauth_rest_until[rest_key] = (
            observed_at + _OAUTH_REST_SECONDS.get(snapshot.reason_code or "", 300.0),
            identity,
            snapshot.reason_code,
        )
    return _statusline_stand_in(
        snapshot,
        reading=reading,
        local=local,
        observed_at=observed_at,
        home=Path(home),
        account_plan=account_plan,
        account_discriminator=account_discriminator,
    )


def collect_claude_local_only(
    preference: ProviderPreference,
    *,
    home: Path,
    observed_at: float,
    local_scanner: Callable[[Path, float], dict[str, object] | None] = _default_claude_local_scan,
    statusline_reader: Callable[[float], object] | None = None,
) -> ProviderUsageSnapshot:
    """What Claude shows with its usage read off: token totals from the
    transcripts on this Mac, and Claude Code's status line when you installed
    it. Nothing asks Anthropic; no Keychain item, credential store or
    `~/.claude.json` is read."""
    from .provider_usage_consent import usage_off_snapshot

    instance = getattr(preference, "source_instance_id", "default")
    default_instance = instance == "default"
    local = local_scanner(Path(home), observed_at) if default_instance else None
    reader = _default_statusline_reader if statusline_reader is None else statusline_reader
    try:
        reading = reader(observed_at) if default_instance else None
    except Exception:
        reading = None
    off = usage_off_snapshot("claude", observed_at=observed_at, source_instance_id=instance)
    return _statusline_stand_in(
        off,
        reading=reading,
        local=local,
        observed_at=observed_at,
        home=Path(home),
    )


def _collect_claude_oauth(
    *,
    home: Path,
    observed_at: float,
    credentials,
    quota_fetcher: Callable[[str], list[dict]],
    local: dict[str, object] | None,
    account_plan: str | None = None,
    account_discriminator: str | None = None,
    source_instance_id: str = "default",
) -> ProviderUsageSnapshot:
    """The OAuth usage endpoint's reading, or the failure that says why not."""
    # Re-read BEFORE asking when JR-Bar's copy is stale. This is a
    # read-only sync under a previously recorded standing grant. Claude
    # Code remains the sole owner of refresh and Keychain mutation.
    try:
        from .provider_reconnect import (
            claude_token_is_stale,
            sync_claude_credential_in_background,
        )

        if source_instance_id == "default" and claude_token_is_stale(credentials, now=observed_at):
            sync_claude_credential_in_background(
                credentials, home=Path(home), now=observed_at, source_instance_id=source_instance_id
            )
    except Exception:
        pass
    access_token = _credential(credentials, "claude", "oauth-token")
    if access_token is None:
        reason = "usage_connection_required"
        action = "Connect Claude usage"
        if source_instance_id == "default":
            from .credentials import CLAUDE_CODE_KEYCHAIN, KeychainConsentLedger
            from .providers import default_state_dir

            if KeychainConsentLedger(default_state_dir() / "keychain-consent.json").access_lost(CLAUDE_CODE_KEYCHAIN.service):
                reason = "claude_keychain_access_lost"
                action = "Allow Claude Keychain access"
        return _with_local_usage(
            _failure(
                "claude",
                observed_at=observed_at,
                state=ProviderSourceState.NEEDS_CONSENT,
                reason=reason,
                action=action,
            ),
            local,
        )
    try:
        windows = _fetch_claude_with_reloaded_token(
            quota_fetcher, access_token, credentials, home, observed_at, source_instance_id
        )
    except Exception as error:
        reason = str(error)
        if "unauthorized" in reason or "needs_sign_in" in reason:
            state = ProviderSourceState.NEEDS_SIGN_IN
            reason_code = "authentication_required"
            action = "Reconnect Claude"
            if source_instance_id == "default":
                from .credentials import CLAUDE_CODE_KEYCHAIN, KeychainConsentLedger
                from .providers import default_state_dir

                ledger = KeychainConsentLedger(default_state_dir() / "keychain-consent.json")
                if ledger.access_lost(CLAUDE_CODE_KEYCHAIN.service):
                    state = ProviderSourceState.NEEDS_CONSENT
                    reason_code = "claude_keychain_access_lost"
                    action = "Allow Claude Keychain access"
        elif "forbidden" in reason:
            state = ProviderSourceState.UNAVAILABLE
            reason_code = "usage_permission_missing"
            action = "Check Claude usage access"
        elif "rate_limit" in reason:
            state = ProviderSourceState.RATE_LIMITED
            reason_code = "rate_limited"
            action = "Retry later"
        else:
            state = ProviderSourceState.UNAVAILABLE
            reason_code = "network_unavailable"
            action = "Retry"
        return _with_local_usage(
            _failure(
                "claude",
                observed_at=observed_at,
                state=state,
                reason=reason_code,
                action=action,
            ),
            local,
        )
    if not isinstance(windows, list):
        return _with_local_usage(
            _failure(
                "claude",
                observed_at=observed_at,
                state=ProviderSourceState.ERROR,
                reason="invalid_provider_response",
                action="Retry",
            ),
            local,
        )
    values = local or {}
    try:
        return parse_claude_usage(
            windows=windows,
            observed_at=observed_at,
            account_plan=account_plan,
            account_discriminator=account_discriminator,
            input_tokens=max(0, int(values.get("input_tokens", 0))),
            cached_input_tokens=max(0, int(values.get("cached_input_tokens", 0))),
            output_tokens=max(0, int(values.get("output_tokens", 0))),
            model_count=max(0, int(values.get("model_count", 0))),
            estimated_cost_usd=values.get("estimated_cost_usd"),
            cache_savings_usd=values.get("cache_savings_usd"),
        )
    except (TypeError, ValueError):
        return _failure(
            "claude",
            observed_at=observed_at,
            state=ProviderSourceState.ERROR,
            reason="invalid_provider_response",
            action="Retry",
        )


__all__ = [
    "collect_claude",
    "collect_claude_local_only",
    "collect_codex",
    "collect_codex_local_only",
]
