# homelab-infra

A ready-to-run platform for a single home server: observability (Grafana, Prometheus, Loki, Tempo), Kafka, PostgreSQL, MongoDB, a local LLM server and the homelab agent — all started with one command.

**[Using the stack](#using-the-stack)** — start it, open the tools, connect your apps.
**[Working on the stack](#working-on-the-stack)** — how it is built and how to change it.

```text
                ┌─ SQL ─────────► PostgreSQL
                ├─ documents ───► MongoDB
  Your apps ────┼─ events ──────► Kafka
                ├─ OpenAI API ──► LLM server ◄── Agent ◄── homelab-ui
                └─ OTLP ────────► OTel Collector ──► Grafana
```

---

## Using the stack

### What's inside

| Service | What you use it for |
|---|---|
| **homelab-ui** | The web front door: every service with its status (databases and Kafka included), and the agent chat |
| **Grafana** | Dashboards, log search, trace explorer — the place to look when something is wrong |
| **Prometheus** | Metrics and their raw queries |
| **Loki** / **Tempo** | Logs / traces storage, browsed through Grafana |
| **OTel Collector** | Where your apps send their traces, metrics and logs |
| **Alloy** / **cAdvisor** | Collect host metrics, container metrics and container logs automatically |
| **Kafka** + **Kafka UI** | Event streaming, and a web UI to browse topics and messages |
| **PostgreSQL** / **MongoDB** | Databases for your projects |
| **LLM (llama-swap)** | Local models behind an OpenAI-compatible API, plus a playground |
| **agent-orchestrator** / **agent-toolbox** | The homelab agent and the tools it can use (files, Python) |

### Start it

Requirements: a Linux machine with Docker Engine and Docker Compose ≥ 2.20. To prepare an Ubuntu laptop as an always-on server, see [the server guide](Readme_homelab.md).

```bash
make env          # creates .env from .env.example
nano .env         # replace every "changeme" (passwords, users)
make validate     # checks settings and every config file
make up           # builds and starts everything
make health       # every main endpoint should show ✓
```

The first start pulls all images and downloads the default model (`qwen3-8b`), which takes a while.

### Open the tools

Replace `<server>` with your machine's address (its name, LAN IP or Tailscale IP), and each `<…-port>` with the port listed under [Ports](#ports).

| Tool | URL | Login |
|---|---|---|
| homelab-ui | `http://<server>:<ui-port>` | — |
| Grafana | `http://<server>:<grafana-port>` | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env` |
| Prometheus | `http://<server>:<prometheus-port>` | — |
| Kafka UI | `http://<server>:<kafka-ui-port>` | `KAFKA_UI_USER` / `KAFKA_UI_PASSWORD` |
| Alloy pipelines | `http://<server>:<alloy-port>` | — |
| LLM playground | `http://<server>:<llm-port>/ui` | — |

Grafana opens on the **Homelab Overview** dashboard; **Server Health** and **LLM (llama.cpp)** are next to it. Logs, traces and metrics are linked: from a log line you can jump to its trace, and back.

### Connect your apps

Use the first column from a container on the stack's network, the second from anywhere else.

| Service | Inside Docker | From your machine |
|---|---|---|
| PostgreSQL | `postgres:<postgres-port>` | `<server>:<postgres-port>` |
| MongoDB | `mongodb://<user>:<password>@mongodb:<mongodb-port>/?authSource=admin` | `mongodb://<user>:<password>@<server>:<mongodb-port>/?authSource=admin` |
| Kafka bootstrap | `kafka:<kafka-internal-port>` | `<server>:<kafka-port>` (set `KAFKA_EXTERNAL_HOST` in `.env` to that address) |
| LLM (OpenAI-compatible) | `http://llm:<llm-internal-port>/v1` | `http://<server>:<llm-port>/v1` |
| OTLP (gRPC / HTTP) | `otel-collector:<otlp-grpc-port>` / `http://otel-collector:<otlp-http-port>` | `<server>:<otlp-grpc-port>` / `http://<server>:<otlp-http-port>` |
| Agent API | `http://agent-orchestrator:<agent-port>` | `http://<server>:<agent-port>` |
| Agent tools (MCP) | `http://agent-toolbox:<toolbox-port>/mcp` | `http://<server>:<toolbox-port>/mcp` |

Kafka and the LLM listen on a different port inside Docker than the one published on the server: both are in the [Ports](#ports) table.

Credentials are the ones you set in `.env`: `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`, `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD`.

The LLM picks the model from the request's `model` field — the list and their sizes are in [`llm/README.md`](llm/README.md):

```bash
curl http://<server>:<llm-port>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "qwen3-8b", "messages": [{"role": "user", "content": "Hello"}]}'
```

### See your app in Grafana

Add this to your service and its traces, metrics and logs show up in Grafana:

```yaml
environment:
  OTEL_SERVICE_NAME: my-service
  OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:<otlp-http-port>
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
labels:
  homelab.logs.otlp: "true"   # only if it ships its logs via OTLP (avoids duplicates)
```

Container logs are collected automatically even without it.

### Day-to-day commands

Run `make` to list every command. The ones you'll use most:

| To… | Run |
|---|---|
| See what is running / is healthy | `make ps` · `make health` · `make stats` |
| Follow logs | `make logs S=kafka` (`TAIL=500` for more history) |
| Restart, or apply a config change | `make restart S="grafana tempo"` · `make recreate S=otel-collector` |
| Start one group only | `make up-obs` · `make up-kafka` · `make up-db` · `make up-apps` · `make up-llm` |
| Open a shell / a database client | `make sh S=kafka` · `make psql` · `make mongosh` |
| Work with Kafka topics | `make topics` · `make topic-create TOPIC=demo` · `make consume TOPIC=demo` · `make groups` |
| Ask a model | `make llm-status` · `make llm-ask M=qwen3-8b Q="..."` |
| Back up / restore the databases | `make backup` · `make restore-postgres FILE=backups/x.dump` · `make restore-mongo FILE=backups/x.archive` |
| Update images | `make update` |
| Stop (data kept) | `make down` |
| Delete everything, data included | `make clean` (asks for confirmation) |

### Keep it private

Kafka, Loki, Tempo and Prometheus have no login. Keep the stack on your LAN or a private network such as Tailscale (`BIND_ADDR` in `.env`), and put a reverse proxy with TLS and authentication in front before exposing anything to the internet.

---

## Working on the stack

### Architecture

```text
APPLICATIONS

  homelab-ui ── HTTP, SSE ──► agent-orchestrator ── MCP ──► agent-toolbox
                                      │
                                      └── conversations ──► MongoDB

TELEMETRY

  agent-orchestrator ─┐
                      ├─ OTLP ─► otel-collector ─┬─ traces ──► Tempo ── span metrics ──► Prometheus
  agent-toolbox ──────┘                          ├─ metrics ─► Prometheus
                                                 └─ logs ────► Loki

  Alloy ─┬─ host metrics ──► Prometheus
         └─ docker logs ───► Loki

SCRAPED BY PROMETHEUS

  Prometheus ─┬─► cAdvisor ─────────────────────── container metrics
              ├─► kafka-exporter ────► Kafka ◄── kafka-ui
              ├─► postgres-exporter ─► PostgreSQL
              ├─► mongodb-exporter ──► MongoDB
              └─► llm (llama-swap) ─── per-model metrics

GRAFANA

  Grafana ──► Prometheus · Loki · Tempo   (logs ↔ traces ↔ metrics, linked)
```

There is no reverse proxy: every service publishes its own port on `BIND_ADDR`, and homelab-ui links to each one directly.

| Signal | Path |
|--------|------|
| App traces / metrics / logs | app → `otel-collector` (OTLP) → Tempo / Prometheus / Loki |
| Host metrics (CPU, RAM, disk, net) | Alloy `prometheus.exporter.unix` → Prometheus remote-write |
| Container metrics | standalone `cadvisor` → Prometheus scrape (see [`cadvisor/README.md`](cadvisor/README.md) for why it isn't Alloy's embedded exporter) |
| Container stdout logs | Alloy `loki.source.docker` → Loki (apps labelled `homelab.logs.otlp=true` are skipped) |
| Kafka lag / throughput | `kafka-exporter` ← Prometheus scrape |
| Database health | `postgres-exporter` (`pg_up`) and `mongodb-exporter` (`mongodb_up`) ← Prometheus scrape; homelab-ui reads them, with `kafka_brokers`, for its Infrastructure status |
| Service graph, RED metrics | Tempo metrics-generator → Prometheus |
| LLM metrics | Prometheus scrapes `llm:8080/upstream/<model>/metrics` per model |

Grafana is provisioned (`grafana/provisioning/`) with the three datasources cross-linked (logs ↔ traces ↔ metrics via `trace_id` and exemplars) and the dashboards in `grafana/dashboards/`.

### Repository layout

| Path | What it holds |
|---|---|
| `compose.yml` | The root stack: `include:`s every service's own compose file |
| `.env.example` | Every setting, with comments |
| `Makefile` | All commands (`make help`); service groups are defined at the top |
| `scripts/` | `up.sh`, `down.sh`, `logs.sh`, `validate.sh`, `download_models.sh`; shared helpers in `_common.sh` |
| `prometheus/`, `loki/`, `tempo/`, `otel-collector/`, `alloy/`, `cadvisor/` | Observability services and their config files |
| `grafana/` | Datasource and dashboard provisioning, dashboard JSON |
| `kafka/`, `kafka-ui/`, `kafka-exporter/` | Streaming |
| `postgres/`, `mongodb/` | Databases |
| `postgres-exporter/`, `mongodb-exporter/` | Database metrics for Prometheus (inside Docker only) |
| `llm/` | llama-swap config (`config.yml`), metrics exporter — see [`llm/README.md`](llm/README.md) |
| `agent-toolbox/`, `agent-orchestrator/`, `homelab-ui/` | The applications, run from their published images |
| `myapi-a/` | Documentation only: a template for packaging a Python API. Not included, never runs |
| `Readme_homelab.md` | Preparing an Ubuntu laptop as an always-on server |

### Configuration

Every setting is in `.env`; `scripts/validate.sh` refuses to start while a `changeme` is left.

| Group | Keys |
|---|---|
| Host | `BIND_ADDR` (`0.0.0.0` = LAN, `127.0.0.1` = this machine only, or a Tailscale IP), `HOST_NAME`, `TZ` |
| Image tags | `*_TAG`, one per service — pinned on purpose |
| Credentials | `GRAFANA_ADMIN_*`, `KAFKA_UI_*`, `POSTGRES_*`, `MONGO_ROOT_*` |
| Retention | `PROMETHEUS_RETENTION_TIME`, `PROMETHEUS_RETENTION_SIZE` |
| Kafka | `KAFKA_CLUSTER_ID`, `KAFKA_EXTERNAL_HOST` |
| Apps | `TOOLBOX_EXTRA_ALLOWED_HOSTS`, `LLM_BASE_URL`, `LLM_API_KEY`, `LOG_LEVEL` |

### Ports

| Service | Published port | Inside Docker | Notes |
|---------|------|------|-------|
| homelab-ui | 8002 | 8080 | |
| agent-orchestrator | 8000 | 8000 | `POST /v1/stream` (SSE), `/actuator/health` |
| agent-toolbox | 8001 | 8001 | `/mcp`, `/actuator/health` |
| LLM (llama-swap) | 8090 | 8080 | `/v1`, `/ui`, `/health` |
| Grafana | 3000 | 3000 | |
| Prometheus | 9090 | 9090 | `/api/v1/query` is open to browsers (homelab-ui uses it) |
| Alloy | 12345 | 12345 | |
| Kafka UI | 8080 | 8080 | |
| Loki | 3100 | 3100 | API only |
| Tempo | 3200 | 3200 | Query API only |
| OTel Collector | 4317 / 4318 / 13133 | same | OTLP gRPC / OTLP HTTP / health |
| Kafka | 9094 | 9092 | External listener on the server; containers use `kafka:9092` |
| kafka-exporter | 9308 | 9308 | `/metrics` |
| postgres-exporter | — | 9187 | `/metrics`, not published |
| mongodb-exporter | — | 9216 | `/metrics`, not published |
| PostgreSQL | 5432 | 5432 | |
| MongoDB | 27017 | 27017 | |

`make health` checks the HTTP ones; its list (`HEALTH_URLS` in the `Makefile`) must follow any port change.

### Adding a service

1. Create `<service>/compose.yml` and list it under `include:` in the root `compose.yml`.
2. Pin its image tag in `.env.example` (`<SERVICE>_TAG`) and give it memory and CPU limits.
3. Send its telemetry to `otel-collector` (see [See your app in Grafana](#see-your-app-in-grafana)); if it exposes Prometheus metrics, add a scrape job in `prometheus/prometheus.yml`.
4. If it has an HTTP endpoint, add it to `HEALTH_URLS` in the `Makefile` and to a service group if it belongs to one.
5. To show it on the homelab page, add a feature for it in homelab-ui.

### Resource budget

Memory limits leave about 10 GiB to the OS page cache, which Kafka, PostgreSQL and Loki rely on. CPU limits are caps, not reservations. Sized for 10 physical cores and 32 GiB RAM.

| Service | Memory limit | CPU cap |
|---------|-------------:|--------:|
| LLM (`qwen3-8b` always on + one on-demand model) | 26 GiB | 16 |
| PostgreSQL | 4 GiB | 2 |
| Prometheus, Loki, Tempo, MongoDB | 3 GiB each | 2 |
| Kafka | 2 GiB (1 GiB heap) | 2 |
| Kafka UI, Grafana, Alloy | 768 MiB each | 1 |
| OTel Collector, agent-orchestrator, agent-toolbox | 512 MiB each | 1 |
| cAdvisor | 384 MiB | 1 |
| homelab-ui, kafka-exporter | 128 MiB each | 0.5 |
| postgres-exporter, mongodb-exporter | 64 MiB each | 0.25 |

The LLM ceiling is deliberately generous: the on-demand group in [`llm/config.yml`](llm/config.yml) keeps only **one** of its models loaded at a time (`swap: true`). Real peak usage is `qwen3-8b` (~5 GiB) plus the active on-demand model (up to ~19 GiB) plus the rest of the stack. On OOM kills, lower that model's `--ctx-size` before touching another service's limit.

### Retention

| Store | Retention | Where to change |
|-------|-----------|-----------------|
| Prometheus | 30 d or 50 GB | `.env` `PROMETHEUS_RETENTION_*` |
| Loki | 30 d | `loki/config.yml` `retention_period` |
| Tempo | 7 d | `tempo/config.yml` `block_retention` |
| Kafka | 7 d, 10 GiB per partition | `kafka/compose.yml` |

Data lives in named Docker volumes (`make volumes`).

### Agent working directory

`agent-toolbox` keeps the files its tools read and write in the volume `homelab_agent-working-directory`, mounted at `/data/working_directory`. Its file tools and Python sandbox are confined to it; the agent reaches these files only through the toolbox's tools.

### Security notes

Alloy mounts the Docker socket read-only (needed for log discovery); cAdvisor runs `privileged` with `cgroup: host` (needed for per-container cgroup stats). Kafka, Loki, Tempo and Prometheus have no authentication: put a reverse proxy with TLS and authentication (Traefik, Caddy) in front before exposing them beyond a trusted network.

### Upgrading

Image tags are pinned in `.env`. Bump one at a time, run `make validate`, then `make up S=<service>`. Read the release notes of Tempo, Loki and the OTel Collector in particular: their config formats change between minor versions.
