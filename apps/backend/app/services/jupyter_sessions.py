from __future__ import annotations

import hashlib

from kubernetes import client
from kubernetes.client.exceptions import ApiException
from kubernetes.config.config_exception import ConfigException

from app.config import Settings
from app.services.demo_users import record_lab_launch, record_lab_stop, sync_session_activity
from app.services.jupyter_snapshots import create_snapshot_publish_job, resolve_launch_image_for_identity
from app.services.kube_client import get_core_v1_api
from app.services.lab_identity import LabIdentity, build_lab_identity

SESSION_COMPONENT = "jupyter-session"
SESSION_LABEL_KEY = "platform.dev/session-id"
MANAGED_BY = "k8s-data-platform-api"


def _read_pod(api: client.CoreV1Api, namespace: str, name: str) -> client.V1Pod | None:
    try:
        return api.read_namespaced_pod(name=name, namespace=namespace)
    except ApiException as exc:
        if exc.status == 404:
            return None
        raise


def _read_service(api: client.CoreV1Api, namespace: str, name: str) -> client.V1Service | None:
    try:
        return api.read_namespaced_service(name=name, namespace=namespace)
    except ApiException as exc:
        if exc.status == 404:
            return None
        raise


def _session_labels(session_id: str) -> dict[str, str]:
    return {
        "app": SESSION_COMPONENT,
        "app.kubernetes.io/name": SESSION_COMPONENT,
        "app.kubernetes.io/component": SESSION_COMPONENT,
        "app.kubernetes.io/managed-by": MANAGED_BY,
        SESSION_LABEL_KEY: session_id,
    }


def _container_detail(pod: client.V1Pod) -> str | None:
    statuses = (pod.status.container_statuses if pod.status else None) or []
    for status in statuses:
        if status.ready:
            continue
        state = status.state
        if state and state.waiting:
            message = state.waiting.message or "container is starting"
            return f"{state.waiting.reason}: {message}"
        if state and state.terminated:
            message = state.terminated.message or "container terminated"
            return f"{state.terminated.reason}: {message}"
    return None


def _is_pod_ready(pod: client.V1Pod | None) -> bool:
    if pod is None or pod.status is None:
        return False
    conditions = pod.status.conditions or []
    return any(condition.type == "Ready" and condition.status == "True" for condition in conditions)


def _created_at(pod: client.V1Pod | None) -> str | None:
    if pod is None or pod.metadata is None or pod.metadata.creation_timestamp is None:
        return None
    return pod.metadata.creation_timestamp.isoformat()


def _pod_image(pod: client.V1Pod | None) -> str | None:
    if pod is None or pod.spec is None:
        return None
    containers = pod.spec.containers or []
    if not containers:
        return None
    return containers[0].image


def _restore_workspace_script(settings: Settings, launch_image: str, workspace_subpath: str) -> str:
    return f"""
set -eu
workspace_dir="/workspace-volume/{workspace_subpath}"
mkdir -p "${{workspace_dir}}"
if [ -z "$(find "${{workspace_dir}}" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ] && [ -d "{settings.jupyter_bootstrap_dir}" ]; then
  cp -a {settings.jupyter_bootstrap_dir}/. "${{workspace_dir}}"/ 2>/dev/null || true
fi
mkdir -p "${{workspace_dir}}/.platform"
printf '%s\\n' '{launch_image}' > "${{workspace_dir}}/.platform/launch-image"
""".strip()


def _snapshot_publish_fields(settings: Settings, username: str) -> dict[str, str | None]:
    try:
        snapshot = create_snapshot_publish_job(settings, username)
        return {
            "snapshot_status": str(snapshot.get("status") or ""),
            "snapshot_job_name": str(snapshot.get("job_name") or "") or None,
            "snapshot_detail": str(snapshot.get("detail") or ""),
        }
    except ValueError as exc:
        return {
            "snapshot_status": "skipped",
            "snapshot_job_name": None,
            "snapshot_detail": str(exc),
        }
    except RuntimeError as exc:
        return {
            "snapshot_status": "failed",
            "snapshot_job_name": None,
            "snapshot_detail": str(exc),
        }


def _session_summary(
    settings: Settings,
    identity: LabIdentity,
    pod: client.V1Pod | None,
    service: client.V1Service | None,
    launch_image: str,
) -> dict[str, object]:
    raw_node_port = None
    if service and service.spec and service.spec.ports:
        raw_node_port = service.spec.ports[0].node_port

    phase = "Missing"
    if pod and pod.status and pod.status.phase:
        phase = pod.status.phase

    ready = _is_pod_ready(pod)
    if pod is None:
        status = "missing"
        detail = "No personal JupyterLab session exists yet."
    elif phase == "Failed":
        status = "failed"
        detail = _container_detail(pod) or "Pod failed to start."
    elif ready and raw_node_port:
        status = "ready"
        detail = f"JupyterLab is ready on NodePort {raw_node_port}."
    else:
        status = "provisioning"
        detail = _container_detail(pod) or "JupyterLab pod is being prepared."

    # Keep stale NodePort values out of the API response when the pod is not ready.
    # This prevents clients from opening orphaned links that will fail with connection refused.
    exposed_node_port = raw_node_port if (ready and raw_node_port) else None

    return {
        "session_id": identity.session_id,
        "username": identity.username,
        "namespace": settings.k8s_namespace,
        "pod_name": identity.pod_name,
        "service_name": identity.service_name,
        "workspace_subpath": identity.workspace_subpath,
        "image": _pod_image(pod) or launch_image,
        "status": status,
        "phase": phase,
        "ready": ready and bool(raw_node_port),
        "detail": detail,
        "token": build_session_token(settings, identity.session_id),
        "node_port": exposed_node_port,
        "created_at": _created_at(pod),
    }


def build_session_token(settings: Settings, session_id: str) -> str:
    seed = f"{settings.jupyter_token}:{session_id}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:24]


def _create_pod(api: client.CoreV1Api, settings: Settings, identity: LabIdentity, launch_image: str) -> None:
    pod = client.V1Pod(
        metadata=client.V1ObjectMeta(
            name=identity.pod_name,
            labels=_session_labels(identity.session_id),
            annotations={
                "platform.dev/username": identity.username,
                "platform.dev/workspace-subpath": identity.workspace_subpath,
                "platform.dev/launch-image": launch_image,
            },
        ),
        spec=client.V1PodSpec(
            restart_policy="Always",
            termination_grace_period_seconds=15,
            init_containers=[
                client.V1Container(
                    name="restore-workspace",
                    image=launch_image,
                    image_pull_policy="IfNotPresent",
                    command=["/bin/sh", "-c", _restore_workspace_script(settings, launch_image, identity.workspace_subpath)],
                    env=[
                        client.V1EnvVar(name="JUPYTER_ROOT_DIR", value=settings.jupyter_workspace_root),
                        client.V1EnvVar(name="JUPYTER_BOOTSTRAP_DIR", value=settings.jupyter_bootstrap_dir),
                    ],
                    volume_mounts=[
                        client.V1VolumeMount(name="jupyter-workspace", mount_path="/workspace-volume")
                    ],
                )
            ],
            containers=[
                client.V1Container(
                    name="jupyter",
                    image=launch_image,
                    image_pull_policy="IfNotPresent",
                    ports=[client.V1ContainerPort(container_port=8888)],
                    env=[
                        client.V1EnvVar(
                            name="JUPYTER_TOKEN",
                            value=build_session_token(settings, identity.session_id),
                        ),
                        client.V1EnvVar(name="JUPYTER_ROOT_DIR", value=settings.jupyter_workspace_root),
                        client.V1EnvVar(name="JUPYTER_BOOTSTRAP_DIR", value=settings.jupyter_bootstrap_dir),
                        client.V1EnvVar(name="PLATFORM_LAB_USERNAME", value=identity.username),
                        client.V1EnvVar(name="PLATFORM_LAB_SESSION_ID", value=identity.session_id),
                    ],
                    resources=client.V1ResourceRequirements(
                        requests={"cpu": "100m", "memory": "256Mi"},
                        limits={"cpu": "1000m", "memory": "1Gi"},
                    ),
                    volume_mounts=[
                        client.V1VolumeMount(
                            name="jupyter-workspace",
                            mount_path=settings.jupyter_workspace_root,
                            sub_path=identity.workspace_subpath,
                        )
                    ],
                    readiness_probe=client.V1Probe(
                        http_get=client.V1HTTPGetAction(path="/lab", port=8888),
                        initial_delay_seconds=5,
                        period_seconds=5,
                        timeout_seconds=2,
                        failure_threshold=18,
                    ),
                    liveness_probe=client.V1Probe(
                        http_get=client.V1HTTPGetAction(path="/lab", port=8888),
                        initial_delay_seconds=20,
                        period_seconds=10,
                        timeout_seconds=2,
                        failure_threshold=6,
                    ),
                )
            ],
            volumes=[
                client.V1Volume(
                    name="jupyter-workspace",
                    persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                        claim_name=settings.jupyter_workspace_pvc,
                    ),
                )
            ],
        ),
    )
    api.create_namespaced_pod(namespace=settings.k8s_namespace, body=pod)


def _create_service(api: client.CoreV1Api, settings: Settings, identity: LabIdentity) -> None:
    service = client.V1Service(
        metadata=client.V1ObjectMeta(
            name=identity.service_name,
            labels=_session_labels(identity.session_id),
        ),
        spec=client.V1ServiceSpec(
            type="NodePort",
            selector={SESSION_LABEL_KEY: identity.session_id},
            ports=[
                client.V1ServicePort(
                    name="http",
                    port=8888,
                    target_port=8888,
                    protocol="TCP",
                )
            ],
        ),
    )
    api.create_namespaced_service(namespace=settings.k8s_namespace, body=service)


def get_lab_session(settings: Settings, username: str) -> dict[str, object]:
    identity = build_lab_identity(username)

    try:
        api = get_core_v1_api()
        pod = _read_pod(api, settings.k8s_namespace, identity.pod_name)
        service = _read_service(api, settings.k8s_namespace, identity.service_name)
        launch_image = _pod_image(pod)
        if launch_image is None:
            launch_image, _snapshot = resolve_launch_image_for_identity(settings, identity)
        summary = _session_summary(settings, identity, pod, service, launch_image)
        sync_session_activity(settings, identity.username, summary)
        return summary
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        raise RuntimeError(f"Kubernetes API error while reading Jupyter session: {exc.reason}") from exc


def ensure_lab_session(settings: Settings, username: str) -> dict[str, object]:
    identity = build_lab_identity(username)
    created_new_session = False

    try:
        api = get_core_v1_api()
        launch_image, _snapshot = resolve_launch_image_for_identity(settings, identity)
        pod = _read_pod(api, settings.k8s_namespace, identity.pod_name)
        if pod and pod.status and pod.status.phase in {"Failed", "Succeeded"}:
            api.delete_namespaced_pod(name=identity.pod_name, namespace=settings.k8s_namespace)
            pod = None

        if pod is None:
            _create_pod(api, settings, identity, launch_image)
            created_new_session = True

        service = _read_service(api, settings.k8s_namespace, identity.service_name)
        if service is None:
            _create_service(api, settings, identity)

        pod = _read_pod(api, settings.k8s_namespace, identity.pod_name)
        service = _read_service(api, settings.k8s_namespace, identity.service_name)
        summary = _session_summary(settings, identity, pod, service, launch_image)
        if created_new_session:
            record_lab_launch(settings, identity.username, summary.get("created_at"))
        else:
            sync_session_activity(settings, identity.username, summary)
        return summary
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        raise RuntimeError(f"Kubernetes API error while creating Jupyter session: {exc.reason}") from exc


def delete_lab_session(settings: Settings, username: str) -> dict[str, object]:
    identity = build_lab_identity(username)

    try:
        api = get_core_v1_api()
        summary = get_lab_session(settings, identity.username)

        try:
            api.delete_namespaced_service(name=identity.service_name, namespace=settings.k8s_namespace)
        except ApiException as exc:
            if exc.status != 404:
                raise

        try:
            api.delete_namespaced_pod(name=identity.pod_name, namespace=settings.k8s_namespace)
        except ApiException as exc:
            if exc.status != 404:
                raise

        summary["status"] = "deleted"
        summary["phase"] = "Deleted"
        summary["ready"] = False
        summary["detail"] = "Personal JupyterLab session resources were deleted."
        summary["node_port"] = None
        summary.update(_snapshot_publish_fields(settings, identity.username))
        snapshot_status = str(summary.get("snapshot_status") or "")
        if snapshot_status in {"pending", "building"}:
            summary["detail"] = (
                "Personal JupyterLab session resources were deleted. "
                "Harbor snapshot publish started."
            )
        elif snapshot_status == "ready":
            summary["detail"] = (
                "Personal JupyterLab session resources were deleted. "
                "Latest Harbor snapshot is ready."
            )
        elif snapshot_status == "failed":
            summary["detail"] = (
                "Personal JupyterLab session resources were deleted. "
                "Harbor snapshot publish failed."
            )
        record_lab_stop(settings, identity.username)
        return summary
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        raise RuntimeError(f"Kubernetes API error while deleting Jupyter session: {exc.reason}") from exc
