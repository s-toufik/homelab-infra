-- migrate:up
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kitchen_atelier') THEN
        CREATE ROLE kitchen_atelier LOGIN;
    END IF;
END
$$;

ALTER ROLE kitchen_atelier
    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;

CREATE SCHEMA IF NOT EXISTS kitchen AUTHORIZATION kitchen_atelier;

CREATE TABLE kitchen.ingredients (
    ciqual_code      text             PRIMARY KEY,
    name_fr          text             NOT NULL,
    name_search      text             NOT NULL,
    kcal_per_100g    double precision NOT NULL DEFAULT 0 CHECK (kcal_per_100g >= 0),
    protein_per_100g double precision NOT NULL DEFAULT 0 CHECK (protein_per_100g >= 0),
    carb_per_100g    double precision NOT NULL DEFAULT 0 CHECK (carb_per_100g >= 0),
    fat_per_100g     double precision NOT NULL DEFAULT 0 CHECK (fat_per_100g >= 0),
    source           text             NOT NULL DEFAULT 'ciqual',
    updated_at       timestamptz      NOT NULL DEFAULT now(),
    CONSTRAINT ingredients_name_fr_length_check CHECK (length(name_fr) BETWEEN 1 AND 300)
);

CREATE INDEX ingredients_name_search_idx ON kitchen.ingredients (name_search);

-- migrate:down
DROP TABLE IF EXISTS kitchen.ingredients;
DROP SCHEMA IF EXISTS kitchen;
ALTER ROLE kitchen_atelier NOLOGIN;
DROP ROLE IF EXISTS kitchen_atelier;
