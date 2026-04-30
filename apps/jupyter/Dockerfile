FROM harbor.local/data-platform/platform-python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    JUPYTER_ROOT_DIR=/workspace/user-home \
    JUPYTER_BOOTSTRAP_DIR=/opt/platform/bootstrap-workspace

WORKDIR /workspace

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bootstrap/start-notebook.sh /usr/local/bin/start-notebook.sh
COPY work ${JUPYTER_BOOTSTRAP_DIR}

RUN chmod +x /usr/local/bin/start-notebook.sh \
  && mkdir -p "${JUPYTER_ROOT_DIR}"

EXPOSE 8888

CMD ["/usr/local/bin/start-notebook.sh"]
