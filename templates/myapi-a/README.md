# myapi-a

> A template, not part of the running homelab: copy it to start a new API.

A minimal FastAPI service, packaged and released the same way as the real Python APIs of the homelab (`agent-toolbox`, `agent-runtime`): a `pyproject.toml` + `src/` layout built with `uv`, a multi-stage Dockerfile that copies only the resulting `.venv` into a slim, non-root image, and a `devops/helm/values.yml` that says how it runs on the server. It is auto-instrumented with `opentelemetry-instrument`: **traces, metrics and logs** go over OTLP/HTTP to `otel-collector:4318`.

| Endpoint | Behaviour |
|----------|-----------|
| `GET /health` | readiness and liveness (excluded from tracing) |
| `GET /work`   | sleeps 10–300 ms, fails 5% of the time, custom span + counter |

```text
myapi-a/
├── pyproject.toml, uv.lock, src/    the app
└── devops/
    ├── docker/Dockerfile            the image CI builds
    └── helm/values.yml              how it runs: port, env, Secrets, probes, resources
```

## A new app from this template

1. Copy this folder into a new repository; rename the package in `src/` and `pyproject.toml`, and the `CMD` of `devops/docker/Dockerfile`.
2. In `devops/helm/values.yml`: its port, env variables, the Secrets it reads, its probes.
3. Copy the CI of agent-toolbox (`.github/workflows/cicd.yml`) and change the image name and the `chart` job's `name` and `image`.
4. Release it and add it to homelab-infra's release train: homelab-infra's DevOps guide, **Add an app**.
