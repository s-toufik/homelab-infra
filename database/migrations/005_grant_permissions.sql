-- migrate:up
REVOKE ALL ON SCHEMA tasker FROM PUBLIC;
GRANT USAGE ON SCHEMA tasker TO tasker_web;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON tasker.workflows, tasker.block_favorites
    TO tasker_web;

REVOKE ALL ON FUNCTION tasker.current_username(), tasker.check_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tasker.current_username(), tasker.check_request() TO tasker_web;

-- Applies to tables the migration user creates later in this schema.
ALTER DEFAULT PRIVILEGES IN SCHEMA tasker
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tasker_web;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

-- migrate:down
ALTER DEFAULT PRIVILEGES IN SCHEMA tasker
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM tasker_web;

REVOKE EXECUTE ON FUNCTION tasker.current_username(), tasker.check_request() FROM tasker_web;
REVOKE SELECT, INSERT, UPDATE, DELETE ON tasker.workflows, tasker.block_favorites FROM tasker_web;
REVOKE USAGE ON SCHEMA tasker FROM tasker_web;
