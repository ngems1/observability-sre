# One image, two workloads:
#   ticket-api    -> default CMD (uvicorn)
#   ticket-worker -> command: ["python", "-m", "opsdesk.worker.main"]
#   migrations    -> command: ["alembic", "upgrade", "head"]
FROM python:3.12-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /venv && /venv/bin/pip install -r requirements.txt

FROM python:3.12-slim-bookworm
LABEL org.opencontainers.image.title="opsdesk" \
      org.opencontainers.image.description="OpsDesk internal ticketing (Week 4 SRE project)"
ENV PATH="/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /venv /venv
WORKDIR /app
COPY alembic.ini ./
COPY migrations ./migrations
COPY opsdesk ./opsdesk
USER 10001:10001
EXPOSE 8080 9100
CMD ["uvicorn", "opsdesk.api.main:build", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
