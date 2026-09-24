"""Thin hook admission entry point with a synchronous fail-open fallback."""

from __future__ import annotations

import sys
from collections.abc import Callable
from pathlib import Path

from .hook_ingress_protocol import (
    HOOK_DECISION_WAIT_MS,
    MAX_HOOK_INGRESS_PAYLOAD_BYTES,
    HookIngressDisposition,
    HookIngressRequest,
    submit_hook_ingress,
    submit_hook_ingress_for_decision,
)

# Admission never proven: the payload may not have reached the daemon.
_UNPROVEN_DISPOSITIONS = frozenset(
    {HookIngressDisposition.UNAVAILABLE, HookIngressDisposition.SUBMISSION_AMBIGUOUS}
)
# A daemon that heard the payload and could not take it: its queue was
# full, or it was shutting down. It never processes a payload it refused.
_REFUSED_FOR_LATER = frozenset(
    {HookIngressDisposition.REFUSED_FULL, HookIngressDisposition.REFUSED_CLOSED}
)


def _synchronous_fallback(provider: str, log_path: Path, payload_text: str) -> None:
    from .hook import process_hook_payload

    process_hook_payload(provider, log_path, payload_text)


def _spool(provider: str, log_path: Path, payload_text: str) -> None:
    """Queue a refused payload where the compiled shim queues it; the
    daemon drains ``<provider>.pending.jsonl`` behind what its queue still
    holds (hook_pending). A spool that cannot be written falls back to
    processing it here: late and out of order beats lost."""
    from .hook_pending import spool_pending_hook

    if not spool_pending_hook(provider, payload_text):
        _synchronous_fallback(provider, log_path, payload_text)


def run_hook_client(
    provider: str,
    log_path: Path,
    payload_text: str,
    *,
    submit: Callable[[HookIngressRequest], HookIngressDisposition] = submit_hook_ingress,
    fallback: Callable[[str, Path, str], object] = _synchronous_fallback,
    spool: Callable[[str, Path, str], object] = _spool,
) -> int:
    try:
        request = HookIngressRequest(provider, str(Path(log_path).expanduser()), payload_text)
    except (TypeError, ValueError):
        return 0

    # Only the hook process can see which agent spawned it. Register that
    # process before handing the payload to the app, so the app can later
    # notice the agent is gone even when no hook ever says so.
    try:
        from .process_registry import note_hook_payload

        note_hook_payload(provider, payload_text)
    except Exception:
        pass

    try:
        disposition = submit(request)
        # UNAVAILABLE means the payload never left this process.
        # SUBMISSION_AMBIGUOUS means the ack was lost after connect: the
        # ingress MAY have queued it, but "maybe" is not a delivery
        # guarantee for a turn boundary. Falling back re-processes the
        # same payload through the dedupe-checked path, so the worst case
        # is a suppressed duplicate -- the other direction is a silent
        # drop, which is the failure this file exists to prevent.
        if disposition in _UNPROVEN_DISPOSITIONS:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        # A refusal is never processed here, where it would land ahead of
        # everything the full queue still holds: it is spooled, and the
        # drain replays it behind them once the queue is empty.
        elif disposition in _REFUSED_FOR_LATER:
            spool(provider, Path(log_path).expanduser(), payload_text)
    except Exception:
        try:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
    return 0


def run_decide_hook_client(
    provider: str,
    log_path: Path,
    payload_text: str,
    *,
    submit: Callable[
        [HookIngressRequest], tuple[HookIngressDisposition, str | None]
    ] = submit_hook_ingress_for_decision,
    fallback: Callable[[str, Path, str], object] = _synchronous_fallback,
    spool: Callable[[str, Path, str], object] = _spool,
) -> str | None:
    """``run_hook_client`` for the decide lane: the verdict line to print,
    or ``None`` for "print nothing" (the agent's own prompt carries on).

    The same admission, fallback and spool as every other hook; the only
    addition is that an accepted frame waits for the daemon's verdict, as
    the compiled shim's ``--decide`` does (hook/jrbar-hook.c). A daemon that
    is down gets the payload through the synchronous fallback, and one that
    refused it through the spool; neither gets a verdict: nothing can be
    decided without it.
    """
    try:
        request = HookIngressRequest(
            provider,
            str(Path(log_path).expanduser()),
            payload_text,
            decide_ms=HOOK_DECISION_WAIT_MS,
        )
    except (TypeError, ValueError):
        return None
    try:
        from .process_registry import note_hook_payload

        note_hook_payload(provider, payload_text)
    except Exception:
        pass
    try:
        disposition, verdict = submit(request)
    except Exception:
        disposition, verdict = HookIngressDisposition.UNAVAILABLE, None
    if disposition in _UNPROVEN_DISPOSITIONS:
        try:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
        return None
    if disposition in _REFUSED_FOR_LATER:
        try:
            spool(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
        return None
    return verdict if disposition is HookIngressDisposition.ACCEPTED else None


def _read_bounded_payload() -> str | None:
    try:
        payload = sys.stdin.buffer.read(MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1)
    except (AttributeError, OSError):
        return None
    if len(payload) > MAX_HOOK_INGRESS_PAYLOAD_BYTES:
        return None
    try:
        return payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None


def hook_client_main(provider: str, log_path: Path, *, decide: bool = False) -> int:
    try:
        payload_text = _read_bounded_payload()
        if payload_text is None:
            return 0
        if decide:
            verdict = run_decide_hook_client(provider, Path(log_path).expanduser(), payload_text)
            if verdict is not None:
                try:
                    sys.stdout.write(verdict + "\n")
                    sys.stdout.flush()
                except Exception:
                    pass
            return 0
        return run_hook_client(provider, Path(log_path).expanduser(), payload_text)
    finally:
        # Cursor and Gemini CLI read a hook's stdout as its JSON verdict;
        # "{}" is the documented no-op.
        if provider in ("cursor", "gemini"):
            try:
                sys.stdout.write("{}\n")
                sys.stdout.flush()
            except Exception:
                pass


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    try:
        provider = args[args.index("--provider") + 1]
        log_path = Path(args[args.index("--log") + 1]).expanduser()
    except (ValueError, IndexError):
        return 0

    return hook_client_main(provider, log_path, decide="--decide" in args)


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["hook_client_main", "main", "run_decide_hook_client", "run_hook_client"]
