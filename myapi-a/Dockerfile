# syntax=docker/dockerfile:1.7
# Placeholder FastAPI service, auto-instrumented with OpenTelemetry.
# Replace the inline app with your own code (see README.md).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN pip install \
      "fastapi>=0.115,<1" \
      "uvicorn[standard]>=0.30,<1" \
      "opentelemetry-distro>=0.50b0" \
      "opentelemetry-exporter-otlp>=1.29" \
 && opentelemetry-bootstrap -a install

COPY <<'EOF' /app/main.py
import asyncio
import logging
import random

from fastapi import FastAPI, HTTPException
from opentelemetry import metrics, trace

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger("myapi-a")

tracer = trace.get_tracer("myapi-a")
meter = metrics.get_meter("myapi-a")
work_counter = meter.create_counter("myapi_a_work", description="Work requests by outcome")

app = FastAPI(title="myapi-a")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/work")
async def work() -> dict:
    with tracer.start_as_current_span("compute") as span:
        delay = random.uniform(0.01, 0.3)
        span.set_attribute("work.delay_ms", int(delay * 1000))
        await asyncio.sleep(delay)
        if random.random() < 0.05:
            work_counter.add(1, {"outcome": "error"})
            logger.error("simulated failure after %d ms", int(delay * 1000))
            raise HTTPException(status_code=500, detail="simulated failure")
    work_counter.add(1, {"outcome": "ok"})
    logger.info("work done in %d ms", int(delay * 1000))
    return {"service": "myapi-a", "delay_ms": int(delay * 1000)}
EOF

RUN useradd --uid 10001 --no-create-home app
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

CMD ["opentelemetry-instrument", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
