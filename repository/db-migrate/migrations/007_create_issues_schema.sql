-- migrate:up
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'issues_web') THEN
        CREATE ROLE issues_web NOLOGIN;
    END IF;
END
$$;

ALTER ROLE issues_web
    NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;

GRANT issues_web TO postgrest;

CREATE SCHEMA IF NOT EXISTS issues;

CREATE TABLE issues.reports (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter           text        NOT NULL,
    title              text        NOT NULL,
    description        text        NOT NULL,
    page_path          text        NOT NULL DEFAULT '',
    user_agent         text        NOT NULL DEFAULT '',
    screenshot_data_url text       ,
    status             text        NOT NULL DEFAULT 'open',
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT reports_title_length_check CHECK (length(title) BETWEEN 1 AND 200),
    CONSTRAINT reports_description_length_check CHECK (length(description) BETWEEN 1 AND 4000),
    CONSTRAINT reports_status_check CHECK (status IN ('open', 'fixed', 'wont_fix')),
    -- ~2 MB of binary data as a base64 data URL, generously rounded up
    CONSTRAINT reports_screenshot_length_check CHECK (
        screenshot_data_url IS NULL OR length(screenshot_data_url) <= 2800000
    )
);

CREATE INDEX reports_created_at_idx ON issues.reports (created_at DESC);

-- The gateway (Caddy) is the only caller that knows app.settings.gateway_secret, and it sets
-- Remote-User from the signed-in session after removing any value the browser sent.
CREATE FUNCTION issues.current_username() RETURNS text
    LANGUAGE sql STABLE
AS $$
    SELECT nullif(current_setting('request.headers', true)::json ->> 'remote-user', '')
$$;

CREATE FUNCTION issues.check_request() RETURNS void
    LANGUAGE plpgsql STABLE
AS $$
DECLARE
    expected text := nullif(current_setting('app.settings.gateway_secret', true), '');
    headers  json := coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json);
BEGIN
    IF expected IS NULL OR (headers ->> 'x-gateway-secret') IS DISTINCT FROM expected THEN
        RAISE SQLSTATE 'PT403' USING MESSAGE = 'Requests must come through the homelab gateway';
    END IF;

    IF issues.current_username() IS NULL THEN
        RAISE SQLSTATE 'PT401' USING MESSAGE = 'Sign in to report an issue';
    END IF;
END
$$;

ALTER TABLE issues.reports ALTER COLUMN reporter SET DEFAULT issues.current_username();

ALTER TABLE issues.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE issues.reports FORCE ROW LEVEL SECURITY;

-- Anyone who can reach this schema can only ever insert their own report; Caddy is what keeps
-- listing and triage (GET/PATCH) admin-only, the same trust model as the Kafka UI and LLM routes.
CREATE POLICY reports_insert_own ON issues.reports
    FOR INSERT
    TO issues_web
    WITH CHECK (reporter = issues.current_username());

CREATE POLICY reports_admin_select ON issues.reports
    FOR SELECT
    TO issues_web
    USING (true);

CREATE POLICY reports_admin_update ON issues.reports
    FOR UPDATE
    TO issues_web
    USING (true)
    WITH CHECK (true);

REVOKE ALL ON SCHEMA issues FROM PUBLIC;
GRANT USAGE ON SCHEMA issues TO issues_web;

GRANT SELECT, INSERT, UPDATE ON issues.reports TO issues_web;

REVOKE ALL ON FUNCTION issues.current_username(), issues.check_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issues.current_username(), issues.check_request() TO issues_web;

ALTER DEFAULT PRIVILEGES IN SCHEMA issues
    GRANT SELECT, INSERT, UPDATE ON TABLES TO issues_web;

NOTIFY pgrst, 'reload schema';

-- migrate:down
ALTER DEFAULT PRIVILEGES IN SCHEMA issues
    REVOKE SELECT, INSERT, UPDATE ON TABLES FROM issues_web;

REVOKE EXECUTE ON FUNCTION issues.current_username(), issues.check_request() FROM issues_web;
REVOKE SELECT, INSERT, UPDATE ON issues.reports FROM issues_web;
REVOKE USAGE ON SCHEMA issues FROM issues_web;

DROP POLICY IF EXISTS reports_admin_update ON issues.reports;
DROP POLICY IF EXISTS reports_admin_select ON issues.reports;
DROP POLICY IF EXISTS reports_insert_own ON issues.reports;
ALTER TABLE issues.reports NO FORCE ROW LEVEL SECURITY;
ALTER TABLE issues.reports DISABLE ROW LEVEL SECURITY;

ALTER TABLE issues.reports ALTER COLUMN reporter DROP DEFAULT;
DROP FUNCTION IF EXISTS issues.check_request();
DROP FUNCTION IF EXISTS issues.current_username();

DROP TABLE IF EXISTS issues.reports;
DROP SCHEMA IF EXISTS issues;

REVOKE issues_web FROM postgrest;
DROP ROLE IF EXISTS issues_web;
