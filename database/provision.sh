#!/bin/sh
# Applies the secrets from .env to the database. Safe to re-run: it runs on every `make up`.
# Passwords never live in migrations: they are passed as psql variables and quoted by psql.
set -eu

psql -v ON_ERROR_STOP=1 \
  -v postgrest_password="$POSTGREST_PASSWORD" \
  -v keycloak_password="$KEYCLOAK_DB_PASSWORD" <<'SQL'
ALTER ROLE postgrest PASSWORD :'postgrest_password';

SELECT 'CREATE ROLE keycloak LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak') \gexec

ALTER ROLE keycloak
    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'keycloak_password';

SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak') \gexec

REVOKE ALL ON DATABASE keycloak FROM PUBLIC;
SQL
