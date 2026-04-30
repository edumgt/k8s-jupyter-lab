from __future__ import annotations

import hashlib
import secrets

from kubernetes.client import V1Node, V1NodeCondition, V1Pod
from kubernetes.client.exceptions import ApiException
from kubernetes.config.config_exception import ConfigException

from app.config import Settings
from app.services.kube_client import get_core_v1_api, get_version_api


def build_control_plane_token(settings: Settings, username: str) -> str:
    seed = f"{username}:{settings.control_plane_password}:{settings.control_plane_session_secret}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def verify_control_plane_credentials(settings: Settings, username: str, password: str) -> bool:
    return secrets.compare_digest(username, settings.control_plane_username) and secrets.compare_digest(
        password,
        settings.control_plane_password,
    )


def verify_control_plane_token(settings: Settings, token: str | None) -> bool:
    if not token:
        return False
    expected = build_control_plane_token(settings, settings.control_plane_username)
    return secrets.compare_digest(token, expected)


def _iso_timestamp(value: object) -> str | None:
    return value.isoformat() if hasattr(value, "isoformat") else None


def _node_ready(node: V1Node) -> bool:
    conditions = node.status.conditions or []
    return any(isinstance(condition, V1NodeCondition) and condition.type == "Ready" and condition.status == "True" for condition in conditions)


def _node_roles(node: V1Node) -> str:
    labels = node.metadata.labels or {}
    roles = sorted(
        key.split("/", 1)[1]
        for key, value in labels.items()
        if key.startswith("node-role.kubernetes.io/") and value == ""
    )
    if not roles and labels.get("kubernetes.io/role"):
        roles = [labels["kubernetes.io/role"]]
    return ",".join(roles) if roles else "worker"


def _node_internal_ip(node: V1Node) -> str:
    addresses = node.status.addresses or []
    for address in addresses:
        if address.type == "InternalIP":
            return address.address
    return "-"


def _pod_ready(pod: V1Pod) -> str:
    statuses = pod.status.container_statuses or []
    total = len(statuses)
    ready = sum(1 for status in statuses if status.ready)
    return f"{ready}/{total}" if total else "0/0"


def _pod_restarts(pod: V1Pod) -> int:
    statuses = pod.status.container_statuses or []
    return sum(status.restart_count for status in statuses)


def build_control_plane_dashboard(settings: Settings, namespace: str = "all") -> dict[str, object]:
    if not namespace:
        namespace = "all"

    try:
        core_api = get_core_v1_api()
        version_api = get_version_api()

        namespaces = sorted(item.metadata.name for item in core_api.list_namespace().items)
        if namespace != "all" and namespace not in namespaces:
            raise ValueError(f"Unknown namespace: {namespace}")

        node_items = sorted(core_api.list_node().items, key=lambda item: item.metadata.name)
        if namespace == "all":
            pod_items = sorted(
                core_api.list_pod_for_all_namespaces().items,
                key=lambda item: (item.metadata.namespace, item.metadata.name),
            )
        else:
            pod_items = sorted(
                core_api.list_namespaced_pod(namespace=namespace).items,
                key=lambda item: item.metadata.name,
            )

        cluster_version = version_api.get_code().git_version
        nodes = [
            {
                "name": node.metadata.name,
                "ready": _node_ready(node),
                "roles": _node_roles(node),
                "version": node.status.node_info.kubelet_version,
                "internal_ip": _node_internal_ip(node),
                "os_image": node.status.node_info.os_image,
                "kernel_version": node.status.node_info.kernel_version,
                "container_runtime": node.status.node_info.container_runtime_version,
                "created_at": _iso_timestamp(node.metadata.creation_timestamp),
            }
            for node in node_items
        ]
        pods = [
            {
                "namespace": pod.metadata.namespace,
                "name": pod.metadata.name,
                "ready": _pod_ready(pod),
                "status": pod.status.phase,
                "restarts": _pod_restarts(pod),
                "node_name": pod.spec.node_name or "-",
                "pod_ip": pod.status.pod_ip,
                "created_at": _iso_timestamp(pod.metadata.creation_timestamp),
            }
            for pod in pod_items
        ]

        return {
            "summary": {
                "cluster_name": "Kubernetes control plane",
                "cluster_version": cluster_version,
                "current_namespace": namespace,
                "namespace_count": len(namespaces),
                "node_count": len(nodes),
                "ready_node_count": sum(1 for item in nodes if item["ready"]),
                "pod_count": len(pods),
                "running_pod_count": sum(1 for item in pods if item["status"] == "Running"),
            },
            "namespaces": ["all", *namespaces],
            "nodes": nodes,
            "pods": pods,
        }
    except ConfigException as exc:
        raise RuntimeError("Kubernetes client configuration is unavailable.") from exc
    except ApiException as exc:
        raise RuntimeError(f"Kubernetes API error while reading control-plane data: {exc.reason}") from exc
