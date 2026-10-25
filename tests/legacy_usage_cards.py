"""Legacy scan-cache oracle for migration comparisons, never a production fallback."""
from __future__ import annotations

import threading
from collections.abc import Iterable
from pathlib import Path

from jrbar.provider_usage_codex_claude import _note_once

_LOCAL_TOKENS_MEMO_LIMIT = 16
_local_tokens_memo = {}
_local_tokens_memo_lock = threading.Lock()
_NOT_REMEMBERED = {}
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
    from jrbar import usage_stats

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
        from jrbar.provider_homes import configured_extra_homes, extra_scan_roots

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
        from jrbar import usage_stats
        from jrbar.provider_homes import _home_cache_path
        from jrbar.providers import negotiated_provider_sources
        from jrbar.state_paths import default_state_dir
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
                    from jrbar.credentials import read_codex_tokens

                    tokens = read_codex_tokens(Path(home) / ".codex" / "auth.json")
                except Exception:
                    tokens = None
                if tokens is not None and getattr(tokens, "account_id", None):
                    document["account_label"] = str(tokens.account_id)
        return document
    return None
