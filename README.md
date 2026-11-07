# homelab-infra

A complete platform for one home server, on Kubernetes: HTTPS and one sign-in in front of every web tool, databases, Kafka, full observability (metrics, logs, traces), local LLMs and the homelab agent, all wired together, watched and backed up. Every piece is a Helm release; one command deploys the whole release train.

**Running it?** Every operation, step by step, with the raw command behind each `make` command: **[devops_guide.md](devops_guide.md)**. Quick answers (passwords, logs, stop and restart, dev images, scaling): **[Q&A.md](Q&A.md)**. The charts are in **[kube-charts](https://github.com/s-toufik/kube-charts)**.

```text
                         ┌─────────────────────── homelab (k3s) ────────────────────────────┐
                         │                                                                  │
  Browser ── HTTPS ──────┼─► GATEWAY ──► homelab-ui · Grafana · Prometheus · Kafka UI · …   │
  (Tailscale)            │   one sign-in   ──► MCP Inspector ────────────┐                  │
                         │                                               ▼                  │
  Tailnet devices ───────┼─► APPS     agent-runtime :8000 ─► agent-toolbox :8001            │
                         │           (LLM: NVIDIA's API or local)     (MCP tools)           │
                         │                                                                  │
  Your apps ─────────────┼─► REPOSITORY        PostgreSQL · MongoDB · PostgREST · backups   │
                         ├─► MESSAGE BROKER    Kafka                                        │
                         ├─► LLM               LLM server (OpenAI-compatible API)           │
                         └─► OBSERVABILITY     OTel Collector ──► Prometheus · Loki · Tempo │
                         │                                     └──► Grafana                 │
                         └──────────────────────────────────────────────────────────────────┘
```

## What's inside

Each group is a folder and a label of the release train ([`helmfile.yaml.gotmpl`](helmfile.yaml.gotmpl)); each release is the folder `<group>/<release>/`, with its `values.yaml.gotmpl` next to the config files it reads.

| Group | Release | What it gives you |
|---|---|---|
| **platform** | CloudNativePG · Reloader | The PostgreSQL operator; restarts pods when a Secret they use changes |
| **[repository/](repository)** | [PostgreSQL](repository/postgres/README.md) | Relational database for your projects, Tasker's data and the accounts, run by CloudNativePG |
| | [PostgREST](repository/postgrest/README.md) | REST API over the `tasker` schema, each account seeing only its own rows |
| | [MongoDB](repository/mongodb/README.md) | Document database; the agent's conversations |
| | [db-migrate](repository/db-migrate/README.md) | Applies the versioned SQL migrations of Tasker's schema (a job, no pod stays) |
| | backups | Nightly dumps of PostgreSQL and MongoDB, outside the cluster, kept 14 days |
| **[message-broker/](message-broker)** | [Kafka](message-broker/kafka/README.md) | Event streaming (KRaft, single node) |
| | [Kafka UI](message-broker/kafka-ui/README.md) | Browse topics, messages and consumer groups |
| **[observability/](observability)** | Prometheus · Loki · Tempo | Metrics, log and trace storage |
| | OTel Collector · Alloy | Receive your apps' OTLP; collect the server's and every container's metrics and every pod's logs |
| | [kafka-exporter](observability/kafka-exporter/README.md) · [mongodb-exporter](observability/mongodb-exporter/README.md) | Kafka and MongoDB metrics |
| | Grafana | Dashboards, log search and traces, all linked |
| **[gateway/](gateway)** | [Caddy](gateway/caddy/README.md) | HTTPS with a Tailscale certificate, one entry point for every web tool and API |
| | [Keycloak](gateway/keycloak/README.md) | Accounts and the sign-in page: Argon2id password hashes, 90-day passwords, lockout; managed from the terminal only |
| | oauth2-proxy | Answers Caddy's "is this browser signed in?" for every request |
| | kube-api | `kubectl proxy` with cluster-admin rights, reachable from Caddy and Headlamp only: homelab-ui's Kubernetes page, for accounts with the `admin` role |
| | Headlamp | The Kubernetes dashboard on `:4466`, admins only, through kube-api (no token of its own) |
| **[llm/](llm)** | [LLM (llama-swap)](llm/llm/README.md) · llm-sd | Local models behind an OpenAI-compatible API, plus a playground; llm-sd tells Prometheus which models are loaded |
| | [MCP Inspector](llm/mcp-inspector/README.md) | Lists and tries the toolbox's tools in the browser, behind the sign-in |
| | grafana-mcp · mongodb-mcp · postgres-mcp | Grafana's, MongoDB's and PostgreSQL's MCP servers: agent-toolbox republishes their tools (`grafana_*`, `mongodb_*`, `postgres_*`), read-only unless `mcp.<server>.write` in `environments/default.yaml` says otherwise |
| **[apps/](apps)** — yours, each from its own repository | homelab-ui | The front door: a control center, a **Status** page, every tool rebuilt as its own page (dashboards, metrics, logs, traces, Kafka, models, tools, account, Kubernetes), the agent beside every page, and Tasker |
| | agent-runtime · agent-toolbox | The homelab agent and its tools (files, Python sandbox), reachable from the tailnet only; the toolbox is fenced off from the databases |

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
                       │         /api/loki/ tempo/ alloy/ kafka/ llm/ toolbox/ account/
                       │                           ─► the tools' APIs, for homelab-ui's own pages
                       │         /api/kube/        ─► kube-api ─► Kubernetes API  (admin only)
                       │         /api/health/<svc> ─► each service's health endpoint  (Status page)
                       ├─ :8443  ─► keycloak  (sign-in and account pages; /admin blocked)
                       ├─ :3000  ─► grafana   (signs in with Keycloak itself, roles mapped)
                       ├─ :6274  ─► mcp-inspector ─► agent-toolbox
                       ├─ :4466  ─► headlamp ─► kube-api  (admin only)
                       ├─ :8100  ─► agent-runtime  (its API and /docs over HTTPS)
                       └─ :9090 :8080 :12345 :8090 :3100 :3200 :9308
                                 ─► prometheus · kafka-ui · alloy · llm · loki · tempo · kafka-exporter

DATA

  homelab-ui (Tasker) ─► /api/tasker ─► postgrest ─► PostgreSQL     workflows and favorites, per account
  homelab-ui (Agent)  ─► /api/agent  ─► agent-runtime ─┬─ MCP ─► agent-toolbox ─► its working-directory volume
                                                       ├─ OpenAI API ─► NVIDIA's API, or llm
                                                       └─ conversations ─► MongoDB
  db-migrate job (dbmate) ─► PostgreSQL schema       CloudNativePG ─► roles, passwords, the keycloak database
  backups (every night)   ─► /var/backups/homelab on the server: PostgreSQL and MongoDB dumps

AGENT — tailnet devices, homelab-ui and the MCP Inspector

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
| Agent API docs (signed in) | `https://<HOMELAB_DOMAIN>:8100/docs` |
| Headlamp, the Kubernetes dashboard (admins) | `https://<HOMELAB_DOMAIN>:4466` |

**Connect your apps**

| Service | From pods | From another machine |
|---|---|---|
| PostgreSQL | `postgres-rw:5432`, each app with its own user ([Q&A](Q&A.md#which-postgresql-user-should-my-app-use)) | through SSH to the server ([pgAdmin](Q&A.md#how-do-i-connect-pgadmin-4-to-postgresql)), or `make psql` on the server |
| MongoDB | `mongodb://<user>:<password>@mongodb:27017/?authSource=admin` | same with `<HOMELAB_DOMAIN>:27017` ([Compass, mongosh](Q&A.md#how-do-i-connect-to-mongodb)) |
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
├── environments/
│   ├── versions.yaml      every chart, image and app version: what the server runs
│   ├── default.yaml       settings (timezone, LLM provider, retention, backup schedule)
│   ├── global.yaml.gotmpl what every release gets as `global` (domain, hostIP, timezone)
│   └── local.yaml         this server's Tailscale name and address (git-ignored, make local)
├── Makefile               every command (make help)
├── devops_guide.md        how to operate it, step by step
├── Q&A.md                 quick answers: passwords, logs, stop and restart, dev images, scaling
├── scripts/               what the make commands run (below)
│
│   one folder per release: <group>/<release>/values.yaml.gotmpl + the files it reads
├── repository/            postgres · db-migrate (migrations/) · postgrest · mongodb · backups
├── message-broker/        kafka · kafka-ui
├── observability/         prometheus · loki · tempo · otel-collector · alloy
│                          kafka-exporter · mongodb-exporter · grafana (provisioning/, dashboards/)
├── gateway/               caddy (Caddyfile) · keycloak (sync.sh: the realm as code) · oauth2-proxy · kube-api · headlamp
├── llm/                   llm (config.yml: the models) · llm-sd · mcp-inspector · grafana-mcp · mongodb-mcp · postgres-mcp
├── apps/                  yours: homelab-ui · agent-runtime · agent-toolbox (this server's additions only)
└── templates/             myapi-a: a starting point for a new Python API (not deployed)
```

| Script | Run by | Does |
|---|---|---|
| `local.sh` | `make local` | writes `environments/local.yaml` from this machine's Tailscale name and address |
| `secrets.sh` | `make secrets`, `secret-*`, `show-secrets`, every release's presync hook | creates, lists, shows, sets, rotates and checks the Secrets (`SPECS`: every Secret and key) |
| `validate.sh` | `make validate` | checks before a deploy: tools, cluster, firewall, Secrets, the train renders, no port clash, each config with its own tool |
| `verify.sh` | `make verify` | checks after a deploy, group by group, on the running homelab |
| `users.sh` | `make user-*`, `sessions-revoke` | sign-in accounts, with Keycloak's `kcadm.sh` run inside its pod |
| `dbmate.sh` | `make migrate-status`, `migrate-rollback` | a one-off copy of the db-migrate job |
| `backups.sh` | `make backup`, `backups`, `restore-*` | runs the nightly backup jobs now, lists and restores dumps |
| `download_models.sh` | `make llm-download`, `llm-models` | loads models through the LLM's API so they download before first use |
| `_common.sh` | every script | colours, `k` (kubectl in namespace homelab), reading `local.yaml`, the PostgreSQL primary, `kcadm` |

## Find your way

**One rule for files.** Release `<release>` of group `<group>` is configured by `<group>/<release>/values.yaml.gotmpl`; the config files next to it (a `Caddyfile`, `prometheus.yml`, dashboards…) are read into it with `readFile` and mounted into the pod. The `platform` releases (CloudNativePG, Reloader) are public charts used as they are, so they have no folder.

**Where a setting comes from**, lowest first; each layer overrides the one before:

1. kube-charts' `app` chart defaults — security, probes, volumes, what every pod gets.
2. For homelab-ui, agent-runtime and agent-toolbox: their repository's `devops/helm/values.yml`, built into their chart at release.
3. `environments/global.yaml.gotmpl` — `global.domain`, `global.hostIP`, `global.timezone`.
4. `<group>/<release>/values.yaml.gotmpl` — this server's choices. It can read `environments/*.yaml` as `.Values` (versions, settings, `domain`).

**What `make apply` does** (`helmfile apply`):

1. Reads `environments/` and stops if `local.yaml` isn't this server's Tailscale name and address.
2. Renders every release (its values, its config files) and compares it with what runs (`helm diff`); only the releases that changed go on.
3. Deploys them in `needs:` order, independent ones in parallel. For each one: the presync hook checks its Secrets exist, `helm upgrade --install` applies it, then waits until its pods are ready and its jobs are done (10 minutes, the LLM 60), then the postsync hook runs (PostgreSQL: wait for the operator).
4. A pod restarts when its config files change (a checksum on the pod) or a Secret it reads changes (Reloader). Nothing else restarts.
5. If one release fails, the releases after it don't run: fix it, `make apply` again.

**What is deployed right now.** `environments/versions.yaml` at the commit the server has pulled is the release train. `make releases` (`helm list -A`) shows each release's chart version and app version on the cluster; an empty `make diff` means the server runs exactly what git says.

**Where things are on the server.**

| What | Where |
|---|---|
| Every homelab pod, Service, Secret | Kubernetes namespace `homelab` (operators: `cnpg-system`, `reloader`) |
| Volumes (databases, Prometheus, models…) | `/var/lib/rancher/k3s/storage/`, one folder per volume; kept when a release is uninstalled |
| Secrets | Kubernetes Secrets, encrypted on disk by k3s; never in git |
| Backups | `/var/backups/homelab/` (root only) |
| k3s settings | `/etc/rancher/k3s/config.yaml`, `/etc/rancher/k3s/registries.yaml` (Docker Hub login) |
| LAN firewall for Kubernetes' ports | `/etc/homelab/k3s-lan-guard.nft` |

**To change… edit… then.**

| To change | Edit | Then |
|---|---|---|
| A service's version | `environments/versions.yaml` (`images:`) | `make diff`, `make apply` |
| An app's version (after its tag) | `environments/versions.yaml` (`apps:`) | `make apply R=<app>` |
| How a service runs (env, resources, ports) | `<group>/<release>/values.yaml.gotmpl` | `make diff R=<release>`, `make apply R=<release>` |
| How an app runs | its repository's `devops/helm/values.yml`, then a new tag | bump `apps:`, `make apply R=<app>` |
| A web route or a published port | `gateway/caddy/Caddyfile` (and `ports:` in `gateway/caddy/values.yaml.gotmpl`) | `make apply R=caddy` |
| The realm, password policy, sign-in clients | `gateway/keycloak/sync.sh` | `make apply R=keycloak` |
| What Prometheus scrapes | `observability/prometheus/prometheus.yml`, or `metrics:` in a release's values | `make apply R=prometheus` (or that release) |
| A dashboard | `observability/grafana/dashboards/*.json` | `make apply R=grafana` |
| The local models | `llm/llm/config.yml` | `make apply R=llm` |
| Tasker's schema | `make migration-new NAME=…`, then the new file in `repository/db-migrate/migrations/` | `make migrate` |
| Retention, backup schedule, the agent's LLM provider | `environments/default.yaml` | `make apply` |
| A new Secret | `SPECS` in `scripts/secrets.sh` | `make secrets` |
| What every pod gets (security, probes, labels) | kube-charts `charts/app`, then a new chart version | `charts.app` in `versions.yaml`, `make apply` |

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
| homelab-ui, kafka-exporter, PostgREST, oauth2-proxy, kube-api | 128 MiB each |
| Headlamp | 256 MiB |
| mongodb-exporter, llm-sd, db-migrate | 64 MiB each |
| grafana-mcp | 128 MiB |
| mongodb-mcp, postgres-mcp | 384 MiB each |

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
