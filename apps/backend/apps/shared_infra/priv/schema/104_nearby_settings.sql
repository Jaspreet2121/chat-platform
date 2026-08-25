-- 104: Nearby v2 — per-user discoverability settings (BLE assist + audience). Plain columns, not
-- jsonb: the discover query must evaluate the TARGET's enabled/audience per candidate row, so the
-- hot path wants real booleans/text with real CHECKs, and an absent row IS the default state
-- (enabled=true — presence still only exists while actively sharing; ble_assist=false;
-- audience='everyone'). BLE tokens/proximity markers live in Redis with TTLs, never here.
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../104_nearby_settings.sql
BEGIN;

CREATE TABLE IF NOT EXISTS nearby_settings (
  user_id uuid PRIMARY KEY REFERENCES users_auth(id) ON DELETE CASCADE,
  app_id uuid NOT NULL REFERENCES apps(id),
  enabled boolean NOT NULL DEFAULT true,
  ble_assist boolean NOT NULL DEFAULT false,
  audience text NOT NULL DEFAULT 'everyone' CHECK (audience IN ('everyone', 'contacts')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMIT;
