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
