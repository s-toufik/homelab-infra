# homelab-infra

A complete platform for one home server, started with one command: HTTPS and one sign-in in front of every web tool, databases, Kafka, full observability (metrics, logs, traces), local LLMs and the homelab agent, all wired together and watched.

**Running it?** Every operation, step by step, with the raw command behind each `make` command: **[devops_guide.md](devops_guide.md)**.

```text
                         ┌──────────────────────────── homelab ─────────────────────────────┐
                         │                                                                  │
  Browser ── HTTPS ──────┼─► GATEWAY ──► homelab-ui · Grafana · Prometheus · Kafka UI · …   │
  (Tailscale)            │   one sign-in   ──► MCP Inspector ────────────┐                  │
                         │                                               ▼                  │
  Tailnet devices ───────┼─► AGENT    agent-runtime :8000 ─► agent-toolbox :8001            │
                         │           (LLM: NVIDIA's API or local)     (MCP tools)           │
                         │                                                                  │
  Your apps ─────────────┼─► REPOSITORY        PostgreSQL · MongoDB · PostgREST             │
                         ├─► MESSAGE BROKER    Kafka                                        │
                         ├─► AI                LLM server (OpenAI-compatible API)           │
                         └─► OBSERVABILITY     OTel Collector ──► Prometheus · Loki · Tempo │
                         │                                     └──► Grafana                 │
                         └──────────────────────────────────────────────────────────────────┘
```

## What's inside

Each group is a folder; each service has its own folder and `compose.yml`, all included by the root [`compose.yml`](compose.yml).

| Group | Service | What it gives you |
|---|---|---|
| **[gateway/](gateway)** | [Caddy](gateway/caddy/README.md) | HTTPS with a Tailscale certificate, one entry point for every web tool and API |
| | [Keycloak](gateway/keycloak/README.md) | Accounts and the sign-in page: Argon2id password hashes, 90-day passwords, lockout; managed from the terminal only |
| | oauth2-proxy | Answers Caddy's "is this browser signed in?" for every request |
| **[repository/](repository)** | [PostgreSQL](repository/postgres/README.md) | Relational database for your projects, Tasker's data and the accounts; [versioned migrations](repository/postgres/MIGRATIONS.md) |
| | [PostgREST](repository/postgrest/README.md) | REST API over the `tasker` schema, each account seeing only its own rows |
| | [MongoDB](repository/mongodb/README.md) | Document database; the agent's conversations |
| **[message_broker/](message_broker)** | [Kafka](message_broker/kafka/README.md) | Event streaming (KRaft, single broker) |
| | [Kafka UI](message_broker/kafka-ui/README.md) | Browse topics, messages and consumer groups |
| **[observability/](observability)** | metrics: Prometheus, [cAdvisor](observability/metrics/cadvisor/README.md), [kafka-exporter](observability/metrics/kafka-exporter/README.md), [postgres-exporter](observability/metrics/postgres-exporter/README.md), [mongodb-exporter](observability/metrics/mongodb-exporter/README.md) | Host, container, Kafka, database and LLM metrics |
| | logs: Loki · traces: Tempo | Log and trace storage |
| | collectors: OTel Collector, Alloy | Receive your apps' OTLP; collect host metrics and every container's logs |
| | dashboards: Grafana | Dashboards, log search and traces, all linked |
| **[ai/](ai)** | [LLM (llama-swap)](ai/llm/README.md) | Local models behind an OpenAI-compatible API, plus a playground |
| | agent-runtime · agent-toolbox | The homelab agent and its tools (files, Python sandbox), reachable from the tailnet only; the toolbox is kept away from the databases |
| | [MCP Inspector](ai/mcp-inspector/README.md) | Lists and tries the toolbox's tools in the browser, behind the sign-in |
| **[apps/](apps)** | homelab-ui | The front door: a **Status** page for every container, links to every tool, the agent chat and Tasker |

## How it connects

```text
SIGN-IN — every browser request

  Browser ─ HTTPS ─► caddy ─ "signed in?" ─► oauth2-proxy ◄─ OIDC ─► keycloak ─► PostgreSQL (db keycloak)
                       │                                                ▲
                       │                             keycloak-sync ─────┘  realm, password policy, clients (as code)
                       │
                       ├─ :443   /                 ─► homelab-ui
                       │         /api/tasker/      ─► postgrest ─ row-level security ─► PostgreSQL (schema tasker)
                       │         /api/agent/       ─► agent-runtime
                       │         /api/prometheus/  ─► prometheus  (queries only)
                       │         /api/health/<svc> ─► each container's health endpoint  (Status page)
                       ├─ :8443  ─► keycloak  (sign-in and account pages; /admin blocked)
                       ├─ :3000  ─► grafana   (signs in with Keycloak itself, roles mapped)
                       ├─ :6274  ─► mcp-inspector ─► agent-toolbox
                       └─ :9090 :8080 :12345 :8090 :3100 :3200 :9308
                                 ─► prometheus · kafka-ui · alloy · llm · loki · tempo · kafka-exporter

DATA

  homelab-ui (Tasker) ─► /api/tasker ─► postgrest ─► PostgreSQL     workflows and favorites, per account
  homelab-ui (Agent)  ─► /api/agent  ─► agent-runtime ─┬─ MCP ─► agent-toolbox ─► working-directory volume
                                                       ├─ OpenAI API ─► LLM_BASE_URL (NVIDIA's API, or llm)
                                                       └─ conversations ─► MongoDB
  db-migrate (dbmate) ─► PostgreSQL schema, at every start · db-provision ─► role passwords

AGENT — tailnet devices, homelab-ui and the MCP Inspector

  tailnet device ─► <tailscale-ip>:8000 ─► agent-runtime        (BIND_ADDR = the Tailscale address)
  tailnet device ─► <tailscale-ip>:8001 ─► agent-toolbox /mcp
  ┌─ network `agents` ──────────────────────────────────────────────────────┐
  │  agent-toolbox   mcp-inspector         (on this network only)           │
  │  agent-runtime   otel-collector  caddy (also on `default`)              │
  └─────────────────────────────────────────────────────────────────────────┘
  agent-toolbox runs the code the agent writes: it reaches agent-runtime, its telemetry, the gateway
  and the internet, never a database, Kafka or the LLM.

TELEMETRY

  your apps, agent-runtime, agent-toolbox ─ OTLP ─► otel-collector ─┬─ traces ─► Tempo ─ span metrics ─► Prometheus
                                                                    ├─ metrics ► Prometheus
                                                                    └─ logs ───► Loki
  Alloy ─┬─ host metrics ─► Prometheus          Prometheus scrapes ─► cAdvisor · kafka-exporter · postgres-exporter
         └─ docker logs ──► Loki                                     · mongodb-exporter · llm (per model)
  Grafana ─► Prometheus · Loki · Tempo   (log line ↔ trace ↔ metrics, linked by trace_id and exemplars)
```

**Signing in** — open any tool, Keycloak asks for your account once, and the session (cookie `__Host-homelab`, 8 hours) opens every other tool. Caddy removes any identity headers a browser sends and sets them itself from oauth2-proxy's answer.

**Your data stays yours** — Tasker calls `/api/tasker/`; Caddy adds a secret only it knows and the signed-in account name; PostgREST refuses requests without the secret, and PostgreSQL's row-level security returns only that account's workflows and favorites.

**Status at a glance** — homelab-ui's Status page asks `/api/health/<service>` for each web service and Prometheus (`pg_up`, `mongodb_up`, `kafka_brokers`) for the rest; `make health` checks the same endpoints from the terminal.

## Access

Every web tool is on `https://<HOMELAB_DOMAIN>:<port>` behind one sign-in (`HOMELAB_DOMAIN` is the server's Tailscale name, `<machine>.<tailnet>.ts.net`). Devices need Tailscale.

| Open | URL |
|---|---|
| homelab-ui (Status, Agent, Tasker) | `https://<HOMELAB_DOMAIN>/` · `/status` |
| Your account (password, sessions) | `https://<HOMELAB_DOMAIN>:8443/realms/homelab/account` |
| Grafana | `https://<HOMELAB_DOMAIN>:3000` · `/dashboards` · `/explore` |
| Prometheus | `https://<HOMELAB_DOMAIN>:9090` · `/query` · `/targets` |
| Kafka UI | `https://<HOMELAB_DOMAIN>:8080` |
| Alloy pipelines | `https://<HOMELAB_DOMAIN>:12345` · `/graph` |
| LLM playground and API | `https://<HOMELAB_DOMAIN>:8090/ui` · `/v1` (also with `Authorization: Bearer <LLM_GATEWAY_API_KEY>`) |
| Loki / Tempo APIs | `https://<HOMELAB_DOMAIN>:3100/ready` · `:3200/ready` |
| kafka-exporter | `https://<HOMELAB_DOMAIN>:9308/metrics` |
| MCP Inspector (agent-toolbox's tools) | `https://<HOMELAB_DOMAIN>:6274` |
| Agent API docs (tailnet, no sign-in) | `http://<HOMELAB_DOMAIN>:8000/docs` |

**Connect your apps**

| Service | Inside Docker | From another machine |
|---|---|---|
| PostgreSQL | `postgres:5432` | `<HOMELAB_DOMAIN>:5432` |
| MongoDB | `mongodb://<user>:<password>@mongodb:27017/?authSource=admin` | same with `<HOMELAB_DOMAIN>:27017` |
| Kafka | `kafka:9092` | `<HOMELAB_DOMAIN>:9094` |
| LLM (OpenAI-compatible) | `http://llm:8080/v1` | `https://<HOMELAB_DOMAIN>:8090/v1` + API key |
| OTLP gRPC / HTTP | `otel-collector:4317` / `http://otel-collector:4318` | `<HOMELAB_DOMAIN>:4317` / `:4318` |
| Agent API | `http://agent-runtime:8000` | `http://<HOMELAB_DOMAIN>:8000` |
| Agent tools (MCP, streamable HTTP) | `http://agent-toolbox:8001/mcp` | `http://<HOMELAB_DOMAIN>:8001/mcp` |

Add `OTEL_SERVICE_NAME` and `OTEL_EXPORTER_OTLP_ENDPOINT` to your service and its traces, metrics and logs appear in Grafana; container logs are collected even without them.

## Security

- **HTTPS everywhere** for the web tools, with a real certificate from Tailscale.
- **One sign-in**: accounts in Keycloak (PostgreSQL), passwords stored as Argon2id hashes with a per-password salt, at least 12 characters, not one of the last 5, expiring after 90 days; 5 wrong attempts lock the account.
- **Terminal-only administration**: accounts are created and changed with `make user-*` on the server; Keycloak's admin console is blocked at the gateway; passwords travel on stdin, never on a command line.
- **Secrets** are generated into `.env` (git-ignored, mode 600) by `make secrets`; none is in git.
- **Per-account data** enforced by PostgreSQL row-level security, not only by the UI.
- **Tailnet only**: every published port listens on the server's Tailscale address (`BIND_ADDR`, checked by `make validate`), so nothing is reachable from the LAN or the internet.
- **Agent kept apart**: agent-toolbox and the MCP Inspector, which run code, sit on their own network with no database, Kafka or LLM; agent-runtime keeps the internet for its LLM provider.
- `make verify` checks all of the above on the running stack.

Outside the sign-in, because their clients are programs, not browsers, and reachable from the tailnet's devices only: PostgreSQL and MongoDB (their own passwords), Kafka and OTLP (no authentication), agent-runtime (8000) and agent-toolbox (8001). Never forward these ports on your router.

## Repository layout

```text
homelab-infra/
├── compose.yml            includes every service below
├── .env.example           every setting, commented (make env → .env)
├── Makefile               every command (make help)
├── devops_guide.md        how to operate it
├── scripts/               up, down, validate, verify, secrets, users, db-passwords, download_models
├── gateway/               caddy (Caddyfile) · keycloak (sync.sh: realm as code) · oauth2-proxy
├── repository/            postgres (migrations/, provision.sh) · postgrest · mongodb
├── message_broker/        kafka · kafka-ui
├── observability/
│   ├── metrics/           prometheus · cadvisor · kafka-exporter · postgres-exporter · mongodb-exporter
│   ├── logs/              loki
│   ├── traces/            tempo
│   ├── collectors/        otel-collector · alloy
│   └── dashboards/        grafana (provisioning, dashboard JSON)
├── ai/                    llm (llama-swap config.yml) · agent-runtime · agent-toolbox · mcp-inspector
├── apps/                  homelab-ui
└── templates/             myapi-a: how to package a Python API (documentation, never runs)
```

## Resources and retention

Sized for one machine with 10 physical cores and 32 GiB RAM; the limits leave about 10 GiB to the OS page cache.

| Service | Memory | CPU |
|---|---:|---:|
| LLM (`qwen3-8b` always on + one on-demand model) | 26 GiB | 16 |
| PostgreSQL | 4 GiB | 2 |
| Prometheus, Loki, Tempo, MongoDB | 3 GiB each | 2 |
| Kafka | 2 GiB | 2 |
| Keycloak | 1 GiB | 2 |
| Kafka UI, Grafana, Alloy | 768 MiB each | 1 |
| OTel Collector, agent-runtime, agent-toolbox | 512 MiB each | 1 |
| cAdvisor | 384 MiB | 1 |
| Caddy, keycloak-sync, MCP Inspector | 256 MiB each | 1 / 0.5 / 0.5 |
| homelab-ui, kafka-exporter, PostgREST, oauth2-proxy | 128 MiB each | 0.5 |
| exporters, db-migrate, db-provision, llm-sd-exporter | 64 MiB each | 0.25 |

| Data | Kept for |
|---|---|
| Metrics (Prometheus) | 30 days or 50 GB |
| Logs (Loki) | 30 days |
| Traces (Tempo) | 7 days |
| Kafka messages | 7 days, 10 GiB per partition |

## The server

The stack runs on an Ubuntu laptop turned into an always-on server: it never sleeps (lid closed included), boots with only Tailscale running, prefers Ethernet with Wi-Fi as fallback, reboots itself on a freeze or a stuck Tailscale, caps its battery at 80%, reports a heartbeat to an external monitor, and measures the internet speed every 2 hours into Grafana's **Server Health** dashboard.

## Quickstart

On a Linux server with Docker Compose ≥ 2.20 and Tailscale (MagicDNS and HTTPS certificates on):

```bash
make env && make secrets        # .env with every secret generated
nano .env                       # HOMELAB_DOMAIN, BIND_ADDR, LLM_BASE_URL
make validate && make up
make user-add ACCOUNT=<name> && make user-admin ACCOUNT=<name>
make verify && make health
```

Then open `https://<HOMELAB_DOMAIN>/status`. Everything else — accounts, passwords, migrations, backups, publishing homelab-ui, preparing the server, troubleshooting — is in **[devops_guide.md](devops_guide.md)**.
