# syntax=docker/dockerfile:1.7
# Placeholder FastAPI service calling myapi-a, to demo distributed tracing.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN pip install \
      "fastapi>=0.115,<1" \
      "uvicorn[standard]>=0.30,<1" \
      "httpx>=0.27,<1" \
      "opentelemetry-distro>=0.50b0" \
      "opentelemetry-exporter-otlp>=1.29" \
 && opentelemetry-bootstrap -a install

COPY <<'EOF' /app/main.py
import asyncio
import logging
import os

import httpx
from fastapi import FastAPI

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger("myapi-b")

MYAPI_A_URL = os.getenv("MYAPI_A_URL", "http://myapi-a:8000")

app = FastAPI(title="myapi-b")
client = httpx.AsyncClient(base_url=MYAPI_A_URL, timeout=5.0)


@app.on_event("shutdown")
async def close_client() -> None:
    await client.aclose()


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/chain")
async def chain(fanout: int = 3) -> dict:
    """Calls myapi-a `fanout` times in parallel -> one trace spanning both services."""
    fanout = max(1, min(fanout, 20))
    responses = await asyncio.gather(
        *(client.get("/work") for _ in range(fanout)), return_exceptions=True
    )
    ok = sum(1 for r in responses if isinstance(r, httpx.Response) and r.status_code == 200)
    if ok < fanout:
        logger.warning("chain partial success: %d/%d", ok, fanout)
    else:
        logger.info("chain success: %d/%d", ok, fanout)
    return {"service": "myapi-b", "calls": fanout, "ok": ok}
EOF

RUN useradd --uid 10001 --no-create-home app
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

CMD ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
