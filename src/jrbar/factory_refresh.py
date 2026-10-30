"""Renew only Factory sessions whose owner approved browser-token rotation."""

from __future__ import annotations

import base64
import json
import logging
import math
import threading

from .browser_session_import import BrowserSessionReadError
from .factory_session import SESSION_LOCK, WORKOS_CLIENT_IDS, _text, fingerprint, save_if_current
from .provider_usage_collectors import ProviderHttpError

WORKOS_URL = "https://api.workos.com/user_management/authenticate"
_COLLECTION_LOCKS = {}
_LOG = logging.getLogger(__name__)


class FactorySessionChanged(Exception):
    pass


class FactoryCredentialUnavailable(Exception):
    pass


class FactoryRenewalFailure(ProviderHttpError):
    def __init__(self, status, code):
        super().__init__(status, "factory_renewal_" + code, error_code=code)


class FactoryRenewalRejected(FactoryRenewalFailure):
    def __init__(self, status, code):
        super().__init__(status, code)
        self.reason = "factory_refresh_" + self.error_code


def _save(credentials, expected, session):
    try:
        if not save_if_current(credentials, expected, session):
            raise FactorySessionChanged
    except FactorySessionChanged:
        raise
    except Exception:
        raise FactoryCredentialUnavailable from None


def collection_lock(instance):
    with SESSION_LOCK:
        return _COLLECTION_LOCKS.setdefault(instance, threading.RLock())


def access_expired(token, now):
    if not token:
        return True
    try:
        part = token.split(".")[1]
        claims = json.loads(base64.b64decode(part + "=" * (-len(part) % 4), altchars=b"-_", validate=True))
        expiry = claims.get("exp")
        return type(expiry) in {int, float} and math.isfinite(expiry) and expiry <= now + 30
    except (ValueError, TypeError, IndexError, AttributeError):
        return False


def _check_current(credentials, expected):
    with SESSION_LOCK:
        current = credentials.get("factory", "web-session")
        if not current.available or fingerprint(current.secret) != expected:
            raise FactorySessionChanged


def _exchange(session, expected, credentials, http_json):
    for index, client in enumerate(WORKOS_CLIENT_IDS):
        _check_current(credentials, expected)
        body = {"client_id": client, "grant_type": "refresh_token", "refresh_token": session["refresh_token"]}
        if session.get("organization_id"):
            body["organization_id"] = session["organization_id"]
        try:
            result = http_json("POST", WORKOS_URL,
                               headers={"Accept": "application/json", "Content-Type": "application/json"}, body=body)
        except ProviderHttpError as error:
            _LOG.warning("Factory renewal failed status=%d error=%s", error.status, error.error_code)
            if error.status not in {400, 401}:
                raise FactoryRenewalFailure(error.status, error.error_code) from None
            if index + 1 < len(WORKOS_CLIENT_IDS):
                continue
            raise FactoryRenewalRejected(error.status, error.error_code) from None
        if not isinstance(result, dict) or not _text(result.get("access_token")) or not _text(result.get("refresh_token")):
            _LOG.warning("Factory renewal failed status=200 error=invalid_response")
            raise ValueError("invalid Factory renewal")
        updated = {key: value for key, value in session.items() if not key.startswith("refresh_")}
        updated.update(access_token=result["access_token"], refresh_token=result["refresh_token"], client_id=client)
        _save(credentials, expected, updated)
        encoded = json.dumps(updated, separators=(",", ":"), sort_keys=True)
        return updated, fingerprint(encoded)
    raise AssertionError("no Factory clients")


def renew(session, expected, credentials, http_json, *, now, source_instance_id="default"):
    """Try the saved token, then one consented browser re-read, with persisted backoff."""
    from .factory_session import read_browser_session, refresh_recovery_allowed

    if session["consent_version"] != 2:
        raise FactoryRenewalRejected(401, "unknown_error")
    rejected = FactoryRenewalRejected(session.get("refresh_status", 401), session.get("refresh_error", "unknown_error"))
    if session.get("refresh_rejected"):
        if now < session.get("refresh_retry_at", 0):
            raise rejected
    else:
        try:
            return _exchange(session, expected, credentials, http_json)
        except FactoryRenewalRejected as error:
            rejected = error
    _check_current(credentials, expected)
    # Version 2 consent includes this profile's three fields even when legacy
    # access-only background repair is disabled. Never scan other profiles.
    if refresh_recovery_allowed(session, source_instance_id=source_instance_id):
        try:
            current = read_browser_session(session["browser"], session["profile"])
        except (OSError, ValueError, BrowserSessionReadError):
            current = None
        if current and current["refresh_token"] != session["refresh_token"]:
            candidate = {**session, "refresh_token": current["refresh_token"]}
            try:
                return _exchange(candidate, expected, credentials, http_json)
            except FactoryRenewalRejected as error:
                rejected = error
    failures = min(session.get("refresh_failures", 0) + 1, 20)
    delay = min(60 * 2 ** (failures - 1), 900)
    updated = {**session, "refresh_rejected": True, "refresh_error": rejected.error_code,
               "refresh_status": rejected.status, "refresh_failures": failures, "refresh_retry_at": now + delay}
    _save(credentials, expected, updated)
    raise rejected
