"""``jrbar serve``: the indicator as a machine-readable endpoint.

CodexBar's ``serve`` spawned its whole integration ecosystem -- Stream
Deck, Waybar, KDE widgets -- because a local JSON endpoint is the one
surface every other tool can consume. This is JR-Bar's: a loopback
HTTP server over the app's own persisted state files, read fresh per
request so it never needs the app's process (or even the app running --
it serves the last persisted truth with its timestamps, and honesty
lives in those timestamps).

    GET /status.json   authenticated agent aggregates + redacted provider quota
    GET /asks.json     what is waiting and which answers each ask takes
    POST /answer       approve / deny / always / a choice, for a Stream Deck key

Loopback only, no query parameters on the status route, nothing written.
The public schema is rebuilt from an allowlist and never forwards persisted
rows. The two answering routes (serve_answers.py) exist only when the host
wires an answer source, are never anonymous, and act only while the
owner's ``serve_answer_enabled`` switch is on -- off by default.
"""

from __future__ import annotations

import hmac
import json
import math
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

from .local_api_contract import (
    LocalAPIRequest,
    LocalAPIResponse,
    ReplayGuard,
    decode_request,
    redacted_response,
    validate_authenticated_request,
)
from .product_identity import PRODUCT_DISPLAY_NAME
from .provider_facts import NextActor, SourceFreshness, SourceHealth, WorkLifecycle
from .provider_usage_platform import ProviderSourceState, provider_descriptors
from .provider_usage_store import default_provider_usage_state_path
from .providers import default_state_dir

SERVE_DEFAULT_PORT = 8737
SERVE_SCHEMA_VERSION = 2
_MAX_STATE_BYTES = 8 * 1024 * 1024
_MAX_WORKS = 1_000
_MAX_SNAPSHOTS = 32
_MAX_LANES = 64
_WORK_LIFECYCLES = frozenset(item.value for item in WorkLifecycle)
_NEXT_ACTORS = frozenset(item.value for item in NextActor)
_SOURCE_HEALTH = frozenset(item.value for item in SourceHealth)
_SOURCE_FRESHNESS = frozenset(item.value for item in SourceFreshness)
_PROVIDER_STATES = frozenset(item.value for item in ProviderSourceState)
_PROVIDER_IDS = frozenset(item.provider_id for item in provider_descriptors())
_MAX_ACCESS_TOKEN_BYTES = 4_096


def _read_json(path: Path) -> object | None:
    try:
        if path.is_symlink() or not path.is_file():
            return None
        if path.stat().st_size > _MAX_STATE_BYTES:
            return None
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _timestamp(value: object) -> float | None:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or float(value) < 0.0
    ):
        return None
    return float(value)


def _increment(counts: dict[str, int], value: str) -> None:
    counts[value] = counts.get(value, 0) + 1


def _public_agents(latest: object) -> dict[str, object] | None:
    if not isinstance(latest, dict) or latest.get("version") != 2:
        return None
    generation = latest.get("generation")
    works = latest.get("works")
    if (
        type(generation) is not int
        or generation < 0
        or not isinstance(works, list)
    ):
        return None
    lifecycle_counts: dict[str, int] = {}
    next_actor_counts: dict[str, int] = {}
    health_counts: dict[str, int] = {}
    freshness_counts: dict[str, int] = {}
    timing_uncertain_count = 0
    work_count = 0
    for raw in works[:_MAX_WORKS]:
        if not isinstance(raw, dict):
            continue
        lifecycle = raw.get("lifecycle")
        next_actor = raw.get("next_actor")
        source_health = raw.get("source_health")
        source_freshness = raw.get("source_freshness")
        timing_uncertain = raw.get("timing_uncertain")
        if not (
            type(lifecycle) is str
            and lifecycle in _WORK_LIFECYCLES
            and type(next_actor) is str
            and next_actor in _NEXT_ACTORS
            and type(source_health) is str
            and source_health in _SOURCE_HEALTH
            and type(source_freshness) is str
            and source_freshness in _SOURCE_FRESHNESS
            and type(timing_uncertain) is bool
        ):
            continue
        work_count += 1
        _increment(lifecycle_counts, lifecycle)
        _increment(next_actor_counts, next_actor)
        _increment(health_counts, source_health)
        _increment(freshness_counts, source_freshness)
        timing_uncertain_count += int(timing_uncertain)
    return {
        "generation": generation,
        "work_count": work_count,
        "lifecycle_counts": lifecycle_counts,
        "next_actor_counts": next_actor_counts,
        "source_health_counts": health_counts,
        "source_freshness_counts": freshness_counts,
        "timing_uncertain_count": timing_uncertain_count,
    }


def _quota_summary(lanes: object, *, provider_id: str) -> dict[str, object]:
    remaining: list[float] = []
    resets: list[float] = []
    window_count = 0
    if isinstance(lanes, list):
        for lane in lanes[:_MAX_LANES]:
            if not isinstance(lane, dict) or lane.get("provider_id") != provider_id:
                continue
            raw_remaining = lane.get("remaining_percent")
            raw_reset = lane.get("reset_at")
            remaining_value = None
            reset_value = None
            if raw_remaining is not None:
                remaining_value = _timestamp(raw_remaining)
                if remaining_value is None or remaining_value > 100.0:
                    continue
            if raw_reset is not None:
                reset_value = _timestamp(raw_reset)
                if reset_value is None:
                    continue
            if remaining_value is not None:
                remaining.append(remaining_value)
            if reset_value is not None:
                resets.append(reset_value)
            window_count += 1
    return {
        "window_count": window_count,
        "remaining_percent": min(remaining) if remaining else None,
        "next_reset_at": min(resets) if resets else None,
    }


def _public_usage(usage: object) -> dict[str, object] | None:
    if not isinstance(usage, dict) or usage.get("schema_version") != 1:
        return None
    snapshots = usage.get("snapshots")
    if not isinstance(snapshots, list):
        return None
    providers: list[dict[str, object]] = []
    seen: set[str] = set()
    for raw in snapshots[:_MAX_SNAPSHOTS]:
        if not isinstance(raw, dict):
            continue
        provider_id = raw.get("provider_id")
        observed_at = _timestamp(raw.get("observed_at"))
        state = raw.get("state")
        if not (
            type(provider_id) is str
            and provider_id in _PROVIDER_IDS
            and provider_id not in seen
            and observed_at is not None
            and type(state) is str
            and state in _PROVIDER_STATES
        ):
            continue
        seen.add(provider_id)
        providers.append(
            {
                "provider_id": provider_id,
                "observed_at": observed_at,
                "state": state,
                "quota": _quota_summary(raw.get("lanes"), provider_id=provider_id),
            }
        )
    providers.sort(key=lambda item: str(item["provider_id"]))
    return {
        "refreshed_at": _timestamp(usage.get("refreshed_at")),
        "next_refresh_at": _timestamp(usage.get("next_refresh_at")),
        "providers": providers,
    }


def build_serve_document(home: Path | None = None) -> dict:
    """Build the endpoint's explicit public projection of persisted truth."""
    latest = _read_json(default_state_dir(home) / "latest.json")
    usage = _read_json(default_provider_usage_state_path(home))
    return {
        "schema_version": SERVE_SCHEMA_VERSION,
        "privacy": "redacted",
        "agents": _public_agents(latest),
        "usage": _public_usage(usage),
    }


def build_authenticated_local_api_response(
    request: LocalAPIRequest | bytes | str,
    *,
    secret: bytes,
    replay_guard: ReplayGuard,
    home: Path | None = None,
    now: float | None = None,
) -> LocalAPIResponse:
    """Serve one authenticated read request without adding a new transport."""
    if not isinstance(replay_guard, ReplayGuard):
        raise ValueError("local API replay guard required")
    parsed = request if type(request) is LocalAPIRequest else decode_request(request)
    generated_at = time.time() if now is None else now
    validate_authenticated_request(
        parsed,
        secret,
        now=generated_at,
        replay_guard=replay_guard,
    )
    document = build_serve_document(home)
    projections: dict[str, dict[str, object]] = {
        "status.read": {"status": document},
        "agents.read": {"agents": document["agents"]},
        "usage.read": {"usage": document["usage"]},
    }
    return redacted_response(
        parsed.capability,
        projections[parsed.capability],
        generated_at=generated_at,
    )


@dataclass(frozen=True, slots=True, repr=False)
class ServeConfiguration:
    """Explicit, in-memory configuration for the loopback server.

    The access token is retained only in this process and is deliberately
    omitted from the configuration representation.
    """

    home: Path | None = None
    status_access_token: bytes | None = field(default=None, repr=False)
    allow_anonymous_status: bool = False
    #: Where ``/asks.json`` and ``/answer`` go (serve_answers.py:
    #: ``ControllerAnswers`` in the daemon, ``CoreSocketAnswers`` for a
    #: standalone ``jrbar serve --allow-answers``); None serves neither.
    answers: object | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if self.home is not None and not isinstance(self.home, Path):
            raise ValueError("invalid serve home")
        if type(self.allow_anonymous_status) is not bool:
            raise ValueError("invalid anonymous status setting")
        token = self.status_access_token
        if token is not None and (
            type(token) is not bytes
            or not 24 <= len(token) <= _MAX_ACCESS_TOKEN_BYTES
        ):
            raise ValueError("invalid access token")
        if self.answers is not None and not all(
            callable(getattr(self.answers, name, None)) for name in ("enabled", "asks", "answer")
        ):
            raise ValueError("invalid answer source")


class _ServeServer(ThreadingHTTPServer):
    def __init__(self, address, handler, configuration: ServeConfiguration) -> None:
        self.serve_configuration = configuration
        super().__init__(address, handler)


class _ServeHandler(BaseHTTPRequestHandler):
    server_version = PRODUCT_DISPLAY_NAME

    def do_GET(self) -> None:
        route = self.path.split("?", 1)[0]
        if route == "/asks.json":
            self._serve_asks()
            return
        if route not in ("/", "/status.json"):
            self.send_error(404)
            return
        configuration = self._configuration()
        if not configuration.allow_anonymous_status and not self._authenticated(
            configuration.status_access_token
        ):
            self._send_authentication_required()
            return
        payload = json.dumps(
            build_serve_document(configuration.home),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:
        route = self.path.split("?", 1)[0]
        if route != "/answer":
            self.send_error(404)
            return
        self._serve_answer()

    # -- answering (serve_answers.py) ------------------------------------------

    def _answer_source(self):
        """The wired answer source when this request may use it, after
        sending the refusal itself when it may not. Never anonymous."""
        from .serve_answers import ServeAnswerRefused

        configuration = self._configuration()
        if configuration.answers is None:
            self.send_error(404)
            return None
        if not self._authenticated(configuration.status_access_token):
            self._send_authentication_required()
            return None
        try:
            enabled = bool(configuration.answers.enabled())
        except Exception:
            enabled = False
        if not enabled:
            refusal = ServeAnswerRefused(
                "answering_off",
                "Answering from serve is off -- turn on serve_answer_enabled.",
            )
            self._send_json(refusal.http_status, refusal.document())
            return None
        return configuration.answers

    def _serve_asks(self) -> None:
        from .serve_answers import ServeAnswerRefused

        answers = self._answer_source()
        if answers is None:
            return
        try:
            asks = answers.asks()
        except ServeAnswerRefused as refusal:
            self._send_json(refusal.http_status, refusal.document())
            return
        except Exception as error:
            refusal = ServeAnswerRefused("internal", f"{error.__class__.__name__}: {error}"[:300])
            self._send_json(500, refusal.document())
            return
        self._send_json(200, {"ok": True, "asks": asks})

    def _serve_answer(self) -> None:
        from .serve_answers import (
            MAX_ANSWER_BODY_BYTES,
            ServeAnswerRefused,
            decode_answer_body,
            parse_answer_target,
            receipt_document,
        )

        answers = self._answer_source()
        if answers is None:
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_ANSWER_BODY_BYTES:
            self._send_json(413, ServeAnswerRefused("invalid_args", "the body is too large").document())
            return
        try:
            body = decode_answer_body(self.rfile.read(length) if length else b"")
            try:
                query = parse_qs(self.path.partition("?")[2], keep_blank_values=True, max_num_fields=8)
            except ValueError:
                raise ServeAnswerRefused("invalid_args", "too many query fields") from None
            target = parse_answer_target({key: values[-1] for key, values in query.items()}, body)
            result = answers.answer(target)
        except ServeAnswerRefused as refusal:
            self._send_json(refusal.http_status, refusal.document())
            return
        except Exception as error:
            # The answer path's own failure: said, never a dropped socket.
            refusal = ServeAnswerRefused("internal", f"{error.__class__.__name__}: {error}"[:300])
            self._send_json(500, refusal.document())
            return
        self._send_json(200, receipt_document(result))

    def _send_json(self, status: int, document: dict) -> None:
        payload = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _configuration(self) -> ServeConfiguration:
        configuration = getattr(self.server, "serve_configuration", None)
        if not isinstance(configuration, ServeConfiguration):
            return ServeConfiguration()
        return configuration

    def _authenticated(self, expected: bytes | None) -> bool:
        if expected is None:
            return False
        supplied = self.headers.get("Authorization")
        if not isinstance(supplied, str) or not supplied.startswith("Bearer "):
            return False
        try:
            candidate = supplied[7:].encode("ascii")
        except UnicodeEncodeError:
            return False
        return hmac.compare_digest(candidate, expected)

    def _send_authentication_required(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args) -> None:
        """Quiet by design; integrators poll this."""


def serve(
    *,
    port: int = SERVE_DEFAULT_PORT,
    status_access_token: bytes | None = None,
    allow_anonymous_status: bool = False,
    answers: object | None = None,
) -> None:
    """Blocking loopback server; Ctrl-C stops it."""
    server = create_serve_server(
        port=port,
        status_access_token=status_access_token,
        allow_anonymous_status=allow_anonymous_status,
        answers=answers,
    )
    print(f"jrbar serve: http://127.0.0.1:{int(port)}/status.json")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def create_serve_server(
    *,
    port: int = SERVE_DEFAULT_PORT,
    home: Path | None = None,
    status_access_token: bytes | None = None,
    allow_anonymous_status: bool = False,
    answers: object | None = None,
) -> ThreadingHTTPServer:
    """Create the loopback server with explicit, testable configuration."""
    configuration = ServeConfiguration(
        home=home,
        status_access_token=status_access_token,
        allow_anonymous_status=allow_anonymous_status,
        answers=answers,
    )
    return _ServeServer(("127.0.0.1", int(port)), _ServeHandler, configuration)


__all__ = [
    "SERVE_DEFAULT_PORT",
    "SERVE_SCHEMA_VERSION",
    "ServeConfiguration",
    "build_authenticated_local_api_response",
    "build_serve_document",
    "create_serve_server",
    "serve",
]
