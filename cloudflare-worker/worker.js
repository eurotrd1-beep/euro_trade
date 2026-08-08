/**
 * Euro Trade — edge cache in front of the OTC proxy (Render).
 *
 * A TRANSPARENT reverse proxy. It caches only the two hot GET endpoints and
 * passes EVERYTHING else straight through untouched. It never reads or rewrites
 * any body content, so the app can't tell it's here — reads are just faster and
 * Render sees far fewer requests.
 *
 *   /api/otc/candles  → cache 5s   (keyed by symbol+interval from the query)
 *   /api/otc/status   → cache 10s  (single global key)
 *   /ws               → WebSocket passthrough — NEVER cached, NEVER touched
 *   everything else   → passthrough, uncached (pairs CRUD, /health, non-GET…)
 *
 * stale-while-revalidate: if the origin is slow/down, serve the last good copy
 * for up to STALE_TTL seconds instead of an error (raw data — safe).
 *
 * Guaranteed-win is 100% client-side (chart.js); these endpoints carry only raw,
 * user-agnostic data, so caching can never leak one user's adjusted prices.
 *
 * The origin is env.ORIGIN_URL (set in wrangler.toml) — never hardcoded here.
 */

const CACHE_TTL = {
  '/api/otc/candles': 5,   // seconds
  '/api/otc/status': 10,   // seconds
};
const STALE_TTL = 60;      // extra seconds a stale copy may be served if origin fails

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request, env, ctx) {
    const origin = (env.ORIGIN_URL || '').replace(/\/+$/, '');
    if (!origin) {
      return new Response('ORIGIN_URL not configured in wrangler.toml', {
        status: 500,
        headers: CORS,
      });
    }

    const url = new URL(request.url);
    const target = origin + url.pathname + url.search;

    // ── 1) WebSocket → fully transparent passthrough. NEVER cached or touched. ──
    // The live price + guaranteed-win entry ride this socket. Forward the exact
    // request; Cloudflare completes the 101 upgrade and returns it untouched.
    if ((request.headers.get('Upgrade') || '').toLowerCase() === 'websocket') {
      return fetch(target, request);
    }

    // ── 2) CORS preflight → answer at the edge (never cached). ──
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }

    // ── 3) Not one of the two cacheable GETs → passthrough, uncached. ──
    const ttl = request.method === 'GET' ? CACHE_TTL[url.pathname] : undefined;
    if (ttl === undefined) {
      const resp = await fetch(target, request);
      return corsStream(resp);
    }

    // ── 4) Cacheable GET (candles/status) → cache-first + stale-while-revalidate.
    // Cache key = full URL (path + query) → each symbol+interval is its own entry.
    const cache = caches.default;
    const key = new Request(url.toString(), { method: 'GET' });
    const now = Date.now();
    const hit = await cache.match(key);

    if (hit) {
      const age = now - Number(hit.headers.get('x-edge-ts') || 0);
      if (age < ttl * 1000) return serve(hit, 'HIT');                 // fresh
      if (age < (ttl + STALE_TTL) * 1000) {
        ctx.waitUntil(store(target, key, cache));                     // refresh in bg
        return serve(hit, 'STALE');                                   // serve stale now
      }
      // else: too stale → fall through to a fresh (blocking) fetch below.
    }

    // ── 5) MISS / too-stale → go to origin; cache 200s. ──
    try {
      const fresh = await store(target, key, cache);
      return serve(fresh, 'MISS');
    } catch (_) {
      if (hit) return serve(hit, 'STALE');   // origin failed but we have a copy
      return new Response(JSON.stringify({ error: 'origin unreachable' }), {
        status: 502,
        headers: { 'Content-Type': 'application/json', 'X-Cache': 'ERROR', ...CORS },
      });
    }
  },
};

// Fetch the origin fresh (plain GET — the data is user-agnostic), build a
// decompressed, timestamped, CORS'd copy, store it, and return it.
async function store(target, key, cache) {
  const resp = await fetch(target);
  if (resp.status !== 200) throw new Error('origin ' + resp.status);
  const body = await resp.arrayBuffer();     // Cloudflare auto-decompresses here
  const h = new Headers(resp.headers);
  h.delete('content-encoding');              // body is now decompressed
  h.delete('content-length');                // let the edge recompute
  h.set('x-edge-ts', String(Date.now()));
  h.set('Cache-Control', 'public, max-age=120'); // CF retains; freshness via x-edge-ts
  for (const k in CORS) h.set(k, CORS[k]);
  const out = new Response(body, { status: 200, headers: h });
  await cache.put(key, out.clone());
  return out;
}

// Return a cached/fresh Response tagged with X-Cache (CORS ensured).
function serve(resp, tag) {
  const h = new Headers(resp.headers);
  for (const k in CORS) h.set(k, CORS[k]);
  h.set('X-Cache', tag);
  return new Response(resp.body, { status: resp.status, headers: h });
}

// Passthrough: stream the original body/headers untouched, only adding CORS.
function corsStream(resp) {
  const h = new Headers(resp.headers);
  for (const k in CORS) h.set(k, CORS[k]);
  return new Response(resp.body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: h,
  });
}
