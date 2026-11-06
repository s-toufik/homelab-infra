-- migrate:up
CREATE SCHEMA IF NOT EXISTS tasker;

CREATE TABLE tasker.workflows (
    id          uuid        PRIMARY KEY,
    owner       text        NOT NULL,
    name        text        NOT NULL,
    blocks      jsonb       NOT NULL DEFAULT '[]'::jsonb,
    connections jsonb       NOT NULL DEFAULT '[]'::jsonb,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workflows_name_length_check CHECK (length(name) BETWEEN 1 AND 200),
    CONSTRAINT workflows_blocks_array_check CHECK (jsonb_typeof(blocks) = 'array'),
    CONSTRAINT workflows_connections_array_check CHECK (jsonb_typeof(connections) = 'array')
);

CREATE INDEX workflows_owner_updated_at_idx ON tasker.workflows (owner, updated_at DESC);

CREATE TABLE tasker.block_favorites (
    id         uuid        PRIMARY KEY,
    owner      text        NOT NULL,
    name       text        NOT NULL,
    config     jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT block_favorites_name_length_check CHECK (length(name) BETWEEN 1 AND 200),
    CONSTRAINT block_favorites_config_object_check CHECK (jsonb_typeof(config) = 'object')
);

CREATE INDEX block_favorites_owner_created_at_idx ON tasker.block_favorites (owner, created_at);

-- migrate:down
DROP TABLE IF EXISTS tasker.block_favorites;
DROP TABLE IF EXISTS tasker.workflows;
DROP SCHEMA IF EXISTS tasker;
