#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

ROOT_DIR = Path(__file__).resolve().parents[1]
BACKEND_DIR = ROOT_DIR / "apps" / "backend"
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from fastapi import HTTPException
from kubernetes.client.exceptions import ApiException

from app.config import get_settings
from app.main import (
    create_jupyter_session,
    login_demo_user,
    read_admin_sandbox_overview,
    read_jupyter_session,
    require_authenticated_user,
)
from app.models import DemoUserLoginRequest, LabSessionRequest
from app.services import demo_users
from app.services.jupyter_sessions import _restore_workspace_script
from app.services.jupyter_snapshots import get_snapshot_status


def fake_session_summary(username: str, minutes_ago: int = 1) -> dict[str, object]:
    created_at = (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()
    session_id = username.replace("@", "-").replace(".", "-")
    return {
        "session_id": session_id,
        "username": username,
        "namespace": "data-platform-dev",
        "pod_name": f"lab-{session_id}",
        "service_name": f"lab-{session_id}",
        "workspace_subpath": f"users/{session_id}",
        "image": "harbor.local/data-platform/k8s-data-platform-jupyter:latest",
        "status": "ready",
        "phase": "Running",
        "ready": True,
        "detail": "JupyterLab is ready on NodePort 31000.",
        "token": "demo-token",
        "node_port": 31000 + minutes_ago,
        "created_at": created_at,
    }


class DemoAuthFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        demo_users._memory_tokens.clear()
        demo_users._memory_metrics.clear()
        get_settings.cache_clear()

        self.session_state = {
            "test1@test.com": fake_session_summary("test1@test.com", minutes_ago=3),
            "test2@test.com": fake_session_summary("test2@test.com", minutes_ago=7),
        }

        def fake_ensure_lab_session(settings, username: str):
            summary = dict(self.session_state[username])
            demo_users.record_lab_launch(settings, username, str(summary["created_at"]))
            demo_users.sync_session_activity(settings, username, summary)
            return summary

        def fake_get_lab_session(settings, username: str):
            summary = dict(self.session_state[username])
            demo_users.sync_session_activity(settings, username, summary)
            return summary

        self.patches = ExitStack()
        self.patches.enter_context(patch("app.main.ensure_lab_session", fake_ensure_lab_session))
        self.patches.enter_context(patch("app.main.get_lab_session", fake_get_lab_session))
        self.patches.enter_context(
            patch("app.services.jupyter_sessions.get_lab_session", fake_get_lab_session)
        )
        self.patches.enter_context(patch("app.services.demo_users._redis_client", lambda settings: None))

    def tearDown(self) -> None:
        self.patches.close()

    def login(self, username: str, password: str = "123456"):
        response = login_demo_user(DemoUserLoginRequest(username=username, password=password))
        current_user = require_authenticated_user(response.token)
        return response, current_user

    def test_demo_user_login_and_own_jupyter_session(self) -> None:
        login_response, current_user = self.login("test1@test.com")
        self.assertEqual(login_response.user.username, "test1@test.com")
        self.assertEqual(login_response.user.role, "user")

        session = create_jupyter_session(
            LabSessionRequest(username="test1@test.com"),
            current_user=current_user,
        )
        self.assertEqual(session.username, "test1@test.com")
        self.assertEqual(session.status, "ready")
        self.assertTrue(session.ready)
        self.assertIn("lab-test1-test-com", session.pod_name)

        with self.assertRaises(HTTPException) as exc:
            read_jupyter_session("test2@test.com", current_user=current_user)
        self.assertEqual(exc.exception.status_code, 403)

    def test_admin_can_monitor_multiple_sandbox_users(self) -> None:
        _response1, user1 = self.login("test1@test.com")
        _response2, user2 = self.login("test2@test.com")

        create_jupyter_session(LabSessionRequest(username="test1@test.com"), current_user=user1)
        create_jupyter_session(LabSessionRequest(username="test2@test.com"), current_user=user2)

        _admin_response, admin_user = self.login("admin@test.com")
        overview = read_admin_sandbox_overview(_current_user=admin_user)

        self.assertEqual(overview.summary.sandbox_user_count, 2)
        self.assertEqual(overview.summary.running_user_count, 2)

        users = {item.username: item for item in overview.users}
        self.assertEqual(users["test1@test.com"].launch_count, 1)
        self.assertEqual(users["test2@test.com"].launch_count, 1)
        self.assertGreaterEqual(users["test1@test.com"].current_session_seconds, 1)
        self.assertGreaterEqual(users["test2@test.com"].current_session_seconds, 1)
        self.assertTrue(users["test1@test.com"].ready)
        self.assertTrue(users["test2@test.com"].ready)

    def test_snapshot_status_falls_back_when_job_listing_is_forbidden(self) -> None:
        settings = get_settings()
        with patch(
            "app.services.jupyter_snapshots.get_batch_v1_api",
            side_effect=ApiException(status=403, reason="Forbidden"),
        ):
            snapshot = get_snapshot_status(settings, "test1@test.com")

        self.assertEqual(snapshot["status"], "missing")
        self.assertFalse(snapshot["restorable"])
        self.assertIn("base Jupyter image", snapshot["detail"])

    def test_restore_workspace_script_keeps_shell_variables_intact(self) -> None:
        settings = get_settings()
        script = _restore_workspace_script(
            settings,
            "harbor.local/data-platform/k8s-data-platform-jupyter:latest",
            "users/test1-test-com",
        )

        self.assertIn('workspace_dir="/workspace-volume/users/test1-test-com"', script)
        self.assertIn('${workspace_dir}', script)
        self.assertNotIn("NameError", script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
