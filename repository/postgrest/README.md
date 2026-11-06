# PostgREST

A REST API generated from PostgreSQL's `tasker` schema. homelab-ui's Tasker keeps each account's workflows and favorite blocks through it.

- Reached only through the gateway: `https://<HOMELAB_DOMAIN>/api/tasker/workflows`, `/api/tasker/block_favorites` (signed in)
- No published port. From pods: `http://postgrest:3000`; settings in [`values.yaml.gotmpl`](values.yaml.gotmpl)

## How a request is checked

1. Caddy lets the request through only for a signed-in session, removes any identity header the browser sent, and adds `Remote-User: <account>` and `X-Gateway-Secret`.
2. Before every request PostgREST runs `tasker.check_request()`: no or wrong gateway secret → **403**, no account → **401**. So a pod that calls `postgrest:3000` directly gets nothing.
3. PostgREST switches to `tasker_web` (cannot log in, cannot bypass row security).
4. Row-level security keeps every row to its owner: you read, create, change and delete only rows where `owner` is your account, and new rows get your account automatically.

| Role | Login | Can do |
|---|---|---|
| `postgrest` | yes, Secret `pg-role-postgrest` | Nothing by itself; switches to `tasker_web` for each request |
| `tasker_web` | no | Read and write its own rows of the `tasker` tables, nothing else |

The roles are declared in [`repository/postgres/`](../postgres/README.md) (the PostgreSQL operator keeps them and their passwords); the schema, functions and policies come from the [migrations](../db-migrate/README.md). PostgREST is deployed after the `db-migrate` release.

## Notes

- The OpenAPI description at `/` is turned off (`PGRST_OPENAPI_MODE=disabled`).
- `make verify` checks the 403/401 answers and that one account cannot read or write another's rows.
- After changing tables by hand, reload PostgREST's schema cache: `make psql`, then `NOTIFY pgrst, 'reload schema';`.
