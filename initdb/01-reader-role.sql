-- SPDX-License-Identifier: Apache-2.0
-- Create read-only Postgres role for external dashboard clients.

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'studio_reader') THEN
    CREATE ROLE studio_reader LOGIN PASSWORD 'complytime-reader-dev';
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO studio_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO studio_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO studio_reader;
