# homelab-infra — control the stack
# Usage: make <target> [S="svc1 svc2"]      e.g.  make logs S=kafka   |   make restart S="grafana tempo"
# Run `make` or `make help` to list targets.

SHELL        := bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS    += --no-print-directory

# Load and export .env for every compose call (the included compose files need the variables)
ENV_FILE := .env
COMPOSE  := set -a; [ -f $(ENV_FILE) ] && . ./$(ENV_FILE); set +a; docker compose

# Address the published ports listen on (BIND_ADDR from .env, e.g. your Tailscale IP)
HOST := $(shell [ -f .env ] && . ./.env; echo "$${BIND_ADDR:-127.0.0.1}")
# Tailscale name the gateway answers on (HOMELAB_DOMAIN from .env)
DOMAIN := $(shell [ -f .env ] && . ./.env; echo "$${HOMELAB_DOMAIN:-}")

# Optional service selection
S ?=
TAIL ?= 200

# Service groups
OBS   := prometheus loki tempo otel-collector alloy grafana
KAFKA := kafka kafka-ui kafka-exporter
DB    := postgres mongodb postgres-exporter mongodb-exporter postgrest
GATEWAY := caddy keycloak oauth2-proxy
APPS  := agent-toolbox agent-runtime mcp-inspector homelab-ui

# Sign-in account for the user-* targets (not USER, which make inherits from your shell)
ACCOUNT ?=

BACKUP_DIR := backups
DATE := $(shell date +%F_%H%M)

##@ Setup

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m [S=\"svc ...\"]\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo

.PHONY: env
env: ## Create .env from .env.example (won't overwrite)
	@if [ -f $(ENV_FILE) ]; then echo ".env already exists"; \
	else cp .env.example $(ENV_FILE) && chmod 600 $(ENV_FILE) && echo "Created .env (readable by you only) — next: make secrets"; fi

.PHONY: secrets
secrets: check-env ## Generate every 'changeme' password and secret in .env, then list what is left to set
	@./scripts/secrets.sh

.PHONY: check-env
check-env:
	@[ -f $(ENV_FILE) ] || { echo "Missing .env — run: make env"; exit 1; }

.PHONY: validate
validate: ## Run pre-flight checks (env, compose, tool configs)
	@./scripts/validate.sh

.PHONY: config
config: check-env ## Print the fully resolved compose model
	@$(COMPOSE) config

##@ Lifecycle

.PHONY: up
up: check-env ## Build & start everything (or S="...")
	@./scripts/up.sh $(S)

.PHONY: down
down: check-env ## Stop and remove containers (data kept)
	@./scripts/down.sh

.PHONY: stop
stop: check-env ## Stop containers without removing them (or S="...")
	@$(COMPOSE) stop $(S)

.PHONY: start
start: check-env ## Start stopped containers (or S="...")
	@$(COMPOSE) start $(S)

.PHONY: restart
restart: check-env ## Restart containers (or S="...")
	@$(COMPOSE) restart $(S)

.PHONY: recreate
recreate: check-env ## Force-recreate containers, e.g. after a config change (or S="...")
	@$(COMPOSE) up -d --force-recreate $(S)

.PHONY: build
build: check-env ## Rebuild locally-built images without cache (or S="...")
	@$(COMPOSE) build --no-cache $(S)

.PHONY: pull
pull: check-env ## Pull images (after bumping tags in .env)
	@$(COMPOSE) pull --ignore-buildable $(S)

.PHONY: update
update: check-env ## Pull new images then recreate changed containers
	@$(MAKE) pull
	@$(MAKE) up

##@ Groups

.PHONY: up-obs up-kafka up-db up-gateway up-apps up-llm
up-obs: check-env ## Start observability only (Prometheus, Loki, Tempo, OTel, Alloy, Grafana)
	@$(COMPOSE) up -d $(OBS)
up-kafka: check-env ## Start Kafka, Kafka UI, exporter
	@$(COMPOSE) up -d $(KAFKA)
up-db: check-env ## Start PostgreSQL, MongoDB, their exporters and PostgREST
	@$(COMPOSE) up -d $(DB)
up-gateway: check-env ## Start the gateway: Caddy (HTTPS), Keycloak and oauth2-proxy (sign-in)
	@$(COMPOSE) up -d $(GATEWAY)
up-apps: check-env ## Start agent-toolbox, agent-runtime, the MCP Inspector and homelab-ui
	@$(COMPOSE) up -d $(APPS)
up-llm: check-env ## Start the LLM server (llama-swap)
	@$(COMPOSE) up -d llm

.PHONY: down-apps
down-apps: check-env ## Stop only the apps
	@$(COMPOSE) stop $(APPS)

##@ Inspect

.PHONY: ps
ps: check-env ## Container status
	@$(COMPOSE) ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

.PHONY: logs
logs: check-env ## Follow logs (S="..." TAIL=500)
	@$(COMPOSE) logs -f --tail=$(TAIL) $(S)

.PHONY: stats
stats: ## Live CPU / memory per container
	@docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

# `make health` checks every service from inside the Docker network (through the caddy container,
# so no sign-in is needed), then the gateway itself from this machine over HTTPS.
# Add a line when you add a service with an HTTP endpoint.
HEALTH_INTERNAL := \
  'homelab-ui|http://homelab-ui:8080/' \
  'grafana|http://grafana:3000/api/health' \
  'prometheus|http://prometheus:9090/-/ready' \
  'loki|http://loki:3100/ready' \
  'tempo|http://tempo:3200/ready' \
  'otel-collector|http://otel-collector:13133/' \
  'alloy|http://alloy:12345/-/ready' \
  'kafka-ui|http://kafka-ui:8080/actuator/health' \
  'kafka-exporter|http://kafka-exporter:9308/metrics' \
  'postgres-exporter|http://postgres-exporter:9187/metrics' \
  'mongodb-exporter|http://mongodb-exporter:9216/metrics' \
  'cadvisor|http://cadvisor:8080/healthz' \
  'postgrest|http://postgrest:3002/ready' \
  'agent-toolbox|http://agent-toolbox:8001/actuator/health' \
  'agent-runtime|http://agent-runtime:8000/actuator/health' \
  'mcp-inspector|http://mcp-inspector:6274/' \
  'keycloak|http://keycloak:9000/health/ready' \
  'oauth2-proxy|http://oauth2-proxy:4180/ping' \
  'llm|http://llm:8080/health'
HEALTH_GATEWAY := \
  'gateway|https://$(DOMAIN)/healthz' \
  'sign-in|https://$(DOMAIN):8443/realms/homelab/.well-known/openid-configuration'

# Fetches a URL from inside the Docker network (busybox wget in the caddy container)
INSIDE := $(COMPOSE) exec -T caddy wget -q -T 5 -O -

.PHONY: health
health: check-env ## Quick health checks: every service inside Docker, then the gateway over HTTPS
	@for u in $(HEALTH_INTERNAL); do \
	  name=$${u%%|*}; url=$${u#*|}; \
	  if err=$$($(INSIDE) "$$url" 2>&1 >/dev/null); then printf "  \033[32m✓\033[0m %s\n" "$$name"; \
	  else printf "  \033[31m✗\033[0m %s  (%s — %s)\n" "$$name" "$$url" "$$(printf '%s' "$$err" | tail -n 1)"; fi; \
	done
	@for u in $(HEALTH_GATEWAY); do \
	  name=$${u%%|*}; url=$${u#*|}; \
	  if curl -fsS -o /dev/null --max-time 5 "$$url"; then printf "  \033[32m✓\033[0m %s\n" "$$name"; \
	  else printf "  \033[31m✗\033[0m %s  (%s)\n" "$$name" "$$url"; fi; \
	done

.PHONY: targets
targets: check-env ## Prometheus scrape targets and their state
	@$(INSIDE) http://prometheus:9090/api/v1/targets | \
	  python3 -c 'import sys,json; [print("  %7s  %-16s %s" % (t["health"], t["labels"]["job"], t["scrapeUrl"])) for t in json.load(sys.stdin)["data"]["activeTargets"]]'

.PHONY: volumes
volumes: ## List data volumes and their size
	@docker system df -v | awk '/^VOLUME NAME/{f=1} f&&/^$$/{exit} f' | grep -E '^(VOLUME NAME|homelab_)' || true

.PHONY: verify
verify: check-env ## Check HTTPS, sign-in, password policy, Tasker API protection and per-user data
	@./scripts/verify.sh

##@ Users (sign-in accounts, managed only from this terminal)

.PHONY: users user-add user-password user-disable user-enable user-unlock user-admin user-unadmin user-remove sessions-revoke
users: check-env ## List sign-in accounts
	@./scripts/users.sh list
user-add: check-env ## Create an account: make user-add ACCOUNT=<name> (asks email, name, password)
	@./scripts/users.sh add "$(ACCOUNT)"
user-password: check-env ## Set a new password: make user-password ACCOUNT=<name>
	@./scripts/users.sh password "$(ACCOUNT)"
user-disable: check-env ## Disable an account and end its Keycloak sessions: make user-disable ACCOUNT=<name>
	@./scripts/users.sh disable "$(ACCOUNT)"
user-enable: check-env ## Enable a disabled account: make user-enable ACCOUNT=<name>
	@./scripts/users.sh enable "$(ACCOUNT)"
user-unlock: check-env ## Clear a lock after too many wrong passwords: make user-unlock ACCOUNT=<name>
	@./scripts/users.sh unlock "$(ACCOUNT)"
user-admin: check-env ## Give an account the 'admin' role: make user-admin ACCOUNT=<name>
	@./scripts/users.sh admin "$(ACCOUNT)"
user-unadmin: check-env ## Take the 'admin' role away: make user-unadmin ACCOUNT=<name>
	@./scripts/users.sh unadmin "$(ACCOUNT)"
user-remove: check-env ## Delete an account (asks to confirm, optionally its Tasker data): make user-remove ACCOUNT=<name>
	@./scripts/users.sh remove "$(ACCOUNT)"
sessions-revoke: check-env ## Sign every account out now (new cookie key + end Keycloak sessions)
	@./scripts/secrets.sh --rotate OAUTH2_PROXY_COOKIE_SECRET
	@$(COMPOSE) up -d --force-recreate oauth2-proxy
	@./scripts/users.sh logout-all

##@ Database (migrations and passwords)

MIGRATIONS_DIR := repository/postgres/migrations
NAME ?=

.PHONY: migrate migrate-status migrate-rollback migration-new db-passwords-check postgres-password-sync mongo-password-sync
migrate: check-env ## Apply the migrations not applied yet, then reload PostgREST's schema
	@$(COMPOSE) run --rm db-migrate migrate
	@$(COMPOSE) kill -s SIGUSR1 postgrest >/dev/null 2>&1 && echo "PostgREST schema reloaded" || true
migrate-status: check-env ## List applied and pending migrations
	@$(COMPOSE) run --rm db-migrate status
migrate-rollback: check-env ## Undo the latest migration (runs its 'migrate:down', asks to confirm)
	@read -r -p "Undo the latest migration? Its data changes are lost. Type 'rollback' to confirm: " a; \
	  [ "$$a" = "rollback" ] || { echo "Aborted."; exit 1; }
	@$(COMPOSE) run --rm db-migrate rollback
	@$(COMPOSE) kill -s SIGUSR1 postgrest >/dev/null 2>&1 && echo "PostgREST schema reloaded" || true
migration-new: ## Create the next numbered migration file: make migration-new NAME=add_workflow_tags
	@[[ "$(NAME)" =~ ^[a-z0-9_]+$$ ]] || { echo "Usage: make migration-new NAME=<lowercase_with_underscores>"; exit 1; }
	@last=$$(ls $(MIGRATIONS_DIR) | sed -n 's/^\([0-9][0-9][0-9]\)_.*/\1/p' | sort | tail -n 1); \
	next=$$(printf '%03d' $$((10#$${last:-0} + 1))); \
	file=$(MIGRATIONS_DIR)/$${next}_$(NAME).sql; \
	printf -- '-- migrate:up\n\n\n-- migrate:down\n\n' > "$$file"; \
	echo "→ $$file  (write the up and down SQL, then: make migrate)"
db-passwords-check: check-env ## Check PostgreSQL and MongoDB accept the passwords in .env
	@./scripts/db-passwords.sh check
postgres-password-sync: check-env ## Make PostgreSQL use POSTGRES_PASSWORD from .env (old one not needed)
	@./scripts/db-passwords.sh postgres-sync
mongo-password-sync: check-env ## Make MongoDB use MONGO_ROOT_PASSWORD from .env (asks the current one)
	@./scripts/db-passwords.sh mongo-sync

##@ Shells

.PHONY: sh
sh: check-env ## Shell into a container: make sh S=kafka
	@[ -n "$(S)" ] || { echo "Usage: make sh S=<service>"; exit 1; }
	@$(COMPOSE) exec $(S) sh -c 'command -v bash >/dev/null && exec bash || exec sh'

.PHONY: psql
psql: check-env ## psql into PostgreSQL
	@$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

.PHONY: mongosh
mongosh: check-env ## mongosh into MongoDB as root
	@$(COMPOSE) exec mongodb sh -c 'mongosh -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'

##@ Kafka

KAFKA_BIN := /opt/kafka/bin
TOPIC ?=
PARTITIONS ?= 3

.PHONY: topics
topics: check-env ## List topics
	@$(COMPOSE) exec kafka $(KAFKA_BIN)/kafka-topics.sh --bootstrap-server localhost:9092 --list

.PHONY: topic-create
topic-create: check-env ## Create a topic: make topic-create TOPIC=demo [PARTITIONS=3]
	@[ -n "$(TOPIC)" ] || { echo "Usage: make topic-create TOPIC=<name>"; exit 1; }
	@$(COMPOSE) exec kafka $(KAFKA_BIN)/kafka-topics.sh --bootstrap-server localhost:9092 \
	  --create --if-not-exists --topic $(TOPIC) --partitions $(PARTITIONS) --replication-factor 1

.PHONY: topic-describe
topic-describe: check-env ## Describe a topic: make topic-describe TOPIC=demo
	@[ -n "$(TOPIC)" ] || { echo "Usage: make topic-describe TOPIC=<name>"; exit 1; }
	@$(COMPOSE) exec kafka $(KAFKA_BIN)/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic $(TOPIC)

.PHONY: consume
consume: check-env ## Consume a topic from the beginning: make consume TOPIC=demo
	@[ -n "$(TOPIC)" ] || { echo "Usage: make consume TOPIC=<name>"; exit 1; }
	@$(COMPOSE) exec kafka $(KAFKA_BIN)/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic $(TOPIC) --from-beginning

.PHONY: groups
groups: check-env ## Consumer groups with lag
	@$(COMPOSE) exec kafka $(KAFKA_BIN)/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups

##@ Observability

.PHONY: reload-prometheus
reload-prometheus: check-env ## Hot-reload prometheus.yml (make up does it too)
	@$(COMPOSE) kill -s SIGHUP prometheus >/dev/null && echo "Prometheus reloaded"

.PHONY: reload-alloy
reload-alloy: check-env ## Hot-reload config.alloy (make up does it too)
	@$(COMPOSE) kill -s SIGHUP alloy >/dev/null && echo "Alloy reloaded"

##@ LLM (llama-swap)

# M = model name for llm-ask (see ai/llm/config.yml for the names llama-swap serves)
M ?= qwen3-8b
Q ?= What is Apache Kafka? Answer in two sentences.
LLM_PORT := 8090
# ai/llm/test.py goes through the gateway with the LLM API key from .env
LLM_TEST := set -a; . ./$(ENV_FILE); set +a; python3 ai/llm/test.py

.PHONY: llm-down
llm-down: check-env ## Stop the LLM server (frees the RAM of always-on models)
	@$(COMPOSE) stop llm

.PHONY: llm-status
llm-status: check-env ## Health check and list of models served by llama-swap
	@if $(INSIDE) http://llm:8080/health >/dev/null 2>&1; then \
	  printf "  \033[32m✓\033[0m llm  :%s\n" "$(LLM_PORT)"; \
	  $(INSIDE) http://llm:8080/v1/models | \
	    python3 -c 'import sys,json; [print("      -", m["id"]) for m in json.load(sys.stdin)["data"]]'; \
	else \
	  printf "  \033[31m✗\033[0m llm  :%s  not ready (downloading, loading or stopped)\n" "$(LLM_PORT)"; \
	fi

.PHONY: llm-running
llm-running: check-env ## Show which models are currently loaded (UP) vs not (DOWN)
	@$(LLM_TEST) running "https://$(DOMAIN):$(LLM_PORT)"

.PHONY: llm-logs
llm-logs: check-env ## Follow llama-swap logs
	@$(COMPOSE) logs -f --tail=$(TAIL) llm

.PHONY: llm-ask
llm-ask: check-env ## Ask a question: make llm-ask [M=<model>] [Q="..."] — see ai/llm/config.yml for model names
	@$(LLM_TEST) ask "https://$(DOMAIN):$(LLM_PORT)" "$(M)" "$(Q)"

##@ Backup

.PHONY: backup
backup: ## Backup PostgreSQL and MongoDB into ./backups
	@$(MAKE) backup-postgres
	@$(MAKE) backup-mongo

.PHONY: backup-postgres
backup-postgres: check-env ## Dump PostgreSQL: the homelab database and keycloak (sign-in accounts)
	@mkdir -p $(BACKUP_DIR)
	@out=$(BACKUP_DIR)/postgres_$(DATE).dump; \
	$(COMPOSE) exec -T postgres sh -c 'pg_dump -U "$$POSTGRES_USER" -Fc "$$POSTGRES_DB"' > "$$out.tmp" \
	  || { rm -f "$$out.tmp"; echo "PostgreSQL backup FAILED"; exit 1; }; \
	mv "$$out.tmp" "$$out"; echo "→ $$out"
	@out=$(BACKUP_DIR)/keycloak_$(DATE).dump; \
	$(COMPOSE) exec -T postgres sh -c 'pg_dump -U "$$POSTGRES_USER" -Fc keycloak' > "$$out.tmp" \
	  || { rm -f "$$out.tmp"; echo "Keycloak backup FAILED"; exit 1; }; \
	mv "$$out.tmp" "$$out"; echo "→ $$out"

.PHONY: backup-mongo
backup-mongo: check-env ## Dump MongoDB (gzip archive)
	@mkdir -p $(BACKUP_DIR)
	@out=$(BACKUP_DIR)/mongo_$(DATE).archive; \
	$(COMPOSE) exec -T mongodb sh -c 'mongodump -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --quiet' > "$$out.tmp" \
	  || { rm -f "$$out.tmp"; echo "MongoDB backup FAILED"; exit 1; }; \
	mv "$$out.tmp" "$$out"; echo "→ $$out"

FILE ?=
DB ?=

.PHONY: restore-postgres
restore-postgres: check-env ## Restore PostgreSQL (REPLACES data): make restore-postgres FILE=backups/x.dump [DB=keycloak]
	@[ -f "$(FILE)" ] || { echo "Usage: make restore-postgres FILE=<dump> [DB=keycloak]"; exit 1; }
	@read -r -p "This REPLACES the current PostgreSQL data$(if $(DB), of $(DB),) with $(FILE). Type 'restore' to confirm: " a; \
	  [ "$$a" = "restore" ] || { echo "Aborted."; exit 1; }
	@$(COMPOSE) exec -T -e RESTORE_DB="$(DB)" postgres sh -c 'pg_restore -U "$$POSTGRES_USER" -d "$${RESTORE_DB:-$$POSTGRES_DB}" --clean --if-exists' < "$(FILE)"
	@echo "PostgreSQL restored from $(FILE)"

.PHONY: restore-mongo
restore-mongo: check-env ## Restore MongoDB (REPLACES data): make restore-mongo FILE=backups/x.archive
	@[ -f "$(FILE)" ] || { echo "Usage: make restore-mongo FILE=<archive>"; exit 1; }
	@read -r -p "This REPLACES the current MongoDB data with $(FILE). Type 'restore' to confirm: " a; \
	  [ "$$a" = "restore" ] || { echo "Aborted."; exit 1; }
	@$(COMPOSE) exec -T mongodb sh -c 'mongorestore -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --drop' < "$(FILE)"
	@echo "MongoDB restored from $(FILE)"

##@ Danger zone

.PHONY: clean
clean: check-env ## Stop and DELETE ALL DATA volumes (asks for confirmation)
	@./scripts/down.sh --volumes

.PHONY: prune
prune: ## Remove dangling images and build cache
	@docker image prune -f && docker builder prune -f
