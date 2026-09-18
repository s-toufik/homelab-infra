# myapi-a

> Kept for documentation only — not part of the running stack. Disabled by default (commented out of the `include:` list in the root `compose.yml`).

This is a minimal FastAPI service, packaged and containerized the same way the real Python APIs in this stack are (`agent-toolbox`, `agent-orchestrator`): a `pyproject.toml` + `src/` layout built with `uv`, and a multi-stage Dockerfile that `uv sync --no-dev --no-editable`s into a builder stage, then copies just the resulting `.venv` into a slim, non-root runtime image. It's kept here as a reference for that template, and to show how an app plugs into the observability stack — auto-instrumented with `opentelemetry-instrument`, sending **traces, metrics and logs** over OTLP/HTTP to `otel-collector:4318`.

| Endpoint | Behaviour |
|----------|-----------|
| `GET /health` | liveness (excluded from tracing) |
| `GET /work`   | sleeps 10–300 ms, fails 5% of the time, custom span + counter |

URL (if enabled): http://<server>:8001/docs

## Using this as a template for a real app

1. Copy `pyproject.toml`, `Dockerfile`, and the `src/` layout as a starting point.
2. Replace `src/myapi_a/` with your own package; update `[tool.setuptools.packages.find]` if the name changes, and the Dockerfile's final `CMD` to point at your app.
3. Keep the `OTEL_*` environment variables from `compose.yml`: that's all the wiring this stack needs. For a real Python API here, that means either the generic `opentelemetry-instrument` auto-instrumentation approach used here, or a project's own telemetry adapter (see `agent-toolbox`/`agent-orchestrator`, which configure `OTEL_HOST`/`OTEL_PORT` for pycraftcore's own OTel provider instead).
