# homelab-infra

A ready-to-run platform for a single home server, started with one command. Each service lives in its own folder and plugs into the same network, observability and commands, so the stack grows one service at a time. Today it brings observability (Grafana, Prometheus, Loki, Tempo), Kafka, PostgreSQL, MongoDB, a local LLM server and the homelab agent.

**[Using the stack](#using-the-stack)** — start it, open the tools, connect your apps.
**[Working on the stack](#working-on-the-stack)** — how it is built and how to change it.

```text
                ┌─ SQL ─────────► PostgreSQL
                ├─ documents ───► MongoDB
  Your apps ────┼─ events ──────► Kafka
                ├─ OpenAI API ──► LLM server ◄── Agent ◄── homelab-ui
                └─ OTLP ────────► OTel Collector ──► Grafana

  Your browser ── HTTPS + one sign-in (Caddy, Keycloak) ──► homelab-ui, Grafana, Prometheus, Kafka UI, …
```

---

## Using the stack

### What's inside

The services today — every service added later appears here, in the [Ports](#ports) table and on the homelab page:

| Service | What you use it for |
|---|---|
| **homelab-ui** | The web front door: every service with its status (databases and Kafka included), the agent chat and Tasker |
| **Gateway** (Caddy + Keycloak + oauth2-proxy) | HTTPS and one sign-in for every web tool: accounts in PostgreSQL with Argon2id password hashes, 90-day password expiry, managed from the terminal |
| **Grafana** | Dashboards, log search, trace explorer — the place to look when something is wrong |
| **Prometheus** | Metrics and their raw queries |
| **Loki** / **Tempo** | Logs / traces storage, browsed through Grafana |
| **OTel Collector** | Where your apps send their traces, metrics and logs |
| **Alloy** / **cAdvisor** | Collect host metrics, container metrics and container logs automatically |
| **Kafka** + **Kafka UI** | Event streaming, and a web UI to browse topics and messages |
| **PostgreSQL** / **MongoDB** | Databases for your projects |
| **PostgREST** | A REST API over PostgreSQL's `tasker` schema, where Tasker keeps each account's workflows and favorite blocks (reached only through the gateway) |
| **LLM (llama-swap)** | Local models behind an OpenAI-compatible API, plus a playground |
| **agent-runtime** / **agent-toolbox** | The homelab agent and the tools it can use (files, Python) |

### Start it

Requirements: a Linux machine with Docker Engine and Docker Compose ≥ 2.20, and [Tailscale](https://tailscale.com) on it with **MagicDNS** and **HTTPS certificates** turned on in the Tailscale admin console (the gateway's certificate comes from Tailscale). To prepare an Ubuntu laptop as an always-on server, see [the server guide](Readme_homelab.md).

**The first time**

```bash
make env                        # creates .env from .env.example
make secrets                    # fills every generated secret with a random value
nano .env                       # HOMELAB_DOMAIN=<machine>.<tailnet>.ts.net, then the remaining "changeme"
make validate                   # checks settings and every config file
make up                         # pulls, builds and starts everything
make user-add ACCOUNT=<name>    # your sign-in account (asks email, name and password)
make user-admin ACCOUNT=<name>  # optional: Grafana Admin and the 'admin' role
make verify                     # HTTPS, sign-in everywhere, password policy, per-account data: every line ✓
make health                     # every service, checked from inside Docker: every line ✓
```

The first start pulls all images and downloads the default model (`qwen3-8b`), which takes a while; Keycloak needs about a minute before the sign-in works.

**After that** — `make up` (also after `git pull` or a config change), then `make verify` and `make health`. `make down` stops everything, data kept.

### Open the tools

Every web tool is on `https://<HOMELAB_DOMAIN>:<port>` behind **one sign-in**: the first one you open asks for your account, the others don't (the session lasts 8 hours). Devices need Tailscale to reach `<HOMELAB_DOMAIN>`.

| Tool | URL | Sign-in |
|---|---|---|
| homelab-ui | `https://<HOMELAB_DOMAIN>/` (the old `http://<server>:8002` redirects there) | your account |
| Grafana | `https://<HOMELAB_DOMAIN>:3000` | your account (Keycloak role `admin` → Grafana Admin, others Viewer). Emergency local admin: `/login?disableAutoLogin` with `GRAFANA_ADMIN_*` |
| Prometheus | `https://<HOMELAB_DOMAIN>:9090` | your account |
| Kafka UI | `https://<HOMELAB_DOMAIN>:8080` | your account |
| Alloy pipelines | `https://<HOMELAB_DOMAIN>:12345` | your account |
| LLM playground | `https://<HOMELAB_DOMAIN>:8090/ui` | your account |
| Password change, sign-out of everything | `https://<HOMELAB_DOMAIN>:8443/realms/homelab/account` | your account |

Grafana opens on the **Homelab Overview** dashboard; **Server Health** and **LLM (llama.cpp)** are next to it. Logs, traces and metrics are linked: from a log line you can jump to its trace, and back.

### Connect your apps

Use the first column from a container on the stack's network, the second from anywhere else. A service you add is reached the same way: its compose service name inside Docker, `<server>:<its-port>` from outside.

| Service | Inside Docker | From your machine |
|---|---|---|
| PostgreSQL | `postgres:<postgres-port>` | `<server>:<postgres-port>` |
| MongoDB | `mongodb://<user>:<password>@mongodb:<mongodb-port>/?authSource=admin` | `mongodb://<user>:<password>@<server>:<mongodb-port>/?authSource=admin` |
| Kafka bootstrap | `kafka:<kafka-internal-port>` | `<server>:<kafka-port>` (set `KAFKA_EXTERNAL_HOST` in `.env` to that address) |
| LLM (OpenAI-compatible) | `http://llm:<llm-internal-port>/v1` | `https://<HOMELAB_DOMAIN>:<llm-port>/v1` with `Authorization: Bearer <LLM_GATEWAY_API_KEY>` |
| OTLP (gRPC / HTTP) | `otel-collector:<otlp-grpc-port>` / `http://otel-collector:<otlp-http-port>` | `<server>:<otlp-grpc-port>` / `http://<server>:<otlp-http-port>` |
| Agent API | `http://agent-runtime:<agent-port>` | `http://<server>:<agent-port>` |
| Agent tools (MCP) | `http://agent-toolbox:<toolbox-port>/mcp` | `http://<server>:<toolbox-port>/mcp` |

Kafka and the LLM listen on a different port inside Docker than the one published on the server: both are in the [Ports](#ports) table. PostgREST is not published: Tasker reaches it through the gateway, signed in. Loki and Tempo's query APIs are behind the sign-in too; Grafana reads them inside Docker.

Credentials are the ones you set in `.env`: `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`, `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD`.

The LLM picks the model from the request's `model` field — the list and their sizes are in [`llm/README.md`](llm/README.md):

```bash
curl https://<HOMELAB_DOMAIN>:<llm-port>/v1/chat/completions \
  -H "Authorization: Bearer $LLM_GATEWAY_API_KEY" \
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
| See what is running / is healthy | `make ps` · `make health` · `make stats` · `make verify` (gateway, sign-in and data protection) · `make targets` |
| Manage sign-in accounts | `make users` · `make user-add ACCOUNT=x` · `make user-password ACCOUNT=x` · `make user-admin ACCOUNT=x` · `make user-disable ACCOUNT=x` · `make user-unlock ACCOUNT=x` · `make sessions-revoke` — see [`keycloak/README.md`](keycloak/README.md) |
| Rotate a gateway secret | `./scripts/secrets.sh --rotate <NAME>` then `make up` |
| Follow logs | `make logs S=kafka` (`TAIL=500` for more history) |
| Restart, or apply a config change | `make up` reloads Prometheus and Alloy configs by itself · `make reload-prometheus` · `make recreate S=otel-collector` for the others |
| Start one group only | `make up-obs` · `make up-kafka` · `make up-db` · `make up-gateway` · `make up-apps` · `make up-llm` |
| Open a shell / a database client | `make sh S=kafka` · `make psql` · `make mongosh` |
| Work with Kafka topics | `make topics` · `make topic-create TOPIC=demo` · `make consume TOPIC=demo` · `make groups` |
| Ask a model | `make llm-status` · `make llm-running` · `make llm-ask M=qwen3-8b Q="..."` (through the gateway, with the API key) |
| Back up / restore the databases | `make backup` (PostgreSQL, the `keycloak` accounts and MongoDB) · `make restore-postgres FILE=backups/x.dump [DB=keycloak]` · `make restore-mongo FILE=backups/x.archive` |
| Update images | `make update` |
| Stop (data kept) | `make down` |
| Delete everything, data included | `make clean` (asks for confirmation) |

### Keep it private

Every web tool is behind HTTPS and one sign-in. Still reached directly, without the gateway: PostgreSQL and MongoDB (their own passwords), Kafka and the OTLP ports (no authentication), and agent-runtime (8000) and agent-toolbox (8001), kept as they are until the agents get their own isolated networks. Keep the stack on your LAN or a private network such as Tailscale (`BIND_ADDR` in `.env`), and never expose it to the internet as it is.

---

## Working on the stack

### Architecture

```text
GATEWAY (every browser request)

  Browser ── HTTPS ──► caddy ── "signed in?" ──► oauth2-proxy ◄── sign-in ──► keycloak ──► PostgreSQL (db keycloak)
                         │                                                       ▲
                         │                                    keycloak-sync ─────┘ realm, password policy, clients
                         │
                         ├─ :443  /                ──► homelab-ui
                         │        /api/agent/      ──► agent-runtime
                         │        /api/prometheus/ ──► prometheus
                         │        /api/tasker/     ──► postgrest ── SQL, row-level security ──► PostgreSQL (schema tasker)
                         │        /api/health/…    ──► each tool's health endpoint
                         ├─ :8443                  ──► keycloak (sign-in pages; /admin blocked)
                         ├─ :3000                  ──► grafana (signs in with Keycloak itself)
                         └─ :9090 :8080 :12345 :8090 :3100 :3200 :9308
                                                   ──► prometheus, kafka-ui, alloy, llm, loki, tempo, kafka-exporter

APPLICATIONS

  agent-runtime ── MCP ──► agent-toolbox
        └── conversations ──► MongoDB

TELEMETRY

  agent-runtime ──────┐
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

Every web port is served by the gateway ([`caddy/README.md`](caddy/README.md)) with HTTPS and one sign-in; the services behind it publish no port of their own, and container-to-container traffic (Grafana → Prometheus, Alloy → Loki, …) stays on the Docker network as before. Published directly: PostgreSQL, MongoDB, Kafka, OTLP, and for now agent-runtime and agent-toolbox. The diagram and tables below describe the stack today; [Adding a service](#adding-a-service) lists what to update when it grows.

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
| `scripts/` | `up.sh`, `down.sh`, `logs.sh`, `validate.sh`, `verify.sh`, `secrets.sh`, `users.sh`, `download_models.sh`; shared helpers in `_common.sh` |
| `caddy/`, `keycloak/`, `oauth2-proxy/` | The gateway: HTTPS and routes (`Caddyfile`), accounts and the `homelab` realm applied by `sync.sh` on every start, the sign-in check — see [`caddy/README.md`](caddy/README.md) and [`keycloak/README.md`](keycloak/README.md) |
| `database/` | Versioned SQL migrations (dbmate) and the provisioning script — see [`database/README.md`](database/README.md) |
| `prometheus/`, `loki/`, `tempo/`, `otel-collector/`, `alloy/`, `cadvisor/` | Observability services and their config files |
| `grafana/` | Datasource and dashboard provisioning, dashboard JSON |
| `kafka/`, `kafka-ui/`, `kafka-exporter/` | Streaming |
| `postgres/`, `mongodb/` | Databases |
| `postgres-exporter/`, `mongodb-exporter/` | Database metrics for Prometheus (inside Docker only) |
| `postgrest/` | REST API over PostgreSQL's `tasker` schema, behind the gateway — see [`postgrest/README.md`](postgrest/README.md) |
| `llm/` | llama-swap config (`config.yml`), metrics exporter — see [`llm/README.md`](llm/README.md) |
| `agent-toolbox/`, `agent-runtime/`, `homelab-ui/` | The applications, run from their published images |
| `myapi-a/` | Documentation only: a template for packaging a Python API. Not included, never runs |
| `Readme_homelab.md` | Preparing an Ubuntu laptop as an always-on server |

### Configuration

Every setting is in `.env`; `scripts/validate.sh` refuses to start while a `changeme` is left. `make secrets` generates the random ones (only those still empty or `changeme`).

| Group | Keys |
|---|---|
| Host | `BIND_ADDR` (`0.0.0.0` = LAN, `127.0.0.1` = this machine only, or a Tailscale IP), `HOST_NAME`, `TZ` |
| Gateway | `HOMELAB_DOMAIN` (this machine's Tailscale name); generated: `OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET` (`make sessions-revoke` rotates it), `TASKER_GATEWAY_SECRET`, `GRAFANA_OIDC_CLIENT_SECRET`, `LLM_GATEWAY_API_KEY` — rotate any of them with `./scripts/secrets.sh --rotate <NAME>` then `make up` |
| Image tags | `*_TAG`, one per service — pinned on purpose |
| Credentials | `GRAFANA_ADMIN_*` (emergency local Grafana admin), `POSTGRES_*`, `MONGO_ROOT_*`; generated: `POSTGREST_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_DB_PASSWORD` (`KEYCLOAK_ADMIN_USER` is yours to set) |
| Retention | `PROMETHEUS_RETENTION_TIME`, `PROMETHEUS_RETENTION_SIZE` |
| Kafka | `KAFKA_CLUSTER_ID`, `KAFKA_EXTERNAL_HOST` |
| Apps | `TOOLBOX_EXTRA_ALLOWED_HOSTS`, `LLM_BASE_URL`, `LLM_API_KEY`, `LOG_LEVEL`; for agent-runtime also `WEB_DOCS`, `GUARDRAIL_ENABLED`, `MAX_CONCURRENT_STREAMS`, `AGENT_ANSWER_DELIVERY` |

### Ports

| Service | Published port | Inside Docker | Notes |
|---------|------|------|-------|
"Gateway port" is served by Caddy on `https://<HOMELAB_DOMAIN>:<port>` behind the sign-in; the service itself publishes nothing.

| Service | Gateway port | Published directly | Inside Docker | Notes |
|---------|------|------|------|-------|
| homelab-ui | 443 | — | 8080 | the old `http://<server>:8002` redirects to 443 |
| Keycloak | 8443 | — | 8080 / 9000 | sign-in pages (`/admin` blocked) / health |
| oauth2-proxy | `/oauth2/` on 443 | — | 4180 | the sign-in check Caddy asks |
| Grafana | 3000 | — | 3000 | signs in with Keycloak itself |
| Prometheus | 9090 | — | 9090 | `/-/quit` and `/-/reload` blocked at the gateway |
| Kafka UI | 8080 | — | 8080 | |
| Alloy | 12345 | — | 12345 | |
| LLM (llama-swap) | 8090 | — | 8080 | `/ui` signed in; `/v1` also with `Authorization: Bearer <LLM_GATEWAY_API_KEY>` |
| Loki | 3100 | — | 3100 | API only |
| Tempo | 3200 | — | 3200 | Query API only |
| kafka-exporter | 9308 | — | 9308 | `/metrics` |
| PostgREST | `/api/tasker/` on 443 | — | 3000 | |
| agent-runtime | `/api/agent/` on 443 | 8000 | 8000 | direct port kept until the agents are isolated |
| agent-toolbox | — | 8001 | 8001 | direct port kept until the agents are isolated |
| OTel Collector | — | 4317 / 4318 / 13133 | same | OTLP gRPC / OTLP HTTP / health |
| Kafka | — | 9094 | 9092 | External listener on the server; containers use `kafka:9092` |
| PostgreSQL | — | 5432 | 5432 | |
| MongoDB | — | 27017 | 27017 | |
| postgres-exporter, mongodb-exporter | — | — | 9187, 9216 | `/metrics` |

`make health` checks every HTTP service from inside the Docker network; its list (`HEALTH_INTERNAL` in the `Makefile`) must follow any port change. A new web port also needs a site block in `caddy/Caddyfile` and the port in `caddy/compose.yml`.

### Adding a service

1. Create `<service>/compose.yml` and list it under `include:` in the root `compose.yml`.
2. Pin its image tag in `.env.example` (`<SERVICE>_TAG`) and give it memory and CPU limits.
3. Send its telemetry to `otel-collector` (see [See your app in Grafana](#see-your-app-in-grafana)); if it exposes Prometheus metrics, add a scrape job in `prometheus/prometheus.yml` — `make up` reloads Prometheus, so the job is live after the next deploy.
4. If it has an HTTP endpoint, add it to `HEALTH_INTERNAL` in the `Makefile` and to a service group if it belongs to one. If people open it in a browser, don't publish its port: add a site in `caddy/Caddyfile` (`import signed_in_tool <service>:<port>`) and the port to `caddy/compose.yml`.
5. To show it on the homelab page, add a feature for it in homelab-ui (a link, a page, or a status in its Infrastructure section).
6. Add it to this README: [What's inside](#whats-inside), the architecture diagram if it sends or receives telemetry, [Ports](#ports) and [Resource budget](#resource-budget).

### Resource budget

Memory limits leave about 10 GiB to the OS page cache, which Kafka, PostgreSQL and Loki rely on. CPU limits are caps, not reservations. Sized for 10 physical cores and 32 GiB RAM.

| Service | Memory limit | CPU cap |
|---------|-------------:|--------:|
| LLM (`qwen3-8b` always on + one on-demand model) | 26 GiB | 16 |
| PostgreSQL | 4 GiB | 2 |
| Prometheus, Loki, Tempo, MongoDB | 3 GiB each | 2 |
| Kafka | 2 GiB (1 GiB heap) | 2 |
| Kafka UI, Grafana, Alloy | 768 MiB each | 1 |
| Keycloak | 1 GiB | 2 |
| OTel Collector, agent-runtime, agent-toolbox | 512 MiB each | 1 |
| cAdvisor | 384 MiB | 1 |
| Caddy | 256 MiB | 1 |
| homelab-ui, kafka-exporter, PostgREST, oauth2-proxy | 128 MiB each | 0.5 |
| keycloak-sync (exits once done) | 256 MiB | 0.5 |
| postgres-exporter, mongodb-exporter, db-migrate and db-provision (exit once done) | 64 MiB each | 0.25 |

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

Alloy mounts the Docker socket read-only (needed for log discovery); cAdvisor runs `privileged` with `cgroup: host` (needed for per-container cgroup stats); Caddy mounts the Tailscale socket (needed for its certificate).

The gateway protects every web tool, homelab-ui's APIs and Tasker's data: HTTPS, one sign-in with Keycloak (Argon2id hashes, 90-day passwords, lockout after repeated failures), identity headers set only by Caddy, PostgREST refusing anything without the gateway secret, and row-level security per account. `make verify` checks all of it on the running stack.

Still outside the gateway: Kafka and the OTLP ports have no authentication, and agent-runtime (8000) and agent-toolbox (8001) keep their direct ports. Every container also shares one Docker network, so agent-toolbox's Python sandbox can reach the other services on it from the inside. Keep the stack on a trusted network until the agents get their own isolated networks.

### Upgrading

Image tags are pinned in `.env`. Bump one at a time, run `make validate`, then `make up S=<service>`. Read the release notes of Tempo, Loki and the OTel Collector in particular: their config formats change between minor versions.
