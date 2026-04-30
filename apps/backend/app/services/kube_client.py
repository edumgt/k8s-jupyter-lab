from functools import lru_cache

from kubernetes import client, config
from kubernetes.config.config_exception import ConfigException


@lru_cache
def _load_config() -> None:
    try:
        config.load_incluster_config()
    except ConfigException:
        config.load_kube_config()


@lru_cache
def get_core_v1_api() -> client.CoreV1Api:
    _load_config()
    return client.CoreV1Api()


@lru_cache
def get_version_api() -> client.VersionApi:
    _load_config()
    return client.VersionApi()


@lru_cache
def get_batch_v1_api() -> client.BatchV1Api:
    _load_config()
    return client.BatchV1Api()
