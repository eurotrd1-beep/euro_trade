# Euro Trade — Edge Cache Worker

A transparent Cloudflare Worker that sits in front of the Render OTC proxy and
caches the two hot read endpoints, cutting Render's request load without touching
any app data.

- `/api/otc/candles` → cached **5s** (per `symbol`+`interval`)
- `/api/otc/status` → cached **10s**
- `/ws` (WebSocket) → **passthrough, never cached/touched**
- everything else → passthrough, uncached
- stale-while-revalidate: serves the last good copy for up to **60s** if the
  origin is slow/down (instead of an error)
- `X-Cache: HIT | MISS | STALE | ERROR` header on cacheable responses
- origin is `ORIGIN_URL` in `wrangler.toml` (not hardcoded)

Guaranteed-win is 100% client-side (chart.js). These endpoints carry only raw,
user-agnostic data, so caching can never leak one user's adjusted prices.

---

## 1) Deploy the Worker (first time — step by step)

```bash
# from this folder:  cloudflare-worker/

# a) install Wrangler (Cloudflare's CLI) — one-time, needs Node.js
npm install -g wrangler

# b) log in (opens a browser to authorize your Cloudflare account)
wrangler login

# c) deploy
wrangler deploy
```

`wrangler deploy` prints the live URL, e.g.:

```
https://euro-trade-cache.<your-subdomain>.workers.dev
```

Copy that URL — it's what the app will point at.

To redeploy after any change: `wrangler deploy` again.
To change the origin later: edit `ORIGIN_URL` in `wrangler.toml`, then redeploy.

---

## 2) Point the app at the Worker

The app reads its proxy base URL from Supabase — **no rebuild/redeploy needed**.

Change **one value**: `configs.proxy_server_url`

- **Easiest:** Admin panel → **سيرفر البيانات (Proxy)** card → paste the Worker URL
  → Save. All devices switch within seconds (realtime).
- **Or** directly in Supabase → Table `configs` → row `id = proxy_server_url` →
  set `data.url` = the Worker URL.

**Rollback (one value):** set `configs.proxy_server_url` back to
`https://euro-trade-proxy-1.onrender.com`. Instant, no redeploy.

---

## 3) Verify BEFORE leaving it for users

```bash
WORKER="https://euro-trade-cache.<your-subdomain>.workers.dev"

# HIT/MISS — 2nd call within 10s must be a HIT, identical body
curl -sD - "$WORKER/api/otc/status" -o /dev/null | grep -i x-cache   # MISS
curl -sD - "$WORKER/api/otc/status" -o /dev/null | grep -i x-cache   # HIT

# candles keyed by symbol+interval (separate entries)
curl -sD - "$WORKER/api/otc/candles?symbol=EURUSD_otc&interval=1m" -o /dev/null | grep -i x-cache

# CORS preflight
curl -sD - -X OPTIONS "$WORKER/api/otc/status" -o /dev/null | grep -i access-control
```

- **Cache:** header flips `MISS → HIT` on the 2nd call; wait >TTL → `MISS` again.
- **WebSocket (critical):** open the app pointed at the Worker → the chart's live
  price must move + a guaranteed-win trade must still win. In DevTools → Network →
  WS, the `wss://…workers.dev/ws` socket must connect (101) and stream ticks.
- **Origin load:** Render dashboard should show ~1 request per TTL per key,
  regardless of how many users are online.
- **stale:** temporarily pause the Render service → the Worker still returns data
  (`X-Cache: STALE`) for ~60s instead of erroring.

If anything looks wrong: roll back via step 2 — the app returns to the direct
proxy instantly.
