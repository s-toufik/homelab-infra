# Database migrations

Versioned SQL for the PostgreSQL schemas the stack owns (today: `tasker`, used through [PostgREST](../postgrest/README.md)).

```text
database/
├── migrations/
│   ├── 001_create_roles.sql              tasker_web (no login), postgrest (login, no superuser, no RLS bypass)
│   ├── 002_create_schema_and_tables.sql  tasker.workflows, tasker.block_favorites, owner column, JSON checks
│   ├── 003_create_auth_functions.sql     tasker.current_username(), tasker.check_request()
│   ├── 004_enable_rls.sql                row-level security, enforced, owner-only policies
│   └── 005_grant_permissions.sql         privileges; PUBLIC loses access to the schema and to public's CREATE
├── provision.sh                          role passwords from .env, the keycloak database
└── compose.yml                           db-migrate, then db-provision (both run once per `make up`, then exit)
```

## How it runs

On every `make up`: PostgreSQL healthy → **db-migrate** ([dbmate](https://github.com/amacneil/dbmate) `migrate`: applies only the migrations not applied yet, recorded in `public.schema_migrations`) → **db-provision** (sets the `postgrest` and `keycloak` role passwords from `.env`, creates the `keycloak` database once) → PostgREST and Keycloak start.

Passwords are never in a migration: `provision.sh` passes them to `psql` as variables, and PostgreSQL stores them as SCRAM-SHA-256 verifiers.

## Adding a migration

1. Add `database/migrations/<next number>_<what it does>.sql` with a `-- migrate:up` and a `-- migrate:down` section. Never edit a migration that has run.
2. `make validate` checks both sections are there; `make up` applies it; `make verify` reports any migration still pending.

```bash
docker compose run --rm db-migrate status     # what is applied and what is pending
docker compose run --rm db-migrate rollback   # undo the latest migration (runs its down section)
```

## Backups

`make backup-postgres` dumps both the homelab database and `keycloak` (the sign-in accounts). Restore one with `make restore-postgres FILE=backups/<file>.dump`, adding `DB=keycloak` for the accounts.
