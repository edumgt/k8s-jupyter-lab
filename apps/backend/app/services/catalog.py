from app.config import Settings
from app.version import BACKEND_APP_VERSION


def runtime_profile(settings: Settings) -> dict[str, str]:
    return {
        "backend_version": BACKEND_APP_VERSION,
        "environment": settings.env,
        "host_os": "Ubuntu 24",
        "cluster": "Kubernetes single-node control plane",
        "containers": "OCI images on Kubernetes",
        "backend": "Python 3.12 / FastAPI",
        "frontend": "Node 22.22 / Quasar Vue 3",
        "orchestration": "Apache Airflow (optional health-check scheduler)",
        "workbench": "JupyterLab pod",
        "data": "MongoDB, Redis, Teradata ANSI SQL",
        "artifact_repositories": "Nexus (PyPI/npm offline cache), Harbor (Jupyter snapshot only)",
        "cicd": "Docker Hub(edumgt), GitHub Actions, GitLab Runner(k8s executor), Harbor snapshot",
    }


def sample_queries() -> list[dict[str, str]]:
    return [
        {
            "name": "active_workloads",
            "description": "Airflow and Jupyter workloads currently tracked by the lab.",
            "sql": (
                "SELECT workload_name, owner_name, workload_status "
                "FROM lab_workloads "
                "WHERE workload_status <> 'STOPPED' "
                "ORDER BY updated_at DESC;"
            ),
        },
        {
            "name": "dag_runtime_summary",
            "description": "Recent DAG durations using ANSI SQL window functions.",
            "sql": (
                "SELECT dag_name, run_date, duration_seconds "
                "FROM dag_runtime_summary "
                "QUALIFY ROW_NUMBER() OVER "
                "(PARTITION BY dag_name ORDER BY run_date DESC) <= 5;"
            ),
        },
        {
            "name": "jupyter_notebook_usage",
            "description": "Notebook usage counts for shared data science workspaces.",
            "sql": (
                "SELECT notebook_name, owner_name, execution_count "
                "FROM notebook_usage "
                "ORDER BY execution_count DESC;"
            ),
        },
    ]


def quick_links(settings: Settings) -> list[dict[str, str]]:
    links = [
        {
            "name": "Backend API",
            "url": settings.backend_url,
            "description": "FastAPI OpenAPI and health endpoints.",
        },
        {
            "name": "Frontend",
            "url": settings.frontend_url,
            "description": "Quasar dashboard for the platform lab.",
        },
        {
            "name": "Control Plane",
            "url": settings.control_plane_url,
            "description": "Frontend module for cluster admin login, node list, and pod inventory.",
        },
        {
            "name": "Sandbox Admin",
            "url": settings.admin_url,
            "description": "Admin monitoring for demo user Jupyter sandbox usage, launch counts, and active sessions.",
        },
        {
            "name": "Jupyter",
            "url": settings.jupyter_url,
            "description": "Shared JupyterLab entrypoint. Personal labs launch from the frontend session module.",
        },
        {
            "name": "GitLab",
            "url": settings.gitlab_url,
            "description": "SCM and pipeline control plane.",
        },
        {
            "name": "Harbor",
            "url": settings.harbor_url,
            "description": "Per-user Jupyter snapshot registry target.",
        },
    ]

    if settings.airflow_url:
        links.insert(
            4,
            {
                "name": "Airflow",
                "url": settings.airflow_url,
                "description": "Optional workflow orchestration UI.",
            },
        )

    if settings.nexus_url:
        links.append(
            {
                "name": "Nexus",
                "url": settings.nexus_url,
                "description": "Offline package repository for PyPI and npm caches.",
            }
        )

    return links
