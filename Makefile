# homelab-infra — deploy and run the homelab on Kubernetes (k3s, Helm, helmfile)
# Usage: make <target> [R=<release>] [G=<group>]   e.g.  make apply R=caddy  |  make logs R=keycloak
# Run `make` or `make help` to list targets. The DevOps guide shows the raw command behind each one.

SHELL        := bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS    += --no-print-directory

NS := homelab
# One release (R=caddy) or one group (G=gateway) for helmfile targets; everything by default
R ?=
G ?=
SELECT := $(if $(R),-l name=$(R),$(if $(G),-l group=$(G),))
TAIL ?= 200
# Sign-in account for the user-* targets (not USER, which make inherits from your shell)
ACCOUNT ?=
# secret-set / secret-rotate: SECRET=<name> KEY=<key>
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

.PHONY: secret-set
secret-set: ## Type a value yourself: make secret-set SECRET=agent-runtime KEY=llm-api-key
	@./scripts/secrets.sh set "$(SECRET)" "$(KEY)"

.PHONY: secret-rotate
secret-rotate: ## Replace a generated value: make secret-rotate SECRET=tasker-gateway KEY=secret
	@./scripts/secrets.sh rotate "$(SECRET)" "$(KEY)"

.PHONY: validate
validate: ## Check tools, cluster, local.yaml, Secrets, that every release renders, the Caddyfile
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

##@ Inspect

.PHONY: status
status: ## Pods, their state and restarts
	@kubectl -n $(NS) get pods -o wide

# PostgreSQL's pods are labelled by its operator, the others by Helm
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
verify: ## Check pods, HTTPS, sign-in, password policy, database roles, published ports
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
	@kubectl -n $(NS) exec -it deploy/$(R) -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'

.PHONY: psql
psql: ## psql into PostgreSQL (database homelab, as postgres)
	@kubectl -n $(NS) exec -it "$$(kubectl -n $(NS) get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name | head -n1)" -c postgres -- psql -d homelab

##@ Danger zone

.PHONY: destroy
destroy: ## Uninstall every release (volumes and Secrets are kept; asks to confirm)
	@read -r -p "Uninstall every homelab release? Volumes and Secrets are kept. Type 'destroy' to confirm: " a; \
	  [ "$$a" = "destroy" ] || { echo "Aborted."; exit 1; }
	@helmfile destroy
