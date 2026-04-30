FROM harbor.local/data-platform/platform-airflow-base:2.10.5-python3.12

USER airflow

COPY --chown=airflow:root requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

COPY --chown=airflow:root dags /opt/airflow/dags
