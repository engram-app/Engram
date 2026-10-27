-- One-time limit grant for the load-sim accounts (re-run is a no-op).
-- Run on the TARGET's Postgres after the first `sim.py --seed-only` pass has
-- created the users (they exist only once they have made an API call).
-- Same mechanism and sentinel as e2e/helpers/billing.py (-1 = unlimited).
--   whale (u00): notes_cap, so it can hold ~10k notes past Free's 2,000
--   all:         ai_searches_per_day (Free: 20/day), devices/connections (Free: 2)
INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by)
SELECT u.id, k.key, '{"v": -1}'::jsonb, 'load-sim', 'load-sim'
FROM users u
CROSS JOIN (VALUES ('ai_searches_per_day'), ('concurrent_devices'), ('obsidian_connections_cap'), ('notes_cap')) AS k(key)
WHERE u.email LIKE 'load-sim-u__+clerk_test@example.com'
  AND (k.key <> 'notes_cap' OR u.email = 'load-sim-u00+clerk_test@example.com')
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW();
