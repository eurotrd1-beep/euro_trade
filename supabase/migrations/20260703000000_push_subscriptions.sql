-- ══════════════════════════════════════════════════════
-- Web Push — subscriptions table + VAPID public-key config row
-- Run in Supabase → SQL Editor (or via `supabase db push`).
-- ══════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id           UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id      TEXT,                          -- account id (users.id); null = anonymous
  endpoint     TEXT        NOT NULL UNIQUE,    -- push endpoint (unique per device/browser)
  subscription JSONB       NOT NULL,           -- full PushSubscription (endpoint + keys)
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS push_subscriptions_user_id_idx
  ON push_subscriptions (user_id);

-- Keep updated_at fresh on upsert.
CREATE OR REPLACE FUNCTION set_push_subscriptions_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_push_subscriptions_updated_at ON push_subscriptions;
CREATE TRIGGER trg_push_subscriptions_updated_at
  BEFORE UPDATE ON push_subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_push_subscriptions_updated_at();

-- RLS: open, matching the rest of this project's tables. The client only needs
-- to upsert its own subscription; the Edge Function reads via the service role.
ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "allow all" ON push_subscriptions
  FOR ALL USING (true) WITH CHECK (true);

-- Public VAPID key the client reads to subscribe. Replace the value after you
-- generate your VAPID keys (see the setup notes).
INSERT INTO configs (id, data) VALUES
  ('push', '{"vapidPublicKey": ""}'::jsonb)
ON CONFLICT (id) DO NOTHING;
