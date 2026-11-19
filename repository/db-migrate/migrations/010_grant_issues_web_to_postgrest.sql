-- migrate:up
-- 007 created issues_web and tried to grant it to postgrest in the same migration, but the grant
-- never took: PostgREST was failing every request on this schema with "permission denied to set
-- role \"issues_web\"" (Postgres 42501). Re-granting here, idempotently, regardless of the
-- original cause, the same way 008 re-granted kitchen_atelier's table privileges after 006.
GRANT issues_web TO postgrest;

-- migrate:down
REVOKE issues_web FROM postgrest;
