from __future__ import annotations

import logging
from datetime import datetime

from airflow import DAG
from airflow.operators.python import PythonOperator
from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException

logger = logging.getLogger(__name__)


def _load_cluster_config() -> None:
    try:
        config.load_incluster_config()
        logger.info("Loaded in-cluster Kubernetes config.")
    except ConfigException:
        config.load_kube_config()
        logger.info("Loaded local kubeconfig.")


def _node_ready_status(node: client.V1Node) -> str:
    for condition in node.status.conditions or []:
        if condition.type == "Ready":
            return condition.status or "Unknown"
    return "Unknown"


def check_kube_nodes_and_pods() -> None:
    _load_cluster_config()

    core_api = client.CoreV1Api()
    nodes = core_api.list_node().items
    pods = core_api.list_pod_for_all_namespaces().items

    logger.info("Kubernetes status snapshot started.")
    logger.info("NODE_SUMMARY total_nodes=%d", len(nodes))

    not_ready_nodes: list[str] = []
    for node in nodes:
        node_name = node.metadata.name
        ready = _node_ready_status(node)
        kubelet_version = (node.status.node_info.kubelet_version if node.status and node.status.node_info else "Unknown")
        logger.info(
            "NODE_STATUS name=%s ready=%s kubelet_version=%s",
            node_name,
            ready,
            kubelet_version,
        )
        if ready != "True":
            not_ready_nodes.append(node_name)

    phase_counts: dict[str, int] = {}
    non_running_pods: list[tuple[str, str, str]] = []
    for pod in pods:
        phase = pod.status.phase or "Unknown"
        phase_counts[phase] = phase_counts.get(phase, 0) + 1

        if phase not in ("Running", "Succeeded"):
            non_running_pods.append(
                (pod.metadata.namespace, pod.metadata.name, phase),
            )

    logger.info("POD_SUMMARY total_pods=%d", len(pods))
    for phase_name, count in sorted(phase_counts.items()):
        logger.info("POD_PHASE phase=%s count=%d", phase_name, count)

    if not_ready_nodes:
        logger.warning("NOT_READY_NODES count=%d nodes=%s", len(not_ready_nodes), ",".join(not_ready_nodes))
    else:
        logger.info("All nodes are Ready.")

    if non_running_pods:
        logger.warning("NON_RUNNING_PODS count=%d", len(non_running_pods))
        for namespace, pod_name, phase in non_running_pods[:200]:
            logger.warning("POD_STATUS namespace=%s name=%s phase=%s", namespace, pod_name, phase)
    else:
        logger.info("All pods are Running or Succeeded.")


with DAG(
    dag_id="kube_system_status_check",
    start_date=datetime(2025, 1, 1),
    schedule="*/10 * * * *",
    catchup=False,
    tags=["platform", "kubernetes", "monitoring"],
) as dag:
    PythonOperator(
        task_id="check_nodes_and_pods",
        python_callable=check_kube_nodes_and_pods,
    )
