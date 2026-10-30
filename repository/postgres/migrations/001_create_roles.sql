-- migrate:up
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tasker_web') THEN
        CREATE ROLE tasker_web NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgrest') THEN
        CREATE ROLE postgrest LOGIN NOINHERIT;
    END IF;
END
$$;

ALTER ROLE tasker_web
    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;

ALTER ROLE postgrest
    LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;

GRANT tasker_web TO postgrest;

-- migrate:down
REVOKE tasker_web FROM postgrest;
DROP ROLE IF EXISTS postgrest;
DROP ROLE IF EXISTS tasker_web;
