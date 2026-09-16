# myapi-a

Placeholder FastAPI service showing how an app plugs into the observability stack. It is auto-instrumented with `opentelemetry-instrument` and sends **traces, metrics and logs** over OTLP/HTTP to `otel-collector:4318`.

| Endpoint | Behaviour |
|----------|-----------|
| `GET /health` | liveness (excluded from tracing) |
| `GET /work`   | sleeps 10–300 ms, fails 5% of the time, custom span + counter |

URL: http://<server>:8001/docs

## Replace with your own app

The Dockerfile embeds `main.py` with a heredoc so the repo stays minimal. For a real project:

1. Put your code next to the Dockerfile (e.g. `src/`, `pyproject.toml`).
2. Replace the `COPY <<'EOF' ...` block with `COPY . /app` and install your dependencies.
3. Keep the `OTEL_*` environment variables in `compose.yml`: that's all the wiring needed. Any language with an OTel SDK works the same way.
