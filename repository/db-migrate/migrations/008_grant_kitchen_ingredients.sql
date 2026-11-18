-- migrate:up
-- 006 made kitchen_atelier the schema's owner, but the table itself was created by whoever runs
-- the migration (the postgres superuser, via dbmate) — schema ownership doesn't retroactively
-- grant privileges on objects someone else created inside it. kitchen-atelier's own queries were
-- failing with "permission denied for table ingredients" because of this gap.
GRANT SELECT, INSERT, UPDATE, DELETE ON kitchen.ingredients TO kitchen_atelier;

-- So any future table created in this schema by a migration (always run as postgres) also
-- works for kitchen-atelier without another fix like this one.
ALTER DEFAULT PRIVILEGES IN SCHEMA kitchen
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kitchen_atelier;

-- migrate:down
ALTER DEFAULT PRIVILEGES IN SCHEMA kitchen
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM kitchen_atelier;
REVOKE SELECT, INSERT, UPDATE, DELETE ON kitchen.ingredients FROM kitchen_atelier;
