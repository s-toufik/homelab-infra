-- migrate:up
ALTER TABLE tasker.workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasker.workflows FORCE ROW LEVEL SECURITY;

CREATE POLICY workflows_owner_only ON tasker.workflows
    FOR ALL
    TO tasker_web
    USING (owner = tasker.current_username())
    WITH CHECK (owner = tasker.current_username());

ALTER TABLE tasker.block_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasker.block_favorites FORCE ROW LEVEL SECURITY;

CREATE POLICY block_favorites_owner_only ON tasker.block_favorites
    FOR ALL
    TO tasker_web
    USING (owner = tasker.current_username())
    WITH CHECK (owner = tasker.current_username());

-- migrate:down
DROP POLICY IF EXISTS block_favorites_owner_only ON tasker.block_favorites;
ALTER TABLE tasker.block_favorites NO FORCE ROW LEVEL SECURITY;
ALTER TABLE tasker.block_favorites DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS workflows_owner_only ON tasker.workflows;
ALTER TABLE tasker.workflows NO FORCE ROW LEVEL SECURITY;
ALTER TABLE tasker.workflows DISABLE ROW LEVEL SECURITY;
