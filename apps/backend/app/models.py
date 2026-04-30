from typing import Any

from pydantic import BaseModel, Field


class ServiceStatus(BaseModel):
    name: str
    kind: str
    endpoint: str
    ok: bool
    detail: str


class QuickLink(BaseModel):
    name: str
    url: str
    description: str


class SampleQuery(BaseModel):
    name: str
    description: str
    sql: str


class DashboardResponse(BaseModel):
    runtime: dict[str, str]
    services: list[ServiceStatus]
    quick_links: list[QuickLink]
    sample_queries: list[SampleQuery]
    notebooks: list[str]
    teradata: dict[str, Any]


class TeradataQueryRequest(BaseModel):
    sql: str = Field(min_length=1)
    limit: int = Field(default=20, ge=1, le=200)


class TeradataQueryResponse(BaseModel):
    columns: list[str]
    rows: list[dict[str, Any]]
    source: str
    note: str


class LabSessionRequest(BaseModel):
    username: str = Field(min_length=2, max_length=48)


class LabSessionResponse(BaseModel):
    session_id: str
    username: str
    namespace: str
    pod_name: str
    service_name: str
    workspace_subpath: str
    image: str
    status: str
    phase: str
    ready: bool
    detail: str
    token: str
    node_port: int | None = None
    created_at: str | None = None
    snapshot_status: str | None = None
    snapshot_job_name: str | None = None
    snapshot_detail: str | None = None


class SnapshotStatusResponse(BaseModel):
    username: str
    session_id: str
    workspace_subpath: str
    image: str
    status: str
    job_name: str | None = None
    published_at: str | None = None
    restorable: bool
    detail: str


class DemoUserInfo(BaseModel):
    username: str
    role: str
    display_name: str


class DemoUserLoginRequest(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class DemoUserLoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    token: str
    user: DemoUserInfo


class DemoUserSessionResponse(BaseModel):
    user: DemoUserInfo


class UserUsageSummary(BaseModel):
    username: str
    display_name: str
    role: str
    current_status: str
    pod_name: str
    node_port: int | None = None
    login_count: int
    launch_count: int
    current_session_seconds: int
    total_session_seconds: int
    last_login_at: str | None = None
    last_launch_at: str | None = None
    last_stop_at: str | None = None


class UserUsageResponse(BaseModel):
    summary: UserUsageSummary


class AdminSandboxSummary(BaseModel):
    sandbox_user_count: int
    running_user_count: int
    ready_user_count: int
    total_login_count: int
    total_launch_count: int
    total_session_seconds: int


class AdminSandboxUserRow(BaseModel):
    username: str
    display_name: str
    status: str
    ready: bool
    detail: str
    pod_name: str
    service_name: str
    workspace_subpath: str
    image: str
    node_port: int | None = None
    session_id: str
    phase: str
    login_count: int
    launch_count: int
    current_session_seconds: int
    total_session_seconds: int
    last_login_at: str | None = None
    last_launch_at: str | None = None
    last_stop_at: str | None = None


class AdminSandboxOverviewResponse(BaseModel):
    summary: AdminSandboxSummary
    users: list[AdminSandboxUserRow]


class ControlPlaneLoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class ControlPlaneSummary(BaseModel):
    cluster_name: str
    cluster_version: str
    current_namespace: str
    namespace_count: int
    node_count: int
    ready_node_count: int
    pod_count: int
    running_pod_count: int


class ControlPlaneNode(BaseModel):
    name: str
    ready: bool
    roles: str
    version: str
    internal_ip: str
    os_image: str
    kernel_version: str
    container_runtime: str
    created_at: str | None = None


class ControlPlanePod(BaseModel):
    namespace: str
    name: str
    ready: str
    status: str
    restarts: int
    node_name: str
    pod_ip: str | None = None
    created_at: str | None = None


class ControlPlaneDashboardResponse(BaseModel):
    summary: ControlPlaneSummary
    namespaces: list[str]
    nodes: list[ControlPlaneNode]
    pods: list[ControlPlanePod]


class ControlPlaneLoginResponse(BaseModel):
    token: str
    username: str
    dashboard: ControlPlaneDashboardResponse
