-- SPDX-License-Identifier: Apache-2.0
-- Bootstrap schemas and service roles for local Compose development.
-- Mirrors the Helm initdb SQL (charts/complytime/templates/postgres.yaml).
-- Keep these in sync — changes here should be reflected in the Helm chart.

CREATE SCHEMA IF NOT EXISTS workbench;

-- Gateway role: full access to public schema only
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gateway_rw') THEN
    CREATE ROLE gateway_rw LOGIN PASSWORD 'complytime-dev';
  ELSE
    ALTER ROLE gateway_rw PASSWORD 'complytime-dev';
  END IF;
END $$;
GRANT ALL ON SCHEMA public TO gateway_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO gateway_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON SEQUENCES TO gateway_rw;

-- Workbench role: full access to workbench schema, no access to public
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'workbench_rw') THEN
    CREATE ROLE workbench_rw LOGIN PASSWORD 'complytime-dev';
  ELSE
    ALTER ROLE workbench_rw PASSWORD 'complytime-dev';
  END IF;
END $$;
GRANT ALL ON SCHEMA workbench TO workbench_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA workbench
  GRANT ALL ON TABLES TO workbench_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA workbench
  GRANT ALL ON SEQUENCES TO workbench_rw;

-- Cross-schema isolation
REVOKE ALL ON SCHEMA workbench FROM gateway_rw;
REVOKE ALL ON SCHEMA public FROM workbench_rw;

-- Read-only role for external dashboard clients (Grafana, Metabase)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'studio_reader') THEN
    CREATE ROLE studio_reader LOGIN PASSWORD 'complytime-reader-dev';
  ELSE
    ALTER ROLE studio_reader PASSWORD 'complytime-reader-dev';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO studio_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO studio_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO studio_reader;
GRANT USAGE ON SCHEMA workbench TO studio_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA workbench TO studio_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA workbench GRANT SELECT ON TABLES TO studio_reader;
