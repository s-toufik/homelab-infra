-- migrate:up
-- The gateway (Caddy) is the only caller that knows app.settings.gateway_secret, and it sets
-- Remote-User from the signed-in session after removing any value the browser sent.
CREATE FUNCTION tasker.current_username() RETURNS text
    LANGUAGE sql STABLE
AS $$
    SELECT nullif(current_setting('request.headers', true)::json ->> 'remote-user', '')
$$;

CREATE FUNCTION tasker.check_request() RETURNS void
    LANGUAGE plpgsql STABLE
AS $$
DECLARE
    expected text := nullif(current_setting('app.settings.gateway_secret', true), '');
    headers  json := coalesce(nullif(current_setting('request.headers', true), '')::json, '{}'::json);
BEGIN
    IF expected IS NULL OR (headers ->> 'x-gateway-secret') IS DISTINCT FROM expected THEN
        RAISE SQLSTATE 'PT403' USING MESSAGE = 'Requests must come through the homelab gateway';
    END IF;

    IF tasker.current_username() IS NULL THEN
        RAISE SQLSTATE 'PT401' USING MESSAGE = 'Sign in to use Tasker';
    END IF;
END
$$;

ALTER TABLE tasker.workflows ALTER COLUMN owner SET DEFAULT tasker.current_username();
ALTER TABLE tasker.block_favorites ALTER COLUMN owner SET DEFAULT tasker.current_username();

-- migrate:down
ALTER TABLE tasker.block_favorites ALTER COLUMN owner DROP DEFAULT;
ALTER TABLE tasker.workflows ALTER COLUMN owner DROP DEFAULT;
DROP FUNCTION IF EXISTS tasker.check_request();
DROP FUNCTION IF EXISTS tasker.current_username();
