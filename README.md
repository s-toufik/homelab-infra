# homelab-infra

A complete platform for one home server, on Kubernetes: HTTPS and one sign-in in front of every web tool, databases, Kafka, full observability (metrics, logs, traces), local LLMs and the homelab agent, all wired together, watched and backed up. Every piece is a Helm release; one command deploys the whole release train.

**Running it?** Every operation, step by step, with the raw command behind each `make` command: **[devops_guide.md](devops_guide.md)**. The charts are in **[kube-charts](https://github.com/s-toufik/kube-charts)**.

```text
                         ┌─────────────────────── homelab (k3s) ────────────────────────────┐
                         │                                                                  │
  Browser ── HTTPS ──────┼─► GATEWAY ──► homelab-ui · Grafana · Prometheus · Kafka UI · …   │
  (Tailscale)            │   one sign-in   ──► MCP Inspector ────────────┐                  │
                         │                                               ▼                  │
  Tailnet devices ───────┼─► AI       agent-runtime :8000 ─► agent-toolbox :8001            │
                         │           (LLM: NVIDIA's API or local)     (MCP tools)           │
                         │                                                                  │
  Your apps ─────────────┼─► REPOSITORY        PostgreSQL · MongoDB · PostgREST · backups   │
                         ├─► MESSAGE BROKER    Kafka                                        │
                         ├─► AI                LLM server (OpenAI-compatible API)           │
                         └─► OBSERVABILITY     OTel Collector ──► Prometheus · Loki · Tempo │
                         │                                     └──► Grafana                 │
                         └──────────────────────────────────────────────────────────────────┘
```

## What's inside

Each group is a folder and a label of the release train ([`helmfile.yaml.gotmpl`](helmfile.yaml.gotmpl)); each release has its folder, with its `values.yaml.gotmpl` next to its own config files.

| Group | Release | What it gives you |
|---|---|---|
| **platform** | CloudNativePG · Reloader | The PostgreSQL operator; restarts pods when a Secret they use changes |
| **[repository/](repository)** | [PostgreSQL](repository/postgres/README.md) | Relational database for your projects, Tasker's data and the accounts, run by CloudNativePG; [versioned migrations](repository/postgres/MIGRATIONS.md) |
| | [PostgREST](repository/postgrest/README.md) | REST API over the `tasker` schema, each account seeing only its own rows |
| | [MongoDB](repository/mongodb/README.md) | Document database; the agent's conversations |
| | backups | Nightly dumps of PostgreSQL and MongoDB, outside the cluster, kept 14 days |
| **[message_broker/](message_broker)** | [Kafka](message_broker/kafka/README.md) | Event streaming (KRaft, single node) |
| | [Kafka UI](message_broker/kafka-ui/README.md) | Browse topics, messages and consumer groups |
| **[observability/](observability)** | metrics: Prometheus, [kafka-exporter](observability/metrics/kafka-exporter/README.md), [mongodb-exporter](observability/metrics/mongodb-exporter/README.md) | Server, container, Kafka, database and LLM metrics |
| | logs: Loki · traces: Tempo | Log and trace storage |
| | collectors: OTel Collector, Alloy | Receive your apps' OTLP; collect the server's and every container's metrics and every pod's logs |
| | dashboards: Grafana | Dashboards, log search and traces, all linked |
| **[gateway/](gateway)** | [Caddy](gateway/caddy/README.md) | HTTPS with a Tailscale certificate, one entry point for every web tool and API |
| | [Keycloak](gateway/keycloak/README.md) | Accounts and the sign-in page: Argon2id password hashes, 90-day passwords, lockout; managed from the terminal only |
| | oauth2-proxy | Answers Caddy's "is this browser signed in?" for every request |
| **[ai/](ai)** | [LLM (llama-swap)](ai/llm/README.md) · llm-sd | Local models behind an OpenAI-compatible API, plus a playground |
| | agent-runtime · agent-toolbox | The homelab agent and its tools (files, Python sandbox), reachable from the tailnet only; the toolbox is fenced off from the databases |
| | [MCP Inspector](ai/mcp-inspector/README.md) | Lists and tries the toolbox's tools in the browser, behind the sign-in |
| **apps** | homelab-ui | The front door: a **Status** page for every service, links to every tool, the agent chat and Tasker |

## How it ships

```text
app repository (homelab-ui, agent-runtime, agent-toolbox)        GitHub                     server
  devops/docker/Dockerfile ─┐                                                               helmfile apply
  devops/helm/values.yml   ─┴─ git tag v1.4.0 ─► image  toufik142/<app>:1.4.0  ─┐         (the whole train)
                                                 chart  ghcr.io/s-toufik/       ├─► helmfile -l name=<app> apply
                                                        charts/<app>:1.4.0     ─┘         (one release)
kube-charts                   ─────────────────► app · pg-cluster charts ─────────► the services' releases
homelab-infra  environments/versions.yaml        every release's version: the release train, in one file
```

An app's values say how it runs (port, env, the Secrets it reads, probes, volumes); the server adds only what is its own: its Tailscale name and address, and who may connect to what.

## How it connects

```text
SIGN-IN — every browser request

  Browser ─ HTTPS ─► caddy ─ "signed in?" ─► oauth2-proxy ◄─ OIDC ─► keycloak ─► PostgreSQL (db keycloak)
                       │                                                ▲
                       │                          keycloak sync job ────┘  realm, password policy, clients (as code)
                       │
                       ├─ :443   /                 ─► homelab-ui
                       │         /api/tasker/      ─► postgrest ─ row-level security ─► PostgreSQL (schema tasker)
                       │         /api/agent/       ─► agent-runtime
                       │         /api/prometheus/  ─► prometheus  (queries only)
                       │         /api/health/<svc> ─► each service's health endpoint  (Status page)
                       ├─ :8443  ─► keycloak  (sign-in and account pages; /admin blocked)
                       ├─ :3000  ─► grafana   (signs in with Keycloak itself, roles mapped)
                       ├─ :6274  ─► mcp-inspector ─► agent-toolbox
                       └─ :9090 :8080 :12345 :8090 :3100 :3200 :9308
                                 ─► prometheus · kafka-ui · alloy · llm · loki · tempo · kafka-exporter

DATA

  homelab-ui (Tasker) ─► /api/tasker ─► postgrest ─► PostgreSQL     workflows and favorites, per account
  homelab-ui (Agent)  ─► /api/agent  ─► agent-runtime ─┬─ MCP ─► agent-toolbox ─► its working-directory volume
                                                       ├─ OpenAI API ─► NVIDIA's API, or llm
                                                       └─ conversations ─► MongoDB
  db-migrate job (dbmate) ─► PostgreSQL schema       CloudNativePG ─► roles, passwords, the keycloak database
  backups (every night)   ─► /var/backups/homelab on the server: PostgreSQL and MongoDB dumps

AI — tailnet devices, homelab-ui and the MCP Inspector

  tailnet device ─► <tailscale-ip>:8000 ─► agent-runtime
  tailnet device ─► <tailscale-ip>:8001 ─► agent-toolbox /mcp
  ┌─ NetworkPolicy ──────────────────────────────────────────────────────────────┐
  │  agent-toolbox  ◄── agent-runtime · MCP Inspector · Caddy · tailnet devices  │
  │                 ──► DNS · OTel Collector · the internet                      │
  │  MCP Inspector  ◄── Caddy        ──► DNS · agent-toolbox · the internet      │
  └──────────────────────────────────────────────────────────────────────────────┘
  agent-toolbox runs the code the agent writes: it never reaches a database, Kafka, the LLM, the
  home network or the server itself.

TELEMETRY

  your apps, agent-runtime, agent-toolbox ─ OTLP ─► otel-collector ─┬─ traces ─► Tempo ─ span metrics ─► Prometheus
                                                                    ├─ metrics ► Prometheus
                                                                    └─ logs ───► Loki
  Alloy ─┬─ the server's metrics (its /proc, /sys, network) ─► Prometheus
         ├─ every container's metrics (the kubelet's cAdvisor) ─► Prometheus
         └─ every pod's logs ─► Loki
  Prometheus scrapes every pod annotated prometheus.io/scrape (the charts' metrics:) · llm, per loaded model
  Grafana ─► Prometheus · Loki · Tempo   (log line ↔ trace ↔ metrics, linked by trace_id and exemplars)
```

**Signing in** — open any tool, Keycloak asks for your account once, and the session (cookie `__Host-homelab`, 8 hours) opens every other tool. Caddy removes any identity headers a browser sends and sets them itself from oauth2-proxy's answer. Inside the cluster, DNS answers the Tailscale name with Caddy, so pods that check sign-ins use the same address and certificate as browsers.

**Your data stays yours** — Tasker calls `/api/tasker/`; Caddy adds a secret only it knows and the signed-in account name; PostgREST refuses requests without the secret, and PostgreSQL's row-level security returns only that account's workflows and favorites.

**Status at a glance** — homelab-ui's Status page asks `/api/health/<service>` for each web service and Prometheus (`cnpg_collector_up`, `mongodb_up`, `kafka_brokers`) for the rest; `make verify` checks every group from the terminal.

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
| LLM playground and API | `https://<HOMELAB_DOMAIN>:8090/ui` · `/v1` (also with `Authorization: Bearer <key>`, Secret `llm-gateway`) |
| Loki / Tempo APIs | `https://<HOMELAB_DOMAIN>:3100/ready` · `:3200/ready` |
| kafka-exporter | `https://<HOMELAB_DOMAIN>:9308/metrics` |
| MCP Inspector (agent-toolbox's tools) | `https://<HOMELAB_DOMAIN>:6274` |
| Agent API docs (tailnet, no sign-in) | `http://<HOMELAB_DOMAIN>:8000/docs` |

**Connect your apps**

| Service | From pods | From another machine |
|---|---|---|
| PostgreSQL | `postgres-rw:5432` | — (`make psql` on the server) |
| MongoDB | `mongodb://<user>:<password>@mongodb:27017/?authSource=admin` | same with `<HOMELAB_DOMAIN>:27017` |
| Kafka | `kafka:9092` | `<HOMELAB_DOMAIN>:9094` |
| LLM (OpenAI-compatible) | `http://llm:8080/v1` | `https://<HOMELAB_DOMAIN>:8090/v1` + API key |
| OTLP gRPC / HTTP | `otel-collector:4317` / `http://otel-collector:4318` | `<HOMELAB_DOMAIN>:4317` / `:4318` |
| Agent API | `http://agent-runtime:8000` | `http://<HOMELAB_DOMAIN>:8000` |
| Agent tools (MCP, streamable HTTP) | `http://agent-toolbox:8001/mcp` | `http://<HOMELAB_DOMAIN>:8001/mcp` |

Add `OTEL_SERVICE_NAME` and `OTEL_EXPORTER_OTLP_ENDPOINT` to your service and its traces, metrics and logs appear in Grafana; pod logs are collected even without them.

## Security

- **HTTPS everywhere** for the web tools, with a real certificate from Tailscale.
- **One sign-in**: accounts in Keycloak (PostgreSQL), passwords stored as Argon2id hashes with a per-password salt, at least 12 characters, not one of the last 5, expiring after 90 days; 5 wrong attempts lock the account.
- **Terminal-only administration**: accounts are created and changed with `make user-*` on the server; Keycloak's admin console is blocked at the gateway; passwords travel on stdin, never on a command line.
- **Secrets** are Kubernetes Secrets, encrypted on disk by k3s, generated or typed at a hidden prompt by `make secrets`; none is in git or on a command line. Rotating one restarts the pods that use it; PostgreSQL applies new role passwords by itself.
- **Hardened pods**: RuntimeDefault seccomp, no privilege escalation, every Linux capability dropped (Caddy keeps one, to listen on 443), non-root users and read-only file systems wherever the image allows, no Kubernetes API token unless granted.
- **Per-account data** enforced by PostgreSQL row-level security, not only by the UI.
- **Tailnet only**: every published port listens on the server's Tailscale address (`make validate` and `make verify` check it); Kubernetes' own ports are kept off the home network.
- **Agent fenced off**: agent-toolbox and the MCP Inspector, which run code, have NetworkPolicies: no database, Kafka, LLM, home network or server; agent-runtime keeps the internet for its LLM provider.
- **Backups** every night, outside the cluster, root-only.
- `make verify` checks all of the above on the running homelab.

Outside the sign-in, because their clients are programs, not browsers, and reachable from the tailnet's devices only: MongoDB (its own password), Kafka and OTLP (no authentication), agent-runtime (8000) and agent-toolbox (8001). Never forward these ports on your router.

## Repository layout

```text
homelab-infra/
├── helmfile.yaml.gotmpl   the release train: every release, its chart, its order
├── environments/          versions.yaml (every version) · default.yaml (settings) · local.yaml (this server, make local)
├── Makefile               every command (make help)
├── devops_guide.md        how to operate it
├── scripts/               local, secrets, validate, verify, users, dbmate, backups, download_models
├── repository/            postgres (migrations/) · postgrest · mongodb · backups
├── message_broker/        kafka · kafka-ui
├── observability/
│   ├── metrics/           prometheus · kafka-exporter · mongodb-exporter
│   ├── logs/              loki
│   ├── traces/            tempo
│   ├── collectors/        otel-collector · alloy
│   └── dashboards/        grafana (provisioning, dashboard JSON)
├── gateway/               caddy (Caddyfile) · keycloak (sync.sh: realm as code) · oauth2-proxy
├── ai/                    llm (llama-swap config.yml, llm-sd) · agent-runtime · agent-toolbox · mcp-inspector
└── templates/             myapi-a: the template for a new Python API
```

## Resources and retention

Sized for one machine with 16 threads and 32 GiB RAM. Memory limits:

| Release | Memory |
|---|---:|
| LLM (`qwen3-8b` always on + one on-demand model) | 26 GiB |
| PostgreSQL | 4 GiB |
| Prometheus, Loki, Tempo, MongoDB | 3 GiB each |
| Kafka | 2 GiB |
| Keycloak | 1 GiB |
| Kafka UI, Grafana, Alloy | 768 MiB each |
| OTel Collector, agent-runtime, agent-toolbox, backups | 512 MiB each |
| Caddy, MCP Inspector | 256 MiB each |
| homelab-ui, kafka-exporter, PostgREST, oauth2-proxy | 128 MiB each |
| mongodb-exporter, llm-sd, db-migrate | 64 MiB each |

| Data | Kept for |
|---|---|
| Metrics (Prometheus) | 30 days or 50 GB |
| Logs (Loki) | 30 days |
| Traces (Tempo) | 7 days |
| Kafka messages | 7 days, 10 GiB per partition |
| Backups | 14 days |

## The server

The homelab runs on an Ubuntu laptop turned into an always-on server with single-node k3s: it never sleeps (lid closed included), keeps a fixed node address while it fails over from Ethernet to Wi-Fi, keeps Kubernetes' ports off the home network, reboots itself on a freeze or a stuck Tailscale, caps its battery at 80%, reports a heartbeat to an external monitor, and measures the internet speed every 2 hours into Grafana's **Server Health** dashboard.

## Quickstart

On the server, with k3s, Helm, helm-diff, helmfile and Tailscale installed (MagicDNS and HTTPS certificates on):

```bash
make local && make secrets                       # this server's name and address; every Secret
make secret-set SECRET=agent-runtime KEY=llm-api-key
make validate && make apply                      # the whole release train
make user-add ACCOUNT=<name> && make user-admin ACCOUNT=<name>
make verify
```

Then open `https://<HOMELAB_DOMAIN>/status`. Everything else — installing Kubernetes, releasing an app, accounts, secrets, migrations, backups, troubleshooting — is in **[devops_guide.md](devops_guide.md)**.
