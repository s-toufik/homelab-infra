# syntax=docker/dockerfile:1.7
# Placeholder FastAPI service documenting the real Dockerfile/uv template used
# by this stack's Python APIs (agent-toolbox, agent-orchestrator). See README.md.
FROM python:3.12-slim AS builder

RUN pip install --no-cache-dir uv

WORKDIR /build
COPY pyproject.toml uv.lock* ./
COPY src ./src

RUN uv sync --no-dev --no-editable

FROM python:3.12-slim

RUN useradd --create-home --uid 1000 app
WORKDIR /app

COPY --from=builder /build/.venv /app/.venv
COPY src ./src

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH="/app/src"

USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

CMD ["opentelemetry-instrument", "uvicorn", "myapi_a.main:app", "--host", "0.0.0.0", "--port", "8000"]
