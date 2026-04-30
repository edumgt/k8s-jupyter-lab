from datetime import datetime

import requests
from airflow import DAG
from airflow.operators.python import PythonOperator

SERVICES = {
    "backend": "http://backend:8000/healthz",
    "jupyter": "http://jupyter:8888/lab",
    "frontend": "http://frontend",
}


def check_service(name: str, url: str) -> None:
    response = requests.get(url, timeout=10)
    response.raise_for_status()
    print(f"{name} ok: {url}")


with DAG(
    dag_id="platform_health_check",
    start_date=datetime(2025, 1, 1),
    schedule="*/15 * * * *",
    catchup=False,
    tags=["platform", "health"],
) as dag:
    for service_name, service_url in SERVICES.items():
        PythonOperator(
            task_id=f"check_{service_name}",
            python_callable=check_service,
            op_kwargs={"name": service_name, "url": service_url},
        )
