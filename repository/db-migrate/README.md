# db-migrate: PostgreSQL migrations

Versioned SQL for the schemas the homelab owns (today: `tasker`, served by [PostgREST](../postgrest/README.md)), applied by [dbmate](https://github.com/amacneil/dbmate). The database itself, its roles and passwords are [repository/postgres](../postgres/README.md).

```text
repository/db-migrate/
├── values.yaml.gotmpl          the db-migrate release: every file below, applied by a dbmate job
└── migrations/
    ├── 001_create_roles.sql              tasker_web (no login), postgrest (login, no superuser, no RLS bypass)
    ├── 002_create_schema_and_tables.sql  tasker.workflows, tasker.block_favorites, owner column, JSON checks
    ├── 003_create_auth_functions.sql     tasker.current_username(), tasker.check_request()
    ├── 004_enable_rls.sql                row-level security, enforced, owner-only policies
    └── 005_grant_permissions.sql         privileges; PUBLIC loses access to the schema and to public's CREATE
```

## How it runs

The `db-migrate` release holds the migration files in a ConfigMap and a job that runs `dbmate migrate` as the `postgres` superuser after every install and upgrade: only the migrations not applied yet, recorded in `public.schema_migrations`. A new or changed file changes the release, so `make apply` runs it; PostgREST is deployed after it.

Passwords are never in a migration: the PostgreSQL operator applies them to the roles from their Secrets.

## Commands

| To… | make | Raw command |
|---|---|---|
| Create the next migration file | `make migration-new NAME=add_workflow_tags` | create `migrations/<next number>_add_workflow_tags.sql` with `-- migrate:up` and `-- migrate:down` |
| Apply pending migrations | `make migrate` | `helmfile -l name=db-migrate sync`, then `NOTIFY pgrst, 'reload schema'` in psql |
| See applied and pending | `make migrate-status` | `./scripts/dbmate.sh status` |
| Undo the latest | `make migrate-rollback` | `./scripts/dbmate.sh rollback` |

Rules: never edit a migration that has run (add a new one); always write the `migrate:down`; end a migration that changes what PostgREST exposes with `NOTIFY pgrst, 'reload schema';`. `make validate` checks every file has both sections; `make verify` reports any migration still pending.

The step-by-step version is in [`devops_guide.md`](../../devops_guide.md#database-migrations).
