-- ══════════════════════════════════════════════════════
-- Euro Trade — Supabase Schema
-- Run this in Supabase → SQL Editor → Run
-- ══════════════════════════════════════════════════════

-- pairs
CREATE TABLE IF NOT EXISTS pairs (
  id          UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  symbol      TEXT    NOT NULL DEFAULT '',
  chart_symbol TEXT   NOT NULL DEFAULT '',
  category    TEXT    DEFAULT 'forex',
  type        TEXT    DEFAULT 'forex',
  "order"     BIGINT  DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- configs (key-value — replaces ALL configs/* Firestore docs)
CREATE TABLE IF NOT EXISTS configs (
  id    TEXT PRIMARY KEY,
  data  JSONB DEFAULT '{}'::jsonb
);

-- brokers
CREATE TABLE IF NOT EXISTS brokers (
  id                  UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  name                TEXT    DEFAULT '',
  logo_url            TEXT    DEFAULT '',
  chart_url           TEXT    DEFAULT '',
  registration_link   TEXT    DEFAULT '',
  desc                TEXT    DEFAULT '',
  click_key           TEXT    DEFAULT '',
  promo_code          TEXT    DEFAULT '',
  bonus_percent       INT     DEFAULT 0,
  min_deposit         INT     DEFAULT 0,
  is_active           BOOL    DEFAULT true,
  is_recommended      BOOL    DEFAULT false,
  "order"             INT     DEFAULT 1,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- users
CREATE TABLE IF NOT EXISTS users (
  id              TEXT    PRIMARY KEY,
  broker          TEXT    DEFAULT '',
  role            TEXT    DEFAULT 'user',
  is_banned       BOOL    DEFAULT false,
  ban_reason      TEXT    DEFAULT '',
  device_id       TEXT    DEFAULT '',
  fcm_token       TEXT    DEFAULT '',
  login_count     INT     DEFAULT 0,
  vip_expiry      TIMESTAMPTZ,
  guaranteed_win  BOOL    DEFAULT false,
  clicked_broker  TEXT    DEFAULT '',
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- clicks (analytics key-value)
CREATE TABLE IF NOT EXISTS clicks (
  id    TEXT  PRIMARY KEY,
  data  JSONB DEFAULT '{}'::jsonb
);

-- ── Default config rows ──────────────────────────────
INSERT INTO configs (id, data) VALUES
  ('chart_settings',   '{"mode":"sim"}'::jsonb),
  ('maintenance',      '{"isActive":false,"message":"","endsAt":null}'::jsonb),
  ('globalVip',        '{"enabled":false}'::jsonb),
  ('appUpdate',        '{"version":"","url":"","forceUpdate":false,"message":""}'::jsonb),
  ('theme',            '{"primaryColor":null,"secondaryColor":null}'::jsonb),
  ('social',           '{"telegram":"","whatsapp":"","youtube":""}'::jsonb),
  ('strategy_standard','{"rsiPeriod":14,"srLookback":50,"minScore":60,"confidenceMode":"conservative"}'::jsonb),
  ('strategy_vip',     '{"rsiPeriod":14,"srLookback":50,"minScore":60,"confidenceMode":"conservative"}'::jsonb),
  ('adminFcmToken',    '{"token":""}'::jsonb),
  ('fcm',              '{"clientEmail":"","privateKey":""}'::jsonb)
ON CONFLICT DO NOTHING;

-- ── Enable Realtime ──────────────────────────────────
ALTER PUBLICATION supabase_realtime ADD TABLE pairs;
ALTER PUBLICATION supabase_realtime ADD TABLE configs;
ALTER PUBLICATION supabase_realtime ADD TABLE users;
ALTER PUBLICATION supabase_realtime ADD TABLE brokers;

-- ── Row Level Security (open — matches current Firestore rules) ──
ALTER TABLE pairs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE configs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE brokers  ENABLE ROW LEVEL SECURITY;
ALTER TABLE users    ENABLE ROW LEVEL SECURITY;
ALTER TABLE clicks   ENABLE ROW LEVEL SECURITY;

CREATE POLICY "allow all" ON pairs    FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "allow all" ON configs  FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "allow all" ON brokers  FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "allow all" ON users    FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "allow all" ON clicks   FOR ALL USING (true) WITH CHECK (true);

-- ── Helper RPC: atomic increment for clicks ──────────
CREATE OR REPLACE FUNCTION increment_click(row_id TEXT, field_name TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clicks (id, data)
    VALUES (row_id, jsonb_build_object(field_name, 1))
  ON CONFLICT (id) DO UPDATE
    SET data = jsonb_set(
      clicks.data,
      ARRAY[field_name],
      to_jsonb(COALESCE((clicks.data->>field_name)::int, 0) + 1)
    );
END;
$$;

-- ══════════════════════════════════════════════════════
-- OTC scraping system (Pocket Option) — independent of the
-- TradingView scraper. Managed by proxy/po-scraper.js.
-- ══════════════════════════════════════════════════════

-- OTC pairs library — single source of truth for OTC pairs.
-- Discovered by the admin "جلب الأزواج" action; enabled per-pair by the admin.
CREATE TABLE IF NOT EXISTS otc_pairs (
  id            UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  name          TEXT    NOT NULL DEFAULT '',            -- "EUR/USD OTC"
  symbol        TEXT    NOT NULL,                        -- internal scraping symbol (NO ':')
  platform      TEXT    NOT NULL DEFAULT 'pocketoption', -- extensible to other OTC platforms
  subcategory   TEXT    DEFAULT 'forex',                -- forex | metals | commodities | crypto
  enabled       BOOLEAN DEFAULT FALSE,                  -- admin switch (off by default)
  "order"       BIGINT  DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (platform, symbol)
);

-- Control rows in configs:
--   otc_scan   — admin "جلب الأزواج" trigger + scraper status
--   otc_prices — latest per-second price per OTC symbol (for the live user chart)
--   otc_status — scraper connection/login/reconnect status
INSERT INTO configs (id, data) VALUES
  ('otc_scan',   '{"requestedAt":null,"status":"idle","count":0,"message":"","updatedAt":null}'::jsonb),
  ('otc_prices', '{}'::jsonb),
  ('otc_status', '{"connected":false,"loggedIn":false,"reconnects":0,"lastError":"","updatedAt":null}'::jsonb)
ON CONFLICT (id) DO NOTHING;

ALTER PUBLICATION supabase_realtime ADD TABLE otc_pairs;

ALTER TABLE otc_pairs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "allow all" ON otc_pairs FOR ALL USING (true) WITH CHECK (true);
