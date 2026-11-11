SHELL        := bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS    += --no-print-directory

NS := homelab
R ?=
G ?=
SELECT := $(if $(R),-l name=$(R),$(if $(G),-l group=$(G),))
TAIL ?= 200
ACCOUNT ?=
SECRET ?=
KEY ?=

##@ Setup

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m [R=<release>] [G=<group>]\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo

.PHONY: local
local: ## Write environments/local.yaml from this machine's Tailscale name and address
	@./scripts/local.sh

.PHONY: secrets
secrets: ## Create every missing password and key as a Kubernetes Secret
	@./scripts/secrets.sh

.PHONY: secrets-list
secrets-list: ## List the Secrets and their keys (no values)
	@./scripts/secrets.sh list

.PHONY: show-secrets
show-secrets: ## Show every password and key, with its value (yours to keep out of git and chats)
	@./scripts/secrets.sh show

.PHONY: secret-set
secret-set: ## Type a value yourself: make secret-set SECRET=agent-runtime KEY=llm-api-key
	@./scripts/secrets.sh set "$(SECRET)" "$(KEY)"

.PHONY: secret-rotate
secret-rotate: ## Replace a generated value: make secret-rotate SECRET=tasker-gateway KEY=secret
	@./scripts/secrets.sh rotate "$(SECRET)" "$(KEY)"

.PHONY: validate
validate: ## Check before deploying: tools, cluster, firewall, Secrets, the train renders, ports, configs
	@./scripts/validate.sh

##@ Deploy (helmfile)

.PHONY: diff
diff: ## Show what apply would change [R=… | G=…]
	@helmfile $(SELECT) diff

.PHONY: apply
apply: ## Install or upgrade what changed [R=… | G=…]
	@helmfile $(SELECT) apply

.PHONY: sync
sync: ## Install or upgrade even without changes, re-running deploy jobs [R=… | G=…]
	@helmfile $(SELECT) sync

.PHONY: template
template: ## Print the rendered Kubernetes manifests [R=… | G=…]
	@helmfile $(SELECT) template

.PHONY: releases
releases: ## Releases on the server, their chart and app version
	@helm list -A

.PHONY: rollback
rollback: ## Go back to a release's previous revision: make rollback R=<release>
	@[ -n "$(R)" ] || { echo "Usage: make rollback R=<release>"; exit 1; }
	@helm -n $(NS) rollback $(R)

.PHONY: restart
restart: ## Restart a release's pods and wait until they're ready (same version and settings): make restart R=<release>
	@[ -n "$(R)" ] || { echo "Usage: make restart R=<release>"; exit 1; }
	@workloads="$$(kubectl -n $(NS) get deploy,statefulset,daemonset -l app.kubernetes.io/instance=$(R) -o name)"; \
	  [ -n "$$workloads" ] || { echo "No Deployment or StatefulSet for release '$(R)'"; exit 1; }; \
	  for workload in $$workloads; do kubectl -n $(NS) rollout restart "$$workload"; done; \
	  for workload in $$workloads; do kubectl -n $(NS) rollout status "$$workload" --timeout=10m; done

##@ Inspect

.PHONY: status ps
status: ## Pods, their state and restarts (also: make ps)
	@kubectl -n $(NS) get pods -o wide
ps: status

PODS_OF = $(if $(filter postgres,$(R)),cnpg.io/cluster=postgres,app.kubernetes.io/instance=$(R))

.PHONY: logs
logs: ## Follow a release's logs: make logs R=<release> [TAIL=500]
	@[ -n "$(R)" ] || { echo "Usage: make logs R=<release>"; exit 1; }
	@kubectl -n $(NS) logs -f --tail=$(TAIL) -l $(PODS_OF) --all-containers --prefix

.PHONY: events
events: ## Recent cluster events (why a pod doesn't start)
	@kubectl -n $(NS) get events --sort-by=.lastTimestamp | tail -n 40

.PHONY: top
top: ## CPU and memory per pod
	@kubectl -n $(NS) top pods

.PHONY: verify
verify: ## Check the running homelab, group by group (pods, HTTPS, sign-in, data, telemetry, LLM, backups)
	@./scripts/verify.sh

##@ Users (sign-in accounts, managed only from this terminal)

.PHONY: users user-add user-password user-disable user-enable user-unlock user-admin user-unadmin user-remove sessions-revoke
users: ## List sign-in accounts
	@./scripts/users.sh list
user-add: ## Create an account: make user-add ACCOUNT=<name> (asks email, name, password)
	@./scripts/users.sh add "$(ACCOUNT)"
user-password: ## Set a new password: make user-password ACCOUNT=<name>
	@./scripts/users.sh password "$(ACCOUNT)"
user-disable: ## Disable an account and end its Keycloak sessions: make user-disable ACCOUNT=<name>
	@./scripts/users.sh disable "$(ACCOUNT)"
user-enable: ## Enable a disabled account: make user-enable ACCOUNT=<name>
	@./scripts/users.sh enable "$(ACCOUNT)"
user-unlock: ## Clear a lock after too many wrong passwords: make user-unlock ACCOUNT=<name>
	@./scripts/users.sh unlock "$(ACCOUNT)"
user-admin: ## Give an account the 'admin' role: make user-admin ACCOUNT=<name>
	@./scripts/users.sh admin "$(ACCOUNT)"
user-unadmin: ## Take the 'admin' role away: make user-unadmin ACCOUNT=<name>
	@./scripts/users.sh unadmin "$(ACCOUNT)"
user-remove: ## Delete an account (asks to confirm, optionally its Tasker data): make user-remove ACCOUNT=<name>
	@./scripts/users.sh remove "$(ACCOUNT)"
sessions-revoke: ## Sign every account out now (new cookie key + end Keycloak sessions)
	@./scripts/secrets.sh rotate oauth2-proxy cookie-secret
	@./scripts/users.sh logout-all

##@ Shells

.PHONY: sh
sh: ## Shell into a release's pod: make sh R=<release>
	@[ -n "$(R)" ] || { echo "Usage: make sh R=<release>"; exit 1; }
	@kubectl -n $(NS) exec -it "$$(kubectl -n $(NS) get pod -l $(PODS_OF) --field-selector=status.phase=Running -o name | head -n1)" -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'

.PHONY: psql
psql: ## psql into PostgreSQL (database homelab, as postgres)
	@kubectl -n $(NS) exec -it "$(PRIMARY)" -c postgres -- psql -d homelab

.PHONY: mongosh
mongosh: ## mongosh into MongoDB as root
	@kubectl -n $(NS) exec -it mongodb-0 -- sh -c 'mongosh -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'

##@ Database migrations (repository/db-migrate/migrations)

MIGRATIONS_DIR := repository/db-migrate/migrations
NAME ?=
PRIMARY = $$(kubectl -n $(NS) get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name | head -n1)

.PHONY: migrate migrate-status migrate-rollback migration-new
migrate: ## Apply the migrations not applied yet, then reload PostgREST's schema
	@helmfile -l name=db-migrate sync
	@kubectl -n $(NS) exec "$(PRIMARY)" -c postgres -- psql -d homelab -qc "NOTIFY pgrst, 'reload schema'" && echo "PostgREST schema reloaded"
migrate-status: ## List applied and pending migrations
	@./scripts/dbmate.sh status
migrate-rollback: ## Undo the latest migration (runs its 'migrate:down', asks to confirm)
	@read -r -p "Undo the latest migration? Its data changes are lost. Type 'rollback' to confirm: " a; \
	  [ "$$a" = "rollback" ] || { echo "Aborted."; exit 1; }
	@./scripts/dbmate.sh rollback
	@kubectl -n $(NS) exec "$(PRIMARY)" -c postgres -- psql -d homelab -qc "NOTIFY pgrst, 'reload schema'" && echo "PostgREST schema reloaded"
migration-new: ## Create the next numbered migration file: make migration-new NAME=add_workflow_tags
	@[[ "$(NAME)" =~ ^[a-z0-9_]+$$ ]] || { echo "Usage: make migration-new NAME=<lowercase_with_underscores>"; exit 1; }
	@last=$$(ls $(MIGRATIONS_DIR) | sed -n 's/^\([0-9][0-9][0-9]\)_.*/\1/p' | sort | tail -n 1); \
	next=$$(printf '%03d' $$((10#$${last:-0} + 1))); \
	file=$(MIGRATIONS_DIR)/$${next}_$(NAME).sql; \
	printf -- '-- migrate:up\n\n\n-- migrate:down\n\n' > "$$file"; \
	echo "→ $$file  (write the up and down SQL, then: make migrate)"

##@ Kafka

KAFKA := kubectl -n $(NS) exec -it kafka-0 -- /opt/kafka/bin
TOPIC ?=
PARTITIONS ?= 3

.PHONY: topics topic-create topic-describe consume groups
topics: ## List topics
	@$(KAFKA)/kafka-topics.sh --bootstrap-server localhost:9092 --list
topic-create: ## Create a topic: make topic-create TOPIC=demo [PARTITIONS=3]
	@[ -n "$(TOPIC)" ] || { echo "Usage: make topic-create TOPIC=<name>"; exit 1; }
	@$(KAFKA)/kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic $(TOPIC) --partitions $(PARTITIONS) --replication-factor 1
topic-describe: ## Describe a topic: make topic-describe TOPIC=demo
	@[ -n "$(TOPIC)" ] || { echo "Usage: make topic-describe TOPIC=<name>"; exit 1; }
	@$(KAFKA)/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic $(TOPIC)
consume: ## Read a topic from the beginning: make consume TOPIC=demo
	@[ -n "$(TOPIC)" ] || { echo "Usage: make consume TOPIC=<name>"; exit 1; }
	@$(KAFKA)/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic $(TOPIC) --from-beginning
groups: ## Consumer groups with lag
	@$(KAFKA)/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups

##@ Observability

INSIDE := kubectl -n $(NS) exec deploy/caddy -c caddy -- wget -q -T 10 -O -

.PHONY: targets
targets: ## Prometheus scrape targets and their state
	@$(INSIDE) http://prometheus:9090/api/v1/targets | \
	  jq -r '.data.activeTargets[] | "  \(.health | (. + "      ")[:7]) \(.labels.job | (. + "                ")[:16]) \(.scrapeUrl)"'

##@ LLM (llama-swap)

M ?= qwen3-8b
MODELS ?=
Q ?= What is Apache Kafka? Answer in two sentences.
LLM_TEST = LLM_GATEWAY_API_KEY="$$(kubectl -n $(NS) get secret llm-gateway -o jsonpath='{.data.api-key}' | base64 -d)" \
  python3 llm/llm/test.py
DOMAIN = $$(awk '$$1 == "domain:" { print $$2 }' environments/local.yaml)

.PHONY: llm-status llm-running llm-ask llm-models llm-download llm-down llm-up
llm-status: ## Is the LLM up, and which models does it serve
	@$(INSIDE) http://llm:8080/v1/models | jq -r '"  models:", (.data[] | "    - \(.id)")'
llm-running: ## Which models are loaded right now (UP) and which aren't (DOWN)
	@$(LLM_TEST) running "https://$(DOMAIN):8090"
llm-ask: ## Ask a question: make llm-ask [M=<model>] [Q="..."]
	@$(LLM_TEST) ask "https://$(DOMAIN):8090" "$(M)" "$(Q)"
llm-models: ## The models llm/llm/config.yml defines
	@./scripts/download_models.sh --list
llm-download: ## Download models before their first use: make llm-download MODELS="qwen3-14b qwen3.5-2b" (or MODELS=--all)
	@[ -n "$(MODELS)" ] || { echo 'Usage: make llm-download MODELS="<model> …" (or MODELS=--all; names: make llm-models)'; exit 1; }
	@./scripts/download_models.sh $(MODELS)
llm-down: ## Stop the LLM (frees its memory) until make llm-up
	@kubectl -n $(NS) scale deploy/llm --replicas=0
llm-up: ## Start the LLM again
	@kubectl -n $(NS) scale deploy/llm --replicas=1

##@ Backups (/var/backups/homelab, every night)

FILE ?=

.PHONY: backup backups restore-postgres restore-mongo
backup: ## Back up PostgreSQL and MongoDB now
	@./scripts/backups.sh now
backups: ## List the backups
	@./scripts/backups.sh list
restore-postgres: ## Restore a database (REPLACES it): make restore-postgres FILE=/var/backups/homelab/postgres/<file>.dump
	@./scripts/backups.sh restore-postgres "$(FILE)"
restore-mongo: ## Restore MongoDB (REPLACES it): make restore-mongo FILE=/var/backups/homelab/mongodb/<file>.archive
	@./scripts/backups.sh restore-mongo "$(FILE)"

##@ Danger zone

.PHONY: destroy
destroy: ## Uninstall every release (volumes and Secrets are kept; asks to confirm)
	@read -r -p "Uninstall every homelab release? Volumes and Secrets are kept. Type 'destroy' to confirm: " a; \
	  [ "$$a" = "destroy" ] || { echo "Aborted."; exit 1; }
	@helmfile destroy
