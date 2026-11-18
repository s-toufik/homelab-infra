# PostgREST (issues)

A second, separate REST API generated from PostgreSQL's `issues` schema — kept apart from the `postgrest` release so a problem with one never touches the other. homelab-ui's Issues page uses it: anyone can submit a report, only admins can list or triage them.

- Reached only through the gateway: `https://<HOMELAB_DOMAIN>/api/issues/reports` (signed in)
- No published port. From pods: `http://postgrest-issues:3000`; settings in [`values.yaml.gotmpl`](values.yaml.gotmpl)

## How a request is checked

1. Caddy requires `app:issues` (or `admin`) to reach the route at all, removes any identity header the browser sent, and adds `Remote-User: <account>` and `X-Gateway-Secret`. Every method but `POST` additionally requires `admin` — regular accounts can only ever create a report.
2. Before every request PostgREST runs `issues.check_request()`: no or wrong gateway secret → **403**, no account → **401**. A pod that calls `postgrest-issues:3000` directly gets nothing.
3. PostgREST switches to `issues_web` (cannot log in, cannot bypass row security).
4. Row-level security lets anyone insert only a row whose `reporter` is their own account; reading and updating any row is allowed at the database level, since Caddy is what keeps that admin-only in practice — the same trust model as the Kafka UI and LLM routes (`@write`/`admin_only` gating in the Caddyfile, not row ownership).

| Role | Login | Can do |
|---|---|---|
| `postgrest` | yes, Secret `pg-role-postgrest` (shared with the `postgrest` release) | Nothing by itself; switches to `issues_web` for each request |
| `issues_web` | no | Insert its own reports; read and update any report (Caddy is the admin gate) |

The roles are declared in [`repository/postgres/`](../postgres/README.md); the schema, functions and policies come from the [migrations](../db-migrate/README.md). Deployed after `db-migrate`, alongside the `postgrest` release — they share the same `postgrest` Postgres login but each PostgREST pod serves only its own schema.

## Notes

- The OpenAPI description at `/` is turned off (`PGRST_OPENAPI_MODE=disabled`).
- A report's screenshot (if any) is a base64 data URL in `screenshot_data_url`, capped at ~2 MB by a `CHECK` constraint — this is a small personal-use inbox, not object storage; if that ever stops being enough, move screenshots to a real blob store instead of growing the column further.
- After changing tables by hand, reload PostgREST's schema cache: `make psql`, then `NOTIFY pgrst, 'reload schema';`.
