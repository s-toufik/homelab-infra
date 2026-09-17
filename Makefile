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

# Optional service selection
S ?=
TAIL ?= 200

# Service groups
OBS   := prometheus loki tempo otel-collector alloy grafana
KAFKA := kafka kafka-ui kafka-exporter
DB    := postgres mongodb
APPS  := myapi-a myapi-b

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
	else cp .env.example $(ENV_FILE) && echo "Created .env — edit the 'changeme' values"; fi

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
build: check-env ## Rebuild app images without cache
	@$(COMPOSE) build --no-cache $(APPS)

.PHONY: pull
pull: check-env ## Pull images (after bumping tags in .env)
	@$(COMPOSE) pull --ignore-buildable $(S)

.PHONY: update
update: check-env ## Pull new images then recreate changed containers
	@$(MAKE) pull
	@$(MAKE) up

##@ Groups

.PHONY: up-obs up-kafka up-db up-apps up-llm
up-obs: check-env ## Start observability only (Prometheus, Loki, Tempo, OTel, Alloy, Grafana)
	@$(COMPOSE) up -d $(OBS)
up-kafka: check-env ## Start Kafka, Kafka UI, exporter
	@$(COMPOSE) up -d $(KAFKA)
up-db: check-env ## Start PostgreSQL and MongoDB
	@$(COMPOSE) up -d $(DB)
up-apps: check-env ## Build & start myapi-a and myapi-b
	@$(COMPOSE) up -d --build $(APPS)
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

# Endpoints checked by `make health`. Remove a line if you removed that service's published port.
HEALTH_URLS := \
  'grafana|http://$(HOST):3000/api/health' \
  'prometheus|http://$(HOST):9090/-/ready' \
  'loki|http://$(HOST):3100/ready' \
  'tempo|http://$(HOST):3200/ready' \
  'otel-collector|http://$(HOST):13133/' \
  'alloy|http://$(HOST):12345/-/ready' \
  'kafka-exporter|http://$(HOST):9308/metrics' \
  'myapi-a|http://$(HOST):8001/health' \
  'myapi-b|http://$(HOST):8002/health' \
  'llm|http://$(HOST):8090/health'

.PHONY: health
health: ## Quick HTTP health checks of main endpoints
	@for u in $(HEALTH_URLS); do \
	  name=$${u%%|*}; url=$${u#*|}; \
	  if curl -fsS -o /dev/null --max-time 3 "$$url"; then printf "  \033[32m✓\033[0m %s\n" "$$name"; \
	  else printf "  \033[31m✗\033[0m %s  (%s)\n" "$$name" "$$url"; fi; \
	done

.PHONY: targets
targets: ## Prometheus scrape targets and their state
	@curl -fsS http://$(HOST):9090/api/v1/targets | \
	  python3 -c 'import sys,json; [print("  %7s  %-16s %s" % (t["health"], t["labels"]["job"], t["scrapeUrl"])) for t in json.load(sys.stdin)["data"]["activeTargets"]]'

.PHONY: volumes
volumes: ## List data volumes and their size
	@docker system df -v | awk '/^VOLUME NAME/{f=1} f&&/^$$/{exit} f' | grep -E '^(VOLUME NAME|homelab_)' || true

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
reload-prometheus: ## Hot-reload prometheus.yml
	@curl -fsS -X POST http://$(HOST):9090/-/reload && echo "Prometheus reloaded"

.PHONY: reload-alloy
reload-alloy: ## Hot-reload config.alloy
	@curl -fsS -X POST http://$(HOST):12345/-/reload && echo "Alloy reloaded"

N ?= 200
FANOUT ?= 5
.PHONY: traffic
traffic: ## Generate demo traces: make traffic [N=200 FANOUT=5]
	@echo "Sending $(N) requests to myapi-b /chain (fanout=$(FANOUT))..."
	@for i in $$(seq 1 $(N)); do curl -fs -o /dev/null "http://$(HOST):8002/chain?fanout=$(FANOUT)" || true; done
	@echo "Done — open Grafana → Explore → Tempo"

##@ LLM (llama-swap)

# M = model name for llm-ask (see llm/config.yml for the names llama-swap serves)
M ?= granite4-7b
Q ?= What is Apache Kafka? Answer in two sentences.
LLM_PORT := 8090

.PHONY: llm-down
llm-down: check-env ## Stop the LLM server (frees the RAM of always-on models)
	@$(COMPOSE) stop llm

.PHONY: llm-status
llm-status: ## Health check and list of models served by llama-swap
	@if curl -fsS -o /dev/null --max-time 3 "http://$(HOST):$(LLM_PORT)/health"; then \
	  printf "  \033[32m✓\033[0m llm  :%s\n" "$(LLM_PORT)"; \
	  curl -fsS --max-time 3 "http://$(HOST):$(LLM_PORT)/v1/models" | \
	    python3 -c 'import sys,json; [print("      -", m["id"]) for m in json.load(sys.stdin)["data"]]'; \
	else \
	  printf "  \033[31m✗\033[0m llm  :%s  not ready (downloading, loading or stopped)\n" "$(LLM_PORT)"; \
	fi

.PHONY: llm-logs
llm-logs: check-env ## Follow llama-swap logs
	@$(COMPOSE) logs -f --tail=$(TAIL) llm

.PHONY: llm-ask
llm-ask: ## Ask a question: make llm-ask [M=<model>] [Q="..."] — see llm/config.yml for model names
	@python3 llm/test.py ask "http://$(HOST):$(LLM_PORT)" "$(M)" "$(Q)"

##@ Backup

.PHONY: backup
backup: ## Backup PostgreSQL and MongoDB into ./backups
	@$(MAKE) backup-postgres
	@$(MAKE) backup-mongo

.PHONY: backup-postgres
backup-postgres: check-env ## Dump PostgreSQL (custom format)
	@mkdir -p $(BACKUP_DIR)
	@out=$(BACKUP_DIR)/postgres_$(DATE).dump; \
	$(COMPOSE) exec -T postgres sh -c 'pg_dump -U "$$POSTGRES_USER" -Fc "$$POSTGRES_DB"' > "$$out.tmp" \
	  || { rm -f "$$out.tmp"; echo "PostgreSQL backup FAILED"; exit 1; }; \
	mv "$$out.tmp" "$$out"; echo "→ $$out"

.PHONY: backup-mongo
backup-mongo: check-env ## Dump MongoDB (gzip archive)
	@mkdir -p $(BACKUP_DIR)
	@out=$(BACKUP_DIR)/mongo_$(DATE).archive; \
	$(COMPOSE) exec -T mongodb sh -c 'mongodump -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --quiet' > "$$out.tmp" \
	  || { rm -f "$$out.tmp"; echo "MongoDB backup FAILED"; exit 1; }; \
	mv "$$out.tmp" "$$out"; echo "→ $$out"

FILE ?=

.PHONY: restore-postgres
restore-postgres: check-env ## Restore PostgreSQL (REPLACES data): make restore-postgres FILE=backups/x.dump
	@[ -f "$(FILE)" ] || { echo "Usage: make restore-postgres FILE=<dump>"; exit 1; }
	@read -r -p "This REPLACES the current PostgreSQL data with $(FILE). Type 'restore' to confirm: " a; \
	  [ "$$a" = "restore" ] || { echo "Aborted."; exit 1; }
	@$(COMPOSE) exec -T postgres sh -c 'pg_restore -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --clean --if-exists' < "$(FILE)"
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
