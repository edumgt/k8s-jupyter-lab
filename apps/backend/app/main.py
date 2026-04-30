from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.models import (
    AdminSandboxOverviewResponse,
    ControlPlaneDashboardResponse,
    ControlPlaneLoginRequest,
    ControlPlaneLoginResponse,
    DashboardResponse,
    DemoUserInfo,
    DemoUserLoginRequest,
    DemoUserLoginResponse,
    DemoUserSessionResponse,
    LabSessionRequest,
    LabSessionResponse,
    SnapshotStatusResponse,
    TeradataQueryRequest,
    TeradataQueryResponse,
    UserUsageResponse,
)
from app.services.catalog import quick_links, runtime_profile, sample_queries
from app.services.control_plane import (
    build_control_plane_dashboard,
    build_control_plane_token,
    verify_control_plane_credentials,
    verify_control_plane_token,
)
from app.services.demo_users import (
    authenticate_demo_user,
    build_admin_overview,
    delete_auth_session,
    get_auth_session,
    build_user_usage,
    list_demo_users,
    record_demo_login,
    store_auth_session,
)
from app.services.jupyter_sessions import delete_lab_session, ensure_lab_session, get_lab_session
from app.services.jupyter_snapshots import create_snapshot_publish_job, get_snapshot_status
from app.services.lab_identity import canonical_username
from app.services.mongo import get_mongo_status
from app.services.redis_store import get_redis_status
from app.services.teradata import run_ansi_query, teradata_summary
from app.version import BACKEND_APP_VERSION

settings = get_settings()

app = FastAPI(title="k8s-data-platform-api", version=BACKEND_APP_VERSION)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_origin_regex=settings.cors_allow_origin_regex,
    allow_credentials=settings.cors_allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)


def list_notebooks(notebooks_path: str) -> list[str]:
    path = Path(notebooks_path)
    if not path.exists():
        return []
    return sorted(item.name for item in path.iterdir() if item.suffix == ".ipynb")


def resolve_auth_token(
    authorization: str | None,
    x_auth_token: str | None,
) -> str | None:
    if authorization:
        parts = authorization.strip().split(" ", 1)
        if len(parts) == 2 and parts[0].lower() == "bearer" and parts[1].strip():
            return parts[1].strip()

    if x_auth_token:
        token = x_auth_token.strip()
        if token:
            return token

    return None


def require_control_plane_access(
    authorization: str | None = Header(default=None),
    x_auth_token: str | None = Header(default=None),
    x_control_plane_token: str | None = Header(default=None),
):
    settings = get_settings()
    auth_token = resolve_auth_token(authorization, x_auth_token)
    auth_session = get_auth_session(settings, auth_token)
    if auth_session and auth_session.get("role") == "admin":
        return settings

    control_plane_token = x_control_plane_token.strip() if x_control_plane_token else auth_token
    if not verify_control_plane_token(settings, control_plane_token):
        raise HTTPException(
            status_code=401,
            detail="Control-plane login required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return settings


def require_authenticated_user(
    authorization: str | None = Header(default=None),
    x_auth_token: str | None = Header(default=None),
):
    settings = get_settings()
    token = resolve_auth_token(authorization, x_auth_token)
    session = get_auth_session(settings, token)
    if not session:
        raise HTTPException(
            status_code=401,
            detail="Application login required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return session


def require_admin_user(current_user=Depends(require_authenticated_user)):
    if current_user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin role required.")
    return current_user


def authorize_username_access(current_user: dict[str, object], username: str) -> str:
    normalized = canonical_username(username)
    if current_user.get("role") == "admin":
        return normalized
    if current_user.get("username") != normalized:
        raise HTTPException(status_code=403, detail="You can only access your own Jupyter sandbox.")
    return normalized


@app.get("/healthz")
def healthz() -> dict[str, object]:
    settings = get_settings()
    mongo_ok, mongo_detail = get_mongo_status(settings.mongo_url)
    redis_ok, redis_detail = get_redis_status(settings.redis_url)
    overall_status = "ok" if mongo_ok and redis_ok else "degraded"
    return {
        "status": overall_status,
        "backend_version": BACKEND_APP_VERSION,
        "checks": {
            "mongodb": {"ok": mongo_ok, "detail": mongo_detail},
            "redis": {"ok": redis_ok, "detail": redis_detail},
        },
    }


@app.get("/livez")
def livez() -> dict[str, object]:
    return {
        "status": "ok",
        "backend_version": BACKEND_APP_VERSION,
    }


@app.get("/api/notebooks")
def notebooks() -> dict[str, list[str]]:
    settings = get_settings()
    return {"items": list_notebooks(settings.notebooks_path)}


@app.get("/api/demo-users")
def demo_users() -> dict[str, object]:
    return {"items": list_demo_users()}


@app.post("/api/auth/login", response_model=DemoUserLoginResponse)
def login_demo_user(request: DemoUserLoginRequest) -> DemoUserLoginResponse:
    settings = get_settings()
    try:
        user = authenticate_demo_user(request.username, request.password)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    session = store_auth_session(settings, user)
    record_demo_login(settings, user.username)
    return DemoUserLoginResponse(
        access_token=session["token"],
        token_type="bearer",
        expires_in=int(session["expires_in"]),
        token=session["token"],
        user=DemoUserInfo(
            username=user.username,
            role=user.role,
            display_name=user.display_name,
        ),
    )


@app.get("/api/auth/me", response_model=DemoUserSessionResponse)
def read_auth_session(current_user=Depends(require_authenticated_user)) -> DemoUserSessionResponse:
    return DemoUserSessionResponse(
        user=DemoUserInfo(
            username=str(current_user["username"]),
            role=str(current_user["role"]),
            display_name=str(current_user["display_name"]),
        )
    )


@app.post("/api/auth/logout")
def logout_demo_user(
    current_user=Depends(require_authenticated_user),
) -> dict[str, str]:
    settings = get_settings()
    delete_auth_session(settings, str(current_user.get("token") or ""))
    return {"status": "ok"}


@app.get("/api/users/me/usage", response_model=UserUsageResponse)
def read_my_usage(current_user=Depends(require_authenticated_user)) -> UserUsageResponse:
    settings = get_settings()
    username = str(current_user["username"])
    try:
        return UserUsageResponse(**build_user_usage(settings, username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/api/dashboard", response_model=DashboardResponse)
def dashboard() -> DashboardResponse:
    settings = get_settings()
    mongo_ok, mongo_detail = get_mongo_status(settings.mongo_url)
    redis_ok, redis_detail = get_redis_status(settings.redis_url)

    services = [
        {
            "name": "backend",
            "kind": "api",
            "endpoint": "http://backend:8000",
            "ok": True,
            "detail": "FastAPI service ready",
        },
        {
            "name": "mongodb",
            "kind": "database",
            "endpoint": settings.mongo_url,
            "ok": mongo_ok,
            "detail": mongo_detail,
        },
        {
            "name": "redis",
            "kind": "cache",
            "endpoint": settings.redis_url,
            "ok": redis_ok,
            "detail": redis_detail,
        },
        {
            "name": "control-plane-dashboard",
            "kind": "cluster-admin",
            "endpoint": settings.control_plane_url,
            "ok": True,
            "detail": "Frontend control-plane dashboard with node and pod inventory after admin login",
        },
        {
            "name": "jupyter",
            "kind": "workbench",
            "endpoint": settings.jupyter_url,
            "ok": True,
            "detail": "Shared JupyterLab plus per-user Jupyter sessions with PVC workspace restore and Harbor snapshots",
        },
        {
            "name": "gitlab",
            "kind": "cicd",
            "endpoint": settings.gitlab_url,
            "ok": True,
            "detail": "GitLab CE web UI is exposed by ingress; SSH is available on port 30224.",
        },
    ]

    if settings.airflow_url:
        services.insert(
            4,
            {
                "name": "airflow",
                "kind": "orchestrator",
                "endpoint": settings.airflow_url,
                "ok": True,
                "detail": "Optional Airflow webserver for scheduled health checks and DAG demos",
            },
        )

    if settings.nexus_url:
        services.append(
            {
                "name": "nexus",
                "kind": "artifact-repository",
                "endpoint": settings.nexus_url,
                "ok": True,
                "detail": "Offline npm and PyPI cache for closed-network rebuilds and one-pod runtime prep",
            }
        )

    return DashboardResponse(
        runtime=runtime_profile(settings),
        services=services,
        quick_links=quick_links(settings),
        sample_queries=sample_queries(),
        notebooks=list_notebooks(settings.notebooks_path),
        teradata=teradata_summary(settings),
    )


@app.post("/api/teradata/query", response_model=TeradataQueryResponse)
def teradata_query(request: TeradataQueryRequest) -> TeradataQueryResponse:
    settings = get_settings()
    result = run_ansi_query(settings, request.sql, request.limit)
    return TeradataQueryResponse(**result)


@app.post("/api/jupyter/sessions", response_model=LabSessionResponse)
def create_jupyter_session(
    request: LabSessionRequest,
    current_user=Depends(require_authenticated_user),
) -> LabSessionResponse:
    settings = get_settings()
    try:
        username = authorize_username_access(current_user, request.username)
        return LabSessionResponse(**ensure_lab_session(settings, username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/api/jupyter/sessions/{username}", response_model=LabSessionResponse)
def read_jupyter_session(
    username: str,
    current_user=Depends(require_authenticated_user),
) -> LabSessionResponse:
    settings = get_settings()
    try:
        allowed_username = authorize_username_access(current_user, username)
        return LabSessionResponse(**get_lab_session(settings, allowed_username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.delete("/api/jupyter/sessions/{username}", response_model=LabSessionResponse)
def remove_jupyter_session(
    username: str,
    current_user=Depends(require_authenticated_user),
) -> LabSessionResponse:
    settings = get_settings()
    try:
        allowed_username = authorize_username_access(current_user, username)
        return LabSessionResponse(**delete_lab_session(settings, allowed_username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/api/jupyter/snapshots/{username}", response_model=SnapshotStatusResponse)
def read_jupyter_snapshot(
    username: str,
    current_user=Depends(require_authenticated_user),
) -> SnapshotStatusResponse:
    settings = get_settings()
    try:
        allowed_username = authorize_username_access(current_user, username)
        return SnapshotStatusResponse(**get_snapshot_status(settings, allowed_username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/api/jupyter/snapshots", response_model=SnapshotStatusResponse)
def publish_jupyter_snapshot(
    request: LabSessionRequest,
    current_user=Depends(require_authenticated_user),
) -> SnapshotStatusResponse:
    settings = get_settings()
    try:
        username = authorize_username_access(current_user, request.username)
        return SnapshotStatusResponse(**create_snapshot_publish_job(settings, username))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/api/admin/sandboxes", response_model=AdminSandboxOverviewResponse)
def read_admin_sandbox_overview(_current_user=Depends(require_admin_user)) -> AdminSandboxOverviewResponse:
    settings = get_settings()
    try:
        return AdminSandboxOverviewResponse(**build_admin_overview(settings))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.post("/api/control-plane/login", response_model=ControlPlaneLoginResponse)
def control_plane_login(request: ControlPlaneLoginRequest) -> ControlPlaneLoginResponse:
    settings = get_settings()
    try:
        user = authenticate_demo_user(request.username, request.password)
    except ValueError:
        if not verify_control_plane_credentials(settings, request.username, request.password):
            raise HTTPException(status_code=401, detail="Invalid control-plane credentials.") from None
        dashboard = build_control_plane_dashboard(settings, namespace="all")
        return ControlPlaneLoginResponse(
            token=build_control_plane_token(settings, request.username),
            username=request.username,
            dashboard=ControlPlaneDashboardResponse(**dashboard),
        )

    if user.role != "admin":
        raise HTTPException(status_code=403, detail="Admin role required for control-plane access.")

    session = store_auth_session(settings, user)
    record_demo_login(settings, user.username)
    dashboard = build_control_plane_dashboard(settings, namespace="all")
    return ControlPlaneLoginResponse(
        token=session["token"],
        username=user.username,
        dashboard=ControlPlaneDashboardResponse(**dashboard),
    )


@app.get("/api/control-plane/dashboard", response_model=ControlPlaneDashboardResponse)
def control_plane_dashboard(
    namespace: str = "all",
    settings=Depends(require_control_plane_access),
) -> ControlPlaneDashboardResponse:
    try:
        return ControlPlaneDashboardResponse(**build_control_plane_dashboard(settings, namespace))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
