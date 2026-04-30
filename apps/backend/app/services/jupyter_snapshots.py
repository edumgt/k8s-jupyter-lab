from __future__ import annotations

import base64
from datetime import datetime, timezone

from kubernetes import client
from kubernetes.client.exceptions import ApiException
from kubernetes.config.config_exception import ConfigException

from app.config import Settings
from app.services.kube_client import get_batch_v1_api
from app.services.lab_identity import LabIdentity, build_lab_identity, snapshot_image

SNAPSHOT_COMPONENT = "jupyter-snapshot"
SESSION_LABEL_KEY = "platform.dev/session-id"


def _job_label_selector(session_id: str) -> str:
    return f"app.kubernetes.io/component={SNAPSHOT_COMPONENT},{SESSION_LABEL_KEY}={session_id}"


def _job_sort_key(job: client.V1Job):
    timestamp = job.metadata.creation_timestamp
    return timestamp or datetime.min.replace(tzinfo=timezone.utc)


def _job_state(job: client.V1Job) -> str:
    status = job.status
    if status is None:
        return "pending"
    if status.active:
        return "building"
    if status.succeeded:
        return "ready"
    if status.failed:
        return "failed"
    return "pending"


def _iso_timestamp(value: object) -> str | None:
    return value.isoformat() if hasattr(value, "isoformat") else None


def _list_session_jobs(api: client.BatchV1Api, settings: Settings, session_id: str) -> list[client.V1Job]:
    jobs = api.list_namespaced_job(
        namespace=settings.k8s_namespace,
        label_selector=_job_label_selector(session_id),
    ).items
    return sorted(jobs, key=_job_sort_key, reverse=True)


def get_snapshot_status_for_identity(settings: Settings, identity: LabIdentity) -> dict[str, object]:
    image = snapshot_image(settings, identity.session_id)

    try:
        api = get_batch_v1_api()
        jobs = _list_session_jobs(api, settings, identity.session_id)
        latest_job = jobs[0] if jobs else None
        latest_succeeded_job = next((job for job in jobs if _job_state(job) == "ready"), None)

        if latest_job is None:
            status = "missing"
            detail = "No Harbor snapshot has been published for this user yet."
        else:
            status = _job_state(latest_job)
            if status == "ready":
                detail = "Latest workspace snapshot is published to Harbor and ready to restore."
            elif status == "building":
                detail = "Workspace snapshot is currently being pushed to Harbor."
            elif status == "failed":
                detail = "Latest Harbor publish job failed. The last successful image can still be restored."
            else:
                detail = "Harbor publish job is pending."

        return {
            "username": identity.username,
            "session_id": identity.session_id,
            "workspace_subpath": identity.workspace_subpath,
            "image": image,
            "status": status,
            "job_name": latest_job.metadata.name if latest_job else None,
            "published_at": _iso_timestamp(
                latest_succeeded_job.status.completion_time if latest_succeeded_job and latest_succeeded_job.status else None
            ),
            "restorable": latest_succeeded_job is not None,
            "detail": detail,
        }
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        if exc.status == 403:
            return {
                "username": identity.username,
                "session_id": identity.session_id,
                "workspace_subpath": identity.workspace_subpath,
                "image": image,
                "status": "missing",
                "job_name": None,
                "published_at": None,
                "restorable": False,
                "detail": "Harbor snapshot lookup is not permitted in this environment, so the base Jupyter image will be used.",
            }
        raise RuntimeError(f"Kubernetes API error while reading Harbor snapshot status: {exc.reason}") from exc


def get_snapshot_status(settings: Settings, username: str) -> dict[str, object]:
    return get_snapshot_status_for_identity(settings, build_lab_identity(username))


def resolve_launch_image_for_identity(settings: Settings, identity: LabIdentity) -> tuple[str, dict[str, object]]:
    snapshot = get_snapshot_status_for_identity(settings, identity)
    if snapshot["restorable"]:
        return str(snapshot["image"]), snapshot
    return settings.jupyter_image, snapshot


def resolve_launch_image(settings: Settings, username: str) -> tuple[str, dict[str, object]]:
    return resolve_launch_image_for_identity(settings, build_lab_identity(username))


def create_snapshot_publish_job(settings: Settings, username: str) -> dict[str, object]:
    identity = build_lab_identity(username)

    if not settings.harbor_user or not settings.harbor_password:
        raise ValueError("Harbor credentials are required to publish a user snapshot image.")

    try:
        api = get_batch_v1_api()
        jobs = _list_session_jobs(api, settings, identity.session_id)
        active_job = next((job for job in jobs if _job_state(job) == "building"), None)
        if active_job is not None:
            return get_snapshot_status_for_identity(settings, identity)

        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        job_name = f"publish-{identity.session_id}-{timestamp}"[:63]
        image = snapshot_image(settings, identity.session_id)
        encoded_auth = base64.b64encode(
            f"{settings.harbor_user}:{settings.harbor_password}".encode("utf-8"),
        ).decode("utf-8")
        subpath = identity.workspace_subpath

        kaniko_args = [
            "--dockerfile=/context/Dockerfile",
            "--context=dir:///context",
            f"--destination={image}",
        ]
        if settings.harbor_insecure_registry:
            kaniko_args.extend(
                [
                    "--insecure",
                    "--skip-tls-verify",
                    f"--insecure-registry={settings.harbor_registry}",
                ]
            )

        prepare_script = f"""
set -eu
mkdir -p /context/workspace
mkdir -p /docker-config
mkdir -p /workspace-data/{subpath}
cp -R /workspace-data/{subpath}/. /context/workspace/ 2>/dev/null || true
cat > /context/Dockerfile <<'EOF'
FROM {settings.jupyter_image}
ENV JUPYTER_ROOT_DIR={settings.jupyter_workspace_root}
ENV JUPYTER_BOOTSTRAP_DIR={settings.jupyter_bootstrap_dir}
COPY workspace/ {settings.jupyter_bootstrap_dir}/
EOF
cat > /docker-config/config.json <<'EOF'
{{"auths":{{"{settings.harbor_registry}":{{"auth":"{encoded_auth}"}}}}}}
EOF
""".strip()

        job = client.V1Job(
            metadata=client.V1ObjectMeta(
                name=job_name,
                labels={
                    "app.kubernetes.io/name": SNAPSHOT_COMPONENT,
                    "app.kubernetes.io/component": SNAPSHOT_COMPONENT,
                    SESSION_LABEL_KEY: identity.session_id,
                },
                annotations={
                    "platform.dev/username": identity.username,
                    "platform.dev/published-image": image,
                },
            ),
            spec=client.V1JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=86400,
                template=client.V1PodTemplateSpec(
                    metadata=client.V1ObjectMeta(
                        labels={
                            "app.kubernetes.io/name": SNAPSHOT_COMPONENT,
                            "app.kubernetes.io/component": SNAPSHOT_COMPONENT,
                            SESSION_LABEL_KEY: identity.session_id,
                        },
                    ),
                    spec=client.V1PodSpec(
                        restart_policy="Never",
                        init_containers=[
                            client.V1Container(
                                name="prepare-context",
                                image="harbor.local/data-platform/platform-busybox:1.36",
                                command=["/bin/sh", "-c", prepare_script],
                                volume_mounts=[
                                    client.V1VolumeMount(name="context", mount_path="/context"),
                                    client.V1VolumeMount(name="docker-config", mount_path="/docker-config"),
                                    client.V1VolumeMount(name="jupyter-workspace", mount_path="/workspace-data"),
                                ],
                            )
                        ],
                        containers=[
                            client.V1Container(
                                name="kaniko",
                                image=settings.jupyter_snapshot_builder_image,
                                args=kaniko_args,
                                volume_mounts=[
                                    client.V1VolumeMount(name="context", mount_path="/context"),
                                    client.V1VolumeMount(name="docker-config", mount_path="/kaniko/.docker"),
                                ],
                            )
                        ],
                        volumes=[
                            client.V1Volume(name="context", empty_dir=client.V1EmptyDirVolumeSource()),
                            client.V1Volume(name="docker-config", empty_dir=client.V1EmptyDirVolumeSource()),
                            client.V1Volume(
                                name="jupyter-workspace",
                                persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                                    claim_name=settings.jupyter_workspace_pvc,
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )
        api.create_namespaced_job(namespace=settings.k8s_namespace, body=job)
        return get_snapshot_status_for_identity(settings, identity)
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        raise RuntimeError(f"Kubernetes API error while creating Harbor publish job: {exc.reason}") from exc
