-- Web-push subscriptions gain the DEVICE linkage (103). push_subscriptions (061) was keyed by
-- (user, endpoint) only, so revoking a device session could not find the browser's subscription —
-- a signed-out browser kept receiving pushes until its endpoint died (the recorded gap in
-- AuthService.Devices). The column is populated on subscribe (the gateway stamps the session's
-- device_id) and matched on revoke; pre-103 NULL rows are deliberately left to expire naturally via
-- push-failure pruning (they cannot be attributed to a device after the fact).
--
--   docker compose -f docker-compose.prod.yml exec -T postgres \
--     psql -U chat_user -d chat_platform -f - < .../103_push_subscription_device.sql
BEGIN;

ALTER TABLE push_subscriptions ADD COLUMN IF NOT EXISTS device_id text;

-- The revoke path deletes by (user_id, device_id); user_id alone is already covered by 061's index,
-- the pair keeps the delete indexed without scanning a user's other browsers.
CREATE INDEX IF NOT EXISTS push_subscriptions_user_device_idx
  ON push_subscriptions (user_id, device_id);

COMMIT;
