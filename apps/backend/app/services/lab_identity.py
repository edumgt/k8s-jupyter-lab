from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from app.config import Settings


@dataclass(frozen=True, slots=True)
class LabIdentity:
    username: str
    session_id: str
    pod_name: str
    service_name: str
    workspace_subpath: str


def canonical_username(username: str) -> str:
    normalized = username.strip().lower()
    if len(normalized) < 2 or len(normalized) > 48:
        raise ValueError("username must be between 2 and 48 characters")
    if not re.fullmatch(r"[a-z0-9._@-]+", normalized):
        raise ValueError("username may contain only letters, numbers, dot, underscore, dash, and @")
    return normalized


def build_session_id(username: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", username).strip("-")
    slug = (slug[:24] or "user").strip("-") or "user"
    digest = hashlib.sha1(username.encode("utf-8")).hexdigest()[:8]
    return f"{slug}-{digest}"


def pod_name(session_id: str) -> str:
    return f"lab-{session_id}"


def service_name(session_id: str) -> str:
    return f"lab-{session_id}"


def workspace_subpath(session_id: str) -> str:
    return f"users/{session_id}"


def build_lab_identity(username: str) -> LabIdentity:
    normalized = canonical_username(username)
    session_id = build_session_id(normalized)
    return LabIdentity(
        username=normalized,
        session_id=session_id,
        pod_name=pod_name(session_id),
        service_name=service_name(session_id),
        workspace_subpath=workspace_subpath(session_id),
    )


def snapshot_image(settings: Settings, session_id: str) -> str:
    registry = settings.harbor_registry.rstrip("/")
    return f"{registry}/{settings.harbor_project}/jupyter-user-{session_id}:latest"
