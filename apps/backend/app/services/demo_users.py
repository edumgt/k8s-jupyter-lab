from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
import time
from typing import Any

import jwt
from jwt import InvalidTokenError
from redis import Redis
from redis.exceptions import RedisError

from app.config import Settings
from app.services.lab_identity import canonical_username

AUTH_TOKEN_PREFIX = "platform:auth:token:"
USER_METRICS_PREFIX = "platform:auth:metrics:"


@dataclass(frozen=True, slots=True)
class DemoUser:
    username: str
    password: str
    role: str
    display_name: str


DEMO_USERS = (
    DemoUser(
        username="test1@test.com",
        password="123456",
        role="user",
        display_name="Test User 1",
    ),
    DemoUser(
        username="test2@test.com",
        password="123456",
        role="user",
        display_name="Test User 2",
    ),
    DemoUser(
        username="admin@test.com",
        password="123456",
        role="admin",
        display_name="Platform Admin",
    ),
)

DEMO_USERS_BY_NAME = {item.username: item for item in DEMO_USERS}

_memory_tokens: dict[str, dict[str, Any]] = {}
_memory_metrics: dict[str, dict[str, Any]] = {}


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _utcnow().isoformat()


def _jwt_decode(token: str, settings: Settings) -> dict[str, Any] | None:
    try:
        payload = jwt.decode(
            token,
            settings.auth_jwt_secret,
            algorithms=[settings.auth_jwt_algorithm],
            issuer=settings.app_name,
        )
    except InvalidTokenError:
        return None
    return payload if isinstance(payload, dict) else None


def _parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _seconds_between(started_at: str | None, finished_at: datetime | None = None) -> int:
    start_dt = _parse_datetime(started_at)
    if start_dt is None:
        return 0
    end_dt = finished_at or _utcnow()
    return max(0, int((end_dt - start_dt).total_seconds()))


def _redis_client(settings: Settings) -> Redis | None:
    client = None
    try:
        client = Redis.from_url(
            settings.redis_url,
            decode_responses=True,
            socket_timeout=1.5,
            socket_connect_timeout=1.5,
        )
        client.ping()
        return client
    except RedisError:
        if client is not None:
            client.close()
        return None


def _default_metrics(user: DemoUser) -> dict[str, Any]:
    return {
        "username": user.username,
        "display_name": user.display_name,
        "role": user.role,
        "login_count": 0,
        "launch_count": 0,
        "total_session_seconds": 0,
        "active_since": None,
        "last_login_at": None,
        "last_launch_at": None,
        "last_stop_at": None,
        "last_seen_status": "idle",
    }


def _load_json(client: Redis, key: str) -> dict[str, Any] | None:
    raw = client.get(key)
    if not raw:
        return None
    return json.loads(raw)


def _save_json(client: Redis, key: str, payload: dict[str, Any], ttl_seconds: int | None = None) -> None:
    encoded = json.dumps(payload)
    if ttl_seconds is None:
        client.set(key, encoded)
    else:
        client.setex(key, ttl_seconds, encoded)


def _token_key(token: str) -> str:
    return f"{AUTH_TOKEN_PREFIX}{token}"


def _metrics_key(username: str) -> str:
    return f"{USER_METRICS_PREFIX}{username}"


def list_demo_users() -> list[dict[str, str]]:
    return [
        {
            "username": user.username,
            "role": user.role,
            "display_name": user.display_name,
        }
        for user in DEMO_USERS
    ]


def list_sandbox_users() -> list[DemoUser]:
    return [user for user in DEMO_USERS if user.role == "user"]


def get_demo_user(username: str) -> DemoUser:
    normalized = canonical_username(username)
    user = DEMO_USERS_BY_NAME.get(normalized)
    if user is None:
        raise ValueError("Unknown demo user.")
    return user


def authenticate_demo_user(username: str, password: str) -> DemoUser:
    user = get_demo_user(username)
    if user.password != password:
        raise ValueError("Invalid username or password.")
    return user


def store_auth_session(settings: Settings, user: DemoUser) -> dict[str, Any]:
    ttl_seconds = max(60, settings.auth_jwt_ttl_seconds)
    issued_at = int(time.time())
    expires_at = issued_at + ttl_seconds
    token = jwt.encode(
        {
            "sub": user.username,
            "role": user.role,
            "display_name": user.display_name,
            "iat": issued_at,
            "exp": expires_at,
            "iss": settings.app_name,
        },
        settings.auth_jwt_secret,
        algorithm=settings.auth_jwt_algorithm,
    )
    payload = {
        "token": token,
        "username": user.username,
        "role": user.role,
        "display_name": user.display_name,
        "created_at": datetime.fromtimestamp(issued_at, timezone.utc).isoformat(),
        "expires_at": datetime.fromtimestamp(expires_at, timezone.utc).isoformat(),
        "expires_in": ttl_seconds,
    }

    return payload


def get_auth_session(settings: Settings, token: str | None) -> dict[str, Any] | None:
    if not token:
        return None

    jwt_payload = _jwt_decode(token, settings)
    if jwt_payload is not None:
        username = str(jwt_payload.get("sub", ""))
        user = DEMO_USERS_BY_NAME.get(username)
        if user is None:
            return None
        role = str(jwt_payload.get("role") or user.role)
        display_name = str(jwt_payload.get("display_name") or user.display_name)
        issued_at = int(jwt_payload.get("iat", 0) or 0)
        expires_at = int(jwt_payload.get("exp", 0) or 0)
        created_at = datetime.fromtimestamp(issued_at, timezone.utc).isoformat() if issued_at else _iso_now()
        expires_at_iso = datetime.fromtimestamp(expires_at, timezone.utc).isoformat() if expires_at else None
        return {
            "token": token,
            "username": username,
            "role": role,
            "display_name": display_name,
            "created_at": created_at,
            "expires_at": expires_at_iso,
            "expires_in": max(0, expires_at - int(time.time())) if expires_at else None,
        }

    client = _redis_client(settings)
    if client is not None:
        try:
            return _load_json(client, _token_key(token))
        finally:
            client.close()

    return _memory_tokens.get(token)


def delete_auth_session(settings: Settings, token: str | None) -> None:
    if not token:
        return

    # JWT is stateless. Keep legacy store cleanup for older session tokens.
    if _jwt_decode(token, settings) is not None:
        return

    client = _redis_client(settings)
    if client is not None:
        try:
            client.delete(_token_key(token))
        finally:
            client.close()
        return

    _memory_tokens.pop(token, None)


def _load_metrics(settings: Settings, user: DemoUser) -> dict[str, Any]:
    client = _redis_client(settings)
    if client is not None:
        try:
            payload = _load_json(client, _metrics_key(user.username))
            return payload or _default_metrics(user)
        finally:
            client.close()

    return dict(_memory_metrics.get(user.username) or _default_metrics(user))


def _save_metrics(settings: Settings, username: str, payload: dict[str, Any]) -> None:
    client = _redis_client(settings)
    if client is not None:
        try:
            _save_json(client, _metrics_key(username), payload)
        finally:
            client.close()
        return

    _memory_metrics[username] = dict(payload)


def get_user_metrics(settings: Settings, username: str) -> dict[str, Any]:
    user = get_demo_user(username)
    return _load_metrics(settings, user)


def record_demo_login(settings: Settings, username: str) -> dict[str, Any]:
    user = get_demo_user(username)
    metrics = _load_metrics(settings, user)
    metrics["login_count"] += 1
    metrics["last_login_at"] = _iso_now()
    _save_metrics(settings, user.username, metrics)
    return metrics


def record_lab_launch(settings: Settings, username: str, created_at: str | None = None) -> dict[str, Any]:
    user = get_demo_user(username)
    metrics = _load_metrics(settings, user)
    started_at = created_at or _iso_now()
    metrics["launch_count"] += 1
    metrics["active_since"] = started_at
    metrics["last_launch_at"] = started_at
    metrics["last_seen_status"] = "provisioning"
    _save_metrics(settings, user.username, metrics)
    return metrics


def record_lab_stop(settings: Settings, username: str) -> dict[str, Any]:
    user = get_demo_user(username)
    metrics = _load_metrics(settings, user)
    if metrics.get("active_since"):
        metrics["total_session_seconds"] += _seconds_between(metrics["active_since"])
    metrics["active_since"] = None
    metrics["last_stop_at"] = _iso_now()
    metrics["last_seen_status"] = "deleted"
    _save_metrics(settings, user.username, metrics)
    return metrics


def sync_session_activity(settings: Settings, username: str, session: dict[str, Any]) -> dict[str, Any]:
    user = get_demo_user(username)
    metrics = _load_metrics(settings, user)
    status = str(session.get("status") or "idle")
    active = status in {"ready", "provisioning"}
    created_at = session.get("created_at") or _iso_now()

    if active:
        if not metrics.get("active_since"):
            metrics["active_since"] = created_at
    elif metrics.get("active_since"):
        metrics["total_session_seconds"] += _seconds_between(metrics["active_since"])
        metrics["active_since"] = None
        metrics["last_stop_at"] = _iso_now()

    metrics["last_seen_status"] = status
    _save_metrics(settings, user.username, metrics)
    return metrics


def current_session_seconds(metrics: dict[str, Any]) -> int:
    if not metrics.get("active_since"):
        return 0
    return _seconds_between(metrics["active_since"])


def build_user_usage(settings: Settings, username: str) -> dict[str, Any]:
    from app.services.jupyter_sessions import get_lab_session

    user = get_demo_user(username)
    try:
        session = get_lab_session(settings, user.username)
        metrics = sync_session_activity(settings, user.username, session)
    except Exception:  # noqa: BLE001 - user usage panel should remain available when k8s is unavailable
        session = {
            "status": "error",
            "pod_name": "",
            "node_port": None,
        }
        metrics = get_user_metrics(settings, user.username)

    current_seconds = current_session_seconds(metrics)
    total_seconds = int(metrics.get("total_session_seconds", 0)) + current_seconds
    return {
        "summary": {
            "username": user.username,
            "display_name": user.display_name,
            "role": user.role,
            "current_status": str(session.get("status") or "idle"),
            "pod_name": str(session.get("pod_name") or ""),
            "node_port": session.get("node_port"),
            "login_count": int(metrics.get("login_count", 0)),
            "launch_count": int(metrics.get("launch_count", 0)),
            "current_session_seconds": current_seconds,
            "total_session_seconds": total_seconds,
            "last_login_at": metrics.get("last_login_at"),
            "last_launch_at": metrics.get("last_launch_at"),
            "last_stop_at": metrics.get("last_stop_at"),
        }
    }


def build_admin_overview(settings: Settings) -> dict[str, Any]:
    from app.services.jupyter_sessions import get_lab_session

    rows: list[dict[str, Any]] = []
    for user in list_sandbox_users():
        try:
            session = get_lab_session(settings, user.username)
            metrics = sync_session_activity(settings, user.username, session)
            detail = session["detail"]
        except Exception as exc:  # noqa: BLE001 - admin UI should stay available even when k8s is unavailable
            session = {
                "username": user.username,
                "session_id": "",
                "namespace": settings.k8s_namespace,
                "pod_name": "",
                "service_name": "",
                "workspace_subpath": "",
                "image": "",
                "status": "error",
                "phase": "Error",
                "ready": False,
                "detail": f"Unable to read session state: {exc}",
                "token": "",
                "node_port": None,
                "created_at": None,
            }
            metrics = get_user_metrics(settings, user.username)
            detail = session["detail"]

        current_seconds = current_session_seconds(metrics)
        total_seconds = int(metrics.get("total_session_seconds", 0)) + current_seconds
        rows.append(
            {
                "username": user.username,
                "display_name": user.display_name,
                "status": session["status"],
                "ready": bool(session["ready"]),
                "detail": detail,
                "pod_name": session["pod_name"],
                "service_name": session["service_name"],
                "workspace_subpath": session["workspace_subpath"],
                "image": session["image"],
                "node_port": session["node_port"],
                "session_id": session["session_id"],
                "phase": session["phase"],
                "login_count": int(metrics.get("login_count", 0)),
                "launch_count": int(metrics.get("launch_count", 0)),
                "current_session_seconds": current_seconds,
                "total_session_seconds": total_seconds,
                "last_login_at": metrics.get("last_login_at"),
                "last_launch_at": metrics.get("last_launch_at"),
                "last_stop_at": metrics.get("last_stop_at"),
            }
        )

    rows.sort(key=lambda item: (item["status"] not in {"ready", "provisioning"}, item["username"]))

    return {
        "summary": {
            "sandbox_user_count": len(rows),
            "running_user_count": sum(1 for item in rows if item["status"] in {"ready", "provisioning"}),
            "ready_user_count": sum(1 for item in rows if item["ready"]),
            "total_login_count": sum(int(item["login_count"]) for item in rows),
            "total_launch_count": sum(int(item["launch_count"]) for item in rows),
            "total_session_seconds": sum(int(item["total_session_seconds"]) for item in rows),
        },
        "users": rows,
    }
