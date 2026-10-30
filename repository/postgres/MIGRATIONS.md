# PostgreSQL migrations

Versioned SQL for the schemas the stack owns (today: `tasker`, served by [PostgREST](../postgrest/README.md)), applied by [dbmate](https://github.com/amacneil/dbmate).

```text
repository/postgres/
├── compose.yml        postgres, then the one-shots db-migrate and db-provision
├── migrations/
│   ├── 001_create_roles.sql              tasker_web (no login), postgrest (login, no superuser, no RLS bypass)
│   ├── 002_create_schema_and_tables.sql  tasker.workflows, tasker.block_favorites, owner column, JSON checks
│   ├── 003_create_auth_functions.sql     tasker.current_username(), tasker.check_request()
│   ├── 004_enable_rls.sql                row-level security, enforced, owner-only policies
│   └── 005_grant_permissions.sql         privileges; PUBLIC loses access to the schema and to public's CREATE
└── provision.sh       role passwords from .env, the keycloak database
```

## How it runs

On every `make up`: PostgreSQL healthy → **db-migrate** (`dbmate migrate`: only the migrations not applied yet, recorded in `public.schema_migrations`) → **db-provision** (sets the `postgrest` and `keycloak` role passwords from `.env`, creates the `keycloak` database once) → PostgREST and Keycloak start.

Passwords are never in a migration: `provision.sh` passes them to `psql` as variables, and PostgreSQL stores them as SCRAM-SHA-256 verifiers.

## Commands

| To… | make | Raw command |
|---|---|---|
| Create the next migration file | `make migration-new NAME=add_workflow_tags` | create `migrations/<next number>_add_workflow_tags.sql` with `-- migrate:up` and `-- migrate:down` |
| Apply pending migrations | `make migrate` | `docker compose run --rm db-migrate migrate` then `docker compose kill -s SIGUSR1 postgrest` |
| See applied and pending | `make migrate-status` | `docker compose run --rm db-migrate status` |
| Undo the latest | `make migrate-rollback` | `docker compose run --rm db-migrate rollback` |

Rules: never edit a migration that has run (add a new one); always write the `migrate:down`; end a migration that changes what PostgREST exposes with `NOTIFY pgrst, 'reload schema';`. `make validate` checks every file has both sections; `make verify` reports any migration still pending.

The step-by-step version, with a backup first, is in [`devops_guide.md`](../../devops_guide.md#database-migrations).
