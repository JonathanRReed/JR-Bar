"""Renew only Factory sessions whose owner approved browser-token rotation."""

from __future__ import annotations

import base64
import json
import math
import threading

from .factory_session import SESSION_LOCK, WORKOS_CLIENT_IDS, _text, fingerprint, save_if_current
from .provider_usage_collectors import ProviderHttpError

WORKOS_URL = "https://api.workos.com/user_management/authenticate"
_COLLECTION_LOCKS = {}


class FactorySessionChanged(Exception):
    pass


class FactoryCredentialUnavailable(Exception):
    pass


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


def renew(session, expected, credentials, http_json):
    """Persist rotation before using access, without changing browser-owned files."""
    if session["consent_version"] != 2 or session.get("refresh_rejected"):
        raise ProviderHttpError(401, "refresh_rejected")
    with SESSION_LOCK:
        current = credentials.get("factory", "web-session")
        if not current.available or fingerprint(current.secret) != expected:
            raise FactorySessionChanged
    clients = (session["client_id"],) if session.get("client_id") else WORKOS_CLIENT_IDS
    for index, client in enumerate(clients):
        body = {"client_id": client, "grant_type": "refresh_token", "refresh_token": session["refresh_token"]}
        if session.get("organization_id"):
            body["organization_id"] = session["organization_id"]
        try:
            result = http_json("POST", WORKOS_URL,
                               headers={"Accept": "application/json", "Content-Type": "application/json"}, body=body)
        except ProviderHttpError as error:
            if error.status not in {400, 401}:
                raise
            if index + 1 < len(clients):
                continue
            rejected = {**session, "refresh_rejected": True}
            _save(credentials, expected, rejected)
            raise ProviderHttpError(401, "refresh_rejected") from None
        if not isinstance(result, dict) or not _text(result.get("access_token")) or not _text(result.get("refresh_token")):
            raise ValueError("invalid Factory renewal")
        updated = {**session, "access_token": result["access_token"],
                   "refresh_token": result["refresh_token"], "client_id": client}
        _save(credentials, expected, updated)
        encoded = json.dumps(updated, separators=(",", ":"), sort_keys=True)
        return updated, fingerprint(encoded)
    raise ProviderHttpError(401, "refresh_rejected")
