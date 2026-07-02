-- 057: App-level observability (self-contained; a future Grafana/Sentry sits ON TOP of this data).
--
-- Two tables, written best-effort from the gateway edge (fail-open — an observability write NEVER breaks
-- the actual request). Everything is keyed by app_id + carries the request's correlation_id, so a single
-- /v1 request is traceable across its structured log line and any error row.
--
--   observability_errors          — one row per error response / caught exception. "What broke for the
--                                    integrator, and when" — queryable after the fact.
--   observability_request_metrics — per (app_id, route, hour-bucket) request counter (ON CONFLICT +1),
--                                    so per-integrator usage scales to many apps without unbounded rows.
--
-- app_id/route/correlation_id are TEXT (not uuid) on purpose: this is a loose, fail-open telemetry store
-- — never risk a type/encode error breaking a write. A future infra dashboard consumes these as-is.
--
-- Idempotent + transactional (fresh initdb volume AND a running DB):
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
--     < infra/docker/postgres/init/057_observability.sql

BEGIN;

CREATE TABLE IF NOT EXISTS observability_errors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correlation_id text,
  app_id text,
  actor text,
  method text,
  route text,
  status integer,
  error_class text,
  message text,
  inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_obs_errors_app_time ON observability_errors (app_id, inserted_at DESC);
CREATE INDEX IF NOT EXISTS idx_obs_errors_correlation ON observability_errors (correlation_id);

CREATE TABLE IF NOT EXISTS observability_request_metrics (
  app_id text NOT NULL,
  route text NOT NULL,
  bucket timestamptz NOT NULL,
  count bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (app_id, route, bucket)
);

CREATE INDEX IF NOT EXISTS idx_obs_metrics_app_bucket ON observability_request_metrics (app_id, bucket DESC);

COMMIT;
