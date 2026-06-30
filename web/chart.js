'use strict';

window.CandleChart = (function () {

  /* ── Theme ───────────────────────────────────────────────────── */
  var BG      = '#0A0714';
  var BULL    = '#00FF7F';
  var BEAR    = '#FF2A6D';
  var GRID    = '#1A1535';
  var TEXT    = '#8B88A0';
  var CROSS   = '#00FFF0';
  var DASH    = '#F0C040';
  var BORDER  = '#2C2250';
  var RM = 80, TM = 20, BM = 28, LM = 4;

  /* ── Brand watermark: faint EURO TRADER logo behind the chart ──── */
  var LOGO = new Image();
  var LOGO_OK = false;
  LOGO.onload = function () { LOGO_OK = true; };
  try { LOGO.src = 'logo.jpg'; } catch (_) {}

  function drawWatermark(ctx, W, H) {
    if (!LOGO_OK || !LOGO.width) return;
    var lw = Math.min(W, H) * 0.55;
    var lh = lw * (LOGO.height / LOGO.width);
    ctx.save();
    ctx.globalAlpha = 0.05;            /* faint / semi-transparent */
    ctx.drawImage(LOGO, (W - lw) / 2, (H - lh) / 2, lw, lh);
    ctx.restore();
  }

  /* ── Proxy base URL ─────────────────────────────────────────── */
  var PROXY = 'https://euro-trade-proxy-1.onrender.com';

  /* ── Supabase (OTC data: candles table + configs/otc_prices) ──
     OTC pairs aren't on TradingView, so their candles/price are read straight
     from Supabase (written there by the independent OTC scraper). The anon key
     is already shipped in the compiled web app, so embedding it here is the same
     public exposure. */
  var SUPABASE_URL = 'https://dlzqdmqkvlvwnjhqxqym.supabase.co';
  var SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRsenFkbXFrdmx2d25qaHF4cXltIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2ODk3OTQsImV4cCI6MjA5ODI2NTc5NH0.Gchfry1V4vDnwSKk-uF9r7C10PfhXUkt2E4EpWGbdAg';

  /* ── Sliding window: max candles kept in memory ─────────────── */
  var MAX_CANDLES = 150;

  /* ── Asset profiles (realistic base prices + volatility) ────── */
  var ASSETS = {
    /* Forex */
    'EUR/USD':       { p: 1.08520, s: 0.00015, d: 5 },
    'GBP/USD':       { p: 1.27340, s: 0.00022, d: 5 },
    'USD/JPY':       { p: 149.500, s: 0.025,   d: 3 },
    'AUD/USD':       { p: 0.65800, s: 0.00012, d: 5 },
    'USD/CAD':       { p: 1.36500, s: 0.00015, d: 5 },
    'USD/CHF':       { p: 0.90500, s: 0.00012, d: 5 },
    'EUR/GBP':       { p: 0.85200, s: 0.00010, d: 5 },
    'EUR/JPY':       { p: 162.500, s: 0.028,   d: 3 },
    'GBP/JPY':       { p: 190.800, s: 0.035,   d: 3 },
    'NZD/USD':       { p: 0.61000, s: 0.00011, d: 5 },
    /* Metals */
    'XAU/USD':       { p: 2348.50, s: 0.38,    d: 2 },
    'XAG/USD':       { p: 28.4500, s: 0.009,   d: 3 },
    /* Commodities */
    'WTICO/USD':     { p: 78.500,  s: 0.015,   d: 2 },
    'BRENT/USD':     { p: 82.300,  s: 0.015,   d: 2 },
    'NATGAS/USD':    { p: 2.4500,  s: 0.0008,  d: 3 },
    /* Metals extended */
    'XAU/EUR':       { p: 2165.00, s: 0.35,    d: 2 },
    'XAG/EUR':       { p: 26.200,  s: 0.008,   d: 3 },
    'XPD/USD':       { p: 1000.00, s: 5.0,     d: 2 },
    'XPT/USD':       { p: 950.000, s: 4.0,     d: 2 },
    /* Forex extended */
    'EUR/CAD':       { p: 1.47500, s: 0.00018, d: 5 },
    'EUR/CHF':       { p: 0.97500, s: 0.00012, d: 5 },
    'EUR/AUD':       { p: 1.65000, s: 0.00022, d: 5 },
    'EUR/NZD':       { p: 1.78500, s: 0.00022, d: 5 },
    'EUR/RUB':       { p: 98.000,  s: 0.10,    d: 3 },
    'EUR/HUF':       { p: 390.00,  s: 0.10,    d: 2 },
    'EUR/TRY':       { p: 36.500,  s: 0.05,    d: 3 },
    'GBP/AUD':       { p: 1.93500, s: 0.00028, d: 5 },
    'GBP/CHF':       { p: 1.15000, s: 0.00018, d: 5 },
    'GBP/CAD':       { p: 1.72000, s: 0.00022, d: 5 },
    'AUD/CAD':       { p: 0.90500, s: 0.00013, d: 5 },
    'AUD/CHF':       { p: 0.59500, s: 0.00011, d: 5 },
    'AUD/JPY':       { p: 98.200,  s: 0.018,   d: 3 },
    'AUD/NZD':       { p: 1.07500, s: 0.00014, d: 5 },
    'CAD/JPY':       { p: 109.50,  s: 0.020,   d: 3 },
    'CAD/CHF':       { p: 0.66300, s: 0.00010, d: 5 },
    'CHF/JPY':       { p: 165.50,  s: 0.028,   d: 3 },
    'CHF/NOK':       { p: 11.500,  s: 0.005,   d: 3 },
    'NZD/JPY':       { p: 91.000,  s: 0.016,   d: 3 },
    'USD/SGD':       { p: 1.34000, s: 0.00013, d: 5 },
    'USD/PHP':       { p: 57.500,  s: 0.008,   d: 3 },
    'USD/RUB':       { p: 88.000,  s: 0.08,    d: 3 },
    'USD/INR':       { p: 83.500,  s: 0.008,   d: 3 },
    'USD/MXN':       { p: 17.200,  s: 0.003,   d: 3 },
    'USD/CNH':       { p: 7.23500, s: 0.00080, d: 5 },
    'USD/BRL':       { p: 4.9500,  s: 0.0008,  d: 4 },
    'USD/ZAR':       { p: 18.600,  s: 0.010,   d: 3 },
    /* Crypto */
    'BTCUSD':        { p: 65000,   s: 200,     d: 0 },
    'BTCGBP':        { p: 51000,   s: 180,     d: 0 },
    'BTCJPY':        { p: 9750000, s: 30000,   d: 0 },
    'ETHUSDT':       { p: 3500.0,  s: 15.0,    d: 2 },
    'ADAUSDT':       { p: 0.4500,  s: 0.003,   d: 4 },
    'DOGEUSDT':      { p: 0.1500,  s: 0.001,   d: 4 },
    'DOTUSDT':       { p: 7.5000,  s: 0.06,    d: 3 },
    'SOLUSDT':       { p: 170.00,  s: 1.5,     d: 2 },
    'AVAXUSDT':      { p: 35.000,  s: 0.30,    d: 2 },
    'TRXUSDT':       { p: 0.1200,  s: 0.0008,  d: 4 },
    'BNBUSDT':       { p: 580.00,  s: 3.0,     d: 2 },
    'LINKUSDT':      { p: 14.000,  s: 0.10,    d: 3 },
    'MATICUSDT':     { p: 0.8500,  s: 0.006,   d: 4 },
    'LTCUSDT':       { p: 85.000,  s: 0.50,    d: 2 },
    'TONUSDT':       { p: 6.0000,  s: 0.050,   d: 3 },
    'DASHUSDT':      { p: 32.000,  s: 0.20,    d: 2 },
    'BCHUSDT':       { p: 450.00,  s: 3.0,     d: 2 },
    'BCHEUR':        { p: 415.00,  s: 3.0,     d: 2 },
    'BCHGBP':        { p: 355.00,  s: 2.5,     d: 2 },
  };

  function asset(sym) {
    var k = sym.replace(/^[A-Z]+:/, '').replace(/_/g, '/');
    return ASSETS[k] || ASSETS['EUR/USD'];
  }

  /* ── Helpers ─────────────────────────────────────────────────── */
  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function candleSec(iv) {
    switch (iv) { case '5m': return 300; case '15m': return 900;
      case '1h': return 3600; case '1D': return 86400; default: return 60; }
  }

  function decimals(sym) { return asset(sym).d; }

  /* Auto-detect decimal places from actual price magnitude — never truncate */
  function autoDec(price) {
    var abs = Math.abs(price);
    if (!isFinite(abs) || abs === 0) return 5;
    if (abs >= 10000) return 0;   // BTC, indices
    if (abs >= 1000)  return 2;   // Gold, Palladium
    if (abs >= 100)   return 2;   // Oil, JPY crosses, EGP
    if (abs >= 10)    return 3;   // USD/JPY, CAD/JPY
    if (abs >= 1)     return 5;   // EUR/USD, GBP/USD, major forex
    return 6;                      // sub-dollar pairs
  }

  /* All candle-time formatting uses UTC (getUTC*) so timestamps are identical on
     every device regardless of the user's local timezone — candle frames are
     built on UTC epoch boundaries server-side, and these labels must match. */
  function fmtShort(t, iv) {
    var d = new Date(t * 1000);
    if (iv === '1D') return (d.getUTCMonth()+1)+'/'+pad2(d.getUTCDate());
    return pad2(d.getUTCHours())+':'+pad2(d.getUTCMinutes());
  }
  function fmtFull(t, iv) {
    var d = new Date(t * 1000);
    if (iv === '1D') return d.getUTCFullYear()+'-'+pad2(d.getUTCMonth()+1)+'-'+pad2(d.getUTCDate());
    return pad2(d.getUTCMonth()+1)+'/'+pad2(d.getUTCDate())+' '+pad2(d.getUTCHours())+':'+pad2(d.getUTCMinutes());
  }

  function showLabel(t, iv) {
    var d = new Date(t * 1000);
    switch(iv) {
      case '1m':  return d.getUTCMinutes() % 30 === 0;
      case '5m':  return d.getUTCMinutes() === 0;
      case '15m': return d.getUTCHours() % 4 === 0 && d.getUTCMinutes() === 0;
      case '1h':  return d.getUTCMinutes() === 0;
      case '1D':  return d.getUTCDay() === 1;
      default:    return d.getUTCMinutes() % 30 === 0;
    }
  }

  function niceTicks(lo, hi, n) {
    var r = hi - lo || 1;
    var raw = r / n;
    var mag = Math.pow(10, Math.floor(Math.log10(raw)));
    var step = Math.ceil(raw / mag) * mag;
    var first = Math.ceil(lo / step) * step;
    var ticks = [];
    for (var v = first; v <= hi + 1e-10; v = +(v + step).toFixed(10)) ticks.push(v);
    return ticks;
  }

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  /* ── Normal random number (Box-Muller) ───────────────────────── */
  function randn() {
    var u = 0, v = 0;
    while (!u) u = Math.random();
    while (!v) v = Math.random();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  }

  /* How many initial sim candles to show per interval (time-window ~1-2 hours) */
  function simCandleCount(iv) {
    switch(iv) {
      case '5m':  return 48;   // 4 hours
      case '15m': return 24;   // 6 hours
      case '1h':  return 24;   // 24 hours
      case '1D':  return 30;   // 30 days
      default:    return 60;   // 1m: 1 hour
    }
  }

  /* ── Generate realistic history ──────────────────────────────── */
  function buildHistory(sym, iv, count) {
    var a     = asset(sym);
    var cs    = candleSec(iv);
    count = count || MAX_CANDLES;
    var sigma = a.s * Math.sqrt(cs / 60);  // scale volatility by candle size
    var now   = Math.floor(Date.now() / 1000);
    var t0    = Math.floor(now / cs) * cs - count * cs;

    var price = a.p * (1 + (Math.random() - 0.5) * 0.004);
    var trend = 0;
    var candles = [];

    for (var i = 0; i < count; i++) {
      var open  = price;

      /* Occasional trend shifts */
      if (Math.random() < 0.04) trend = (Math.random() - 0.5) * sigma * 0.6;
      trend *= 0.95; // decay

      /* Candle body */
      var move  = trend + sigma * randn();
      var close = open + move;

      /* Gentle mean reversion keeps price near base */
      close += (a.p - close) * 0.003;

      /* Wicks */
      var hi = Math.max(open, close) + Math.abs(sigma * Math.random() * 0.8);
      var lo = Math.min(open, close) - Math.abs(sigma * Math.random() * 0.8);

      candles.push({ t: t0 + i * cs, o: open, h: hi, l: lo, c: close });
      price = close;
    }

    return candles;
  }

  function toTVSym(sym) {
    return sym.replace(/^[A-Z]+:/, '').replace(/_/g, '');
  }

  /* ── Candle integrity validator ──────────────────────────────── */
  /* A candle is only usable if it carries a numeric timestamp and finite
     OHLC values. Guards against half-written candles from a server that
     restarted mid-write, or malformed live ticks. */
  function validCandle(b) {
    return b && isFinite(b.t) && isFinite(b.o) && isFinite(b.h) && isFinite(b.l) && isFinite(b.c);
  }

  /* ── Guaranteed-win price bias ───────────────────────────────────
     Works as a persistent price OFFSET (self._gwinBias) that is eased in and
     out gradually — it never snaps, so the candle stream is always continuous
     (NO gap / empty space between candles, even at the moment the trade ends):
       • Each trade wins by a DIFFERENT amount (gwinTarget, per-trade) → no
         fixed-size tell.
       • A smooth guided path (smootherstep) runs from entry to that target
         across the WHOLE trade — calm start, calm finish — so candles stay
         small and there is never a big late jump.
       • We only ever lift a SHORTFALL behind the path; a genuine bigger real
         move is left to ride (offset eases back to 0), nothing looks clipped.
       • When the trade ends the offset eases back to 0 over the next few ticks,
         so the price drifts back to the real market smoothly — no snap, no gap.
       • Per-tick cap + micro-jitter keep every candle small and organic.
     `price` is the RAW market/sim price (no offset baked in); we return the
     shown price = raw + eased offset. gwinTarget/gwinTotal/gwinJit come from
     _setTradeState. */
  function gwinAdjust(self, price) {
    if (!isFinite(price)) return price;
    var t = self._trade;
    var bias = self._gwinBias || 0;
    var active = t && t.gwin && t.gwinTarget != null;
    if (!active && bias === 0) return price;            // fast path: nothing applied
    var desiredBias = 0;
    if (active) {
      var isCall = t.direction === 'CALL';
      var total  = t.gwinTotal || 1;
      var p = 1 - (t.secondsLeft / total);             // progress 0 → 1
      if (p < 0) p = 0; else if (p > 1) p = 1;
      var e = p * p * p * (p * (p * 6 - 15) + 10);      // smootherstep
      var center = t.entryPrice + (t.gwinTarget - t.entryPrice) * e;
      // Shown price should sit on the win path; if the real price is already
      // deeper in profit, ride it (offset → 0).
      var desiredShown = isCall ? Math.max(price, center) : Math.min(price, center);
      desiredBias = desiredShown - price;
    }
    var step = (desiredBias - bias) * 0.18;            // ease toward target offset
    if (active && desiredBias !== 0) step += (Math.random() - 0.5) * (t.gwinJit || 0);
    var cap = price * 0.00015;                          // ≤ ~1.5 pip per tick → no candle jumps
    if (step >  cap) step =  cap;
    else if (step < -cap) step = -cap;
    bias += step;
    if (Math.abs(bias) < price * 0.000002) bias = 0;    // fully release tiny residual
    self._gwinBias = bias;
    return price + bias;
  }

  /* ── Chart Instance ──────────────────────────────────────────── */
  function Chart(container, symbol, interval, mode) {
    this.container  = container;
    this.symbol     = symbol;
    this.interval   = interval;
    this.mode       = mode || 'sim';   // 'sim' | 'tv'
    this.candles    = [];
    this.scrollRight = 0;
    this.candleW    = 10;
    this.gap        = 2;
    this.mouse      = null;
    this.dragging   = false;
    this.dragX      = 0;
    this.dragScroll = 0;  /* unused — interaction disabled */
    this._tickTimer      = null;
    this._tvTimer        = null;
    this._simFallbackTimer = null;
    this._lastTVPrice    = 0;
    this._lastTVTickTime = 0;
    this._tvDistinctPrices = 0; /* count of distinct TV price changes received */
    this._resolvedSym    = null;
    this._destroyed      = false;
    this._ws             = null;
    this._wsTimer        = null;
    this._retryTimer     = null;  // tv-mode fetch retry timer
    this._otcHistTimer   = null;  // otc-mode: periodic candle history refresh
    this._otcPriceTimer  = null;  // otc-mode: per-second live price poll
    this._loadStartedAt  = 0;     // start of current tv load cycle (for status timing)
    this._sawEmptyResponse = false; // received >=1 valid JSON with empty candles
    this._marketClosedNote = false; // overlay 'market closed' note on next _draw
    this._trade          = null; // { direction, entryPrice, secondsLeft, gwin }
    this._gwinBias       = 0;    // current guaranteed-win price offset (eased in/out — never snaps)

    this.canvas = document.createElement('canvas');
    this.canvas.style.cssText = 'display:block;width:100%;height:100%;cursor:crosshair;';
    container.appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d');

    var self = this;
    this._mm  = function(e) { self._onMM(e); };
    this._ml  = function()  { self.mouse = null; self._draw(); };

    this.canvas.addEventListener('mousemove',  this._mm);
    this.canvas.addEventListener('mouseleave', this._ml);

    if (window.ResizeObserver) {
      this._ro = new ResizeObserver(function() { self._resize(); });
      this._ro.observe(container);
    }

    this._init();
  }

  Chart.prototype._init = function() {
    var self = this;
    if (this.mode === 'otc') {
      this._resize();          // loading screen until Supabase data arrives
      this._fetchOtcCandles();
      this._startOtcStream();
    } else if (this.mode === 'tv') {
      this._resize();          // draws loading screen (candles still empty)
      this._fetchTVCandles();
      /* NOTE: no sim-data fallback in tv mode — the status/error states drawn
         by _fetchTVCandles must own the canvas so the user always sees the
         real connection state instead of fake candles. */
    } else {
      this.candles = buildHistory(this.symbol, this.interval, simCandleCount(this.interval));
      this._resize();
      this._startTick();
    }
  };

  Chart.prototype._resize = function() {
    var r  = this.container.getBoundingClientRect();
    this.W = r.width  || 400;
    this.H = r.height || 300;
    this.dpr = window.devicePixelRatio || 1;
    this.canvas.width  = Math.round(this.W * this.dpr);
    this.canvas.height = Math.round(this.H * this.dpr);
    this.canvas.style.width  = this.W + 'px';
    this.canvas.style.height = this.H + 'px';
    this._draw();
  };

  /* ── TradingView data mode ───────────────────────────────────── */

  Chart.prototype._fetchTVCandles = function(retries, chain) {
    var self = this;
    var cs   = candleSec(this.interval);

    /* Mark the start of the current load cycle once (per symbol). Cleared in
       update() so a symbol/interval change restarts all the timing windows. */
    if (!this._loadStartedAt) this._loadStartedAt = Date.now();

    if (!chain) chain = [this.symbol];
    if (!chain.length) {
      /* Whole fallback chain exhausted with no candles — keep retrying. */
      self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, 15000);
      return;
    }

    var sym     = chain[0];
    var rest    = chain.slice(1);
    var attempt = (retries || 0) + 1;
    var url = PROXY + '/api/tv/candles?symbol=' + encodeURIComponent(toTVSym(sym)) + '&interval=' + this.interval;

    /* State 1 (pre-flight): browser reports offline → don't even try, just
       poll until connectivity returns. */
    if (navigator.onLine === false) {
      self._drawMessage('تحقق من اتصالك بالإنترنت', '#F0C040');
      self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, 3000);
      return;
    }

    var elapsed = function() { return Date.now() - self._loadStartedAt; };

    /* Shown when a request can't reach the server (network error / timeout /
       no usable response). Picks the right message for how long we've waited. */
    function showConnectFailure() {
      if (navigator.onLine === false) {
        /* State 1: connection dropped mid-flight. */
        self._drawMessage('تحقق من اتصالك بالإنترنت', '#F0C040');
      } else if (elapsed() < 55000) {
        /* State 2: Render free dyno cold start (up to ~50s). */
        self._drawMessage('جاري تجهيز السيرفر...', '#F0C040');
      } else {
        /* State 3: server still unreachable after the cold-start window. */
        self._drawMessage('السيرفر غير متاح حالياً', '#FF5555');
      }
    }

    /* Retry delay for connect/data failures: tight during the cold-start
       window so we recover fast, relaxed afterwards. */
    function failureDelay() {
      if (navigator.onLine === false) return 3000;
      return elapsed() < 55000 ? 3000 : 10000;
    }

    var xhr = new XMLHttpRequest();
    xhr.open('GET', url);
    /* Generous timeout so a waking dyno isn't mistaken for a dead server. */
    xhr.timeout = 30000;

    xhr.onloadend = function() {
      if (self._destroyed) return;

      var d = null;
      try { d = JSON.parse(xhr.responseText); } catch (_) { d = null; }

      /* State 4: server responded but body isn't valid JSON, or JSON without
         a candles array. Treat as a data error. */
      if (!d || !d.candles || Object.prototype.toString.call(d.candles) !== '[object Array]') {
        if (elapsed() >= 55000) {
          self._drawMessage('خطأ في تحميل البيانات', '#FF5555');
        } else {
          showConnectFailure();
        }
        self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, failureDelay());
        return;
      }

      /* Valid JSON with a candles array. Filter out incomplete candles. */
      var good = [];
      for (var ci = 0; ci < d.candles.length; ci++) {
        if (validCandle(d.candles[ci])) good.push(d.candles[ci]);
      }
      var marketOpen = (d.marketOpen === undefined) ? true : !!d.marketOpen;

      if (good.length) {
        // Got usable candles — cancel sim fallback and display immediately
        clearTimeout(self._simFallbackTimer);
        if (self._tickTimer) { clearInterval(self._tickTimer); self._tickTimer = null; }

        var all = good;
        self.candles      = all.length > MAX_CANDLES ? all.slice(all.length - MAX_CANDLES) : all;
        self._lastTVPrice = self.candles[self.candles.length - 1].c;
        self._resolvedSym = sym;
        self._marketClosedNote = !marketOpen;

        if (marketOpen) {
          self._marketClosedNote = false;
          // Bridge gap to current candle if needed
          var nowSec = Math.floor(Date.now() / 1000);
          var cT = Math.floor(nowSec / cs) * cs;
          var lc = self.candles[self.candles.length - 1];
          if (cT > lc.t) {
            self.candles.push({ t: cT, o: lc.c, h: lc.c, l: lc.c, c: lc.c });
            if (self.candles.length > MAX_CANDLES) self.candles.shift();
          }
          self._draw();          // _draw clears the closed note when marketOpen
          self._startTVTick();
        } else {
          /* State 6: market closed — draw candles, overlay note, keep polling.
             Stop any live WS tick so the badge logic stays clean; polling will
             resume normal drawing once marketOpen flips back to true. */
          if (self._tvTimer) { clearInterval(self._tvTimer); self._tvTimer = null; }
          self._draw();          // _draw paints the 'السوق مغلق حالياً' note
          self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, 15000);
        }
        return;
      }

      /* Reachable but EMPTY candles. Note the symbol is unavailable on this
         backend; try the fallback chain first, then settle on a message. */
      self._sawEmptyResponse = true;

      if (rest.length && attempt >= 3) {
        self._fetchTVCandles(0, rest); return;
      }

      /* State 5: server reachable + valid JSON but persistently empty. */
      if (elapsed() >= 30000) {
        self._drawMessage('الزوج غير متاح حالياً', '#FF5555');
        self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, 15000);
        return;
      }

      /* Still inside the early window — keep loading message and retry soon. */
      self._drawLoading();
      self._scheduleRetry(function() { self._fetchTVCandles(attempt, chain); }, 2000);
    };

    xhr.onerror = xhr.ontimeout = function() {
      if (self._destroyed) return;

      /* Network-level failure → States 1/2/3 depending on online + elapsed. */
      if (rest.length && attempt >= 3) {
        self._fetchTVCandles(0, rest); return;
      }
      showConnectFailure();
      self._scheduleRetry(function() { self._fetchTVCandles(0, [self.symbol]); }, failureDelay());
    };

    xhr.send();
  };

  /* Self-healing retry scheduler: always reschedules, never gives up, and is a
     no-op once the instance is destroyed. */
  Chart.prototype._scheduleRetry = function(fn, delay) {
    var self = this;
    if (this._destroyed) return;
    clearTimeout(this._retryTimer);
    this._retryTimer = setTimeout(function() {
      if (!self._destroyed) fn();
    }, delay);
  };

  Chart.prototype._startTVTick = function() {
    var self = this;
    // Close any existing WS
    if (this._ws) { try { this._ws.close(); } catch(_) {} this._ws = null; }
    clearTimeout(this._wsTimer); this._wsTimer = null;

    /* 1-second heartbeat: redraw only (keeps the live countdown badge ticking).
       A NEW candle is opened ONLY when a CHANGED price arrives (ws.onmessage),
       never as a flat candle on a timer — mirrors the server rule: a new candle
       requires BOTH the frame elapsing AND the price changing. So during a frozen
       price no flat candle is created; the new one opens when the price moves. */
    if (this._tvTimer) clearInterval(this._tvTimer);
    this._tvTimer = setInterval(function() {
      if (self._destroyed || !self.candles.length) return;
      self._draw();
    }, 1000);

    var wsUrl = PROXY.replace(/^http/, 'ws') + '/ws';

    function connect() {
      if (self._destroyed) return;
      var ws = new WebSocket(wsUrl);
      self._ws = ws;

      ws.onopen = function() {
        var live   = self._resolvedSym || self.symbol;
        ws.send(JSON.stringify({ sub: toTVSym(live) }));
      };

      ws.onmessage = function(e) {
        if (self._destroyed) { ws.close(); return; }
        try {
          var d     = JSON.parse(e.data);
          var price = d.price;
          if (!isFinite(price) || !price || !self.candles.length) return;

          // Guaranteed win — eased price offset (tv mode). `price` is the raw
          // market price; the offset eases in/out so candles never gap.
          price = gwinAdjust(self, price);

          if (price === self._lastTVPrice) return;
          self._tvDistinctPrices++;
          self._lastTVPrice = price;
          self._lastTVTickTime = Date.now();
          /* Price moved → market is live: drop the CLOSED badge / note instantly. */
          self._marketClosedNote = false;

          var last  = self.candles[self.candles.length - 1];
          var cs    = candleSec(self.interval);
          var now   = Math.floor(Date.now() / 1000);
          var cTime = Math.floor(now / cs) * cs;

          if (cTime === last.t) {
            if (price !== last.c) last.c = price;
            if (price >  last.h)  last.h = price;
            if (price <  last.l)  last.l = price;
          } else if (cTime > last.t) {
            var nc = { t: cTime, o: price, h: price, l: price, c: price };
            if (!validCandle(nc)) return;
            self.candles.push(nc);
            /* Sliding window: drop oldest candle when limit is exceeded */
            if (self.candles.length > MAX_CANDLES) self.candles.shift();
          }
          /* Always redraw on a fresh price so the CLOSED badge clears immediately. */
          self._draw();
        } catch(_) {}
      };

      ws.onclose = function() {
        self._ws = null;
        if (!self._destroyed) {
          self._wsTimer = setTimeout(connect, 3000);
        }
      };

      ws.onerror = function() {};
    }

    connect();
  };

  /* ── OTC data mode (Pocket Option via Supabase) ──────────────────
     OTC pairs aren't on TradingView. Their candles live in the Supabase
     `candles` table and their per-second price + scraper status live in
     configs/otc_prices + configs/otc_status (written by the OTC scraper).
     Each chart instance polls Supabase independently over plain REST — so
     multiple open tabs never conflict (no shared/limited socket). All candle
     timing is UTC-epoch based, identical on every device. */

  /* OTC symbol = PO's exact asset symbol (e.g. "EURUSD_otc", "#AAPL_otc").
     Do NOT upper-case — PO uses lowercase "_otc", and candle keys must match
     exactly what the scraper wrote. Only strip an exchange prefix if present. */
  function toOtcSym(sym) { return String(sym).replace(/^[A-Z]+:/, ''); }

  /* One specific message per real cause — never a generic "error". */
  var OTC_MSG = {
    offline:        ['🌐 تحقق من اتصالك بالإنترنت', '#F0C040'],
    reconnecting:   ['🔄 جاري إعادة الاتصال...', '#F0C040'],
    server:         ['⚠️ تعذر الاتصال بالسيرفر، جاري المحاولة...', '#F0C040'],
    relogin:        ['🔄 جاري إعادة تسجيل الدخول للمنصة...', '#F0C040'],
    login_failed:   ['⚠️ تعذر الاتصال بمنصة البيانات، يتم إبلاغ الدعم الفني', '#FF6B6B'],
    ip_blocked:     ['⚠️ تعذر الوصول لمصدر البيانات حاليًا', '#FF6B6B'],
    resolving:      ['🔧 جاري إصلاح الاتصال بمصدر البيانات...', '#F0C040'],
    repairing:      ['🔄 جاري إعادة الاتصال بمصدر البيانات...', '#F0C040'],
    repairing_long: ['⏳ النظام بيستعيد الاتصال، استنى لحظات', '#F0C040'],
    circuit:        ['⏳ النظام بيستريح شوية، هيرجع تلقائي خلال دقايق', '#F0C040'],
    supabase:       ['📡 مشكلة مؤقتة في تحميل البيانات، جاري المحاولة', '#F0C040'],
    warming:        ['📊 جاري تجهيز البيانات لأول مرة، يستغرق دقيقة', '#5AC8FA'],
    unavailable:    ['هذا الزوج غير متاح حاليًا', '#9CA3AF'],
  };

  /* Transient states keep the last candles visible with a calm banner overlay
     (the chart isn't "broken" — something is working quietly in the background).
     Hard/no-data states take over the whole canvas. */
  var OTC_OVERLAY_KINDS = { repairing: 1, repairing_long: 1, reconnecting: 1, relogin: 1, resolving: 1 };

  Chart.prototype._sbHeaders = function() {
    return { apikey: SUPABASE_ANON, Authorization: 'Bearer ' + SUPABASE_ANON };
  };

  Chart.prototype._otcMsg = function(kind) {
    this._otcProblem = kind;
    var m = OTC_MSG[kind] || OTC_MSG.unavailable;
    if (OTC_OVERLAY_KINDS[kind] && this.candles && this.candles.length) {
      this._otcOverlay = { text: m[0], color: m[1] };   // candles stay + banner
      this._draw();
    } else {
      this._otcOverlay = null;
      this._drawMessage(m[0], m[1]);                     // full takeover (no usable data)
    }
  };

  /* Candle history from the Supabase `candles` table (key = SYMBOL_interval). */
  Chart.prototype._fetchOtcCandles = function() {
    var self = this;
    function load() {
      if (self._destroyed) return;
      var key = toOtcSym(self.symbol) + '_' + self.interval;
      var url = SUPABASE_URL + '/rest/v1/candles?key=eq.' +
                encodeURIComponent(key) + '&select=data';
      fetch(url, { headers: self._sbHeaders() })
        .then(function(r) { if (!r.ok) throw 0; return r.json(); })
        .then(function(rows) {
          if (self._destroyed) return;
          var arr = (rows && rows[0] && rows[0].data) || [];
          if (!Array.isArray(arr) || !arr.length) return;
          /* Adopt stored history only when it's at/ahead of our local forming
             candle, so periodic refreshes never wipe the live candle. */
          var lastLocal = self.candles.length ? self.candles[self.candles.length - 1].t : 0;
          var lastStored = arr[arr.length - 1].t;
          if (lastStored >= lastLocal) {
            self.candles = arr.slice(-MAX_CANDLES);
            if (!self._otcProblem) self._draw();
          }
        })
        .catch(function() { /* surfaced by the status poll (supabase down) */ });
    }
    load();
    this._otcHistTimer = setInterval(load, 15000);
  };

  /* Per-second status + price poll → resolves the exact state, then either shows
     the right message or feeds the live price into the candles. */
  Chart.prototype._startOtcStream = function() {
    var self = this;
    function poll() {
      if (self._destroyed) return;
      /* STATE 17 — the user's own device is offline. */
      if (navigator.onLine === false) { self._otcMsg('offline'); return; }
      var url = SUPABASE_URL +
        '/rest/v1/configs?id=in.(otc_status,otc_prices)&select=id,data';
      fetch(url, { headers: self._sbHeaders() })
        .then(function(r) { if (!r.ok) throw 0; return r.json(); })
        .then(function(rows) {
          if (self._destroyed) return;
          var status = {}, prices = {};
          (rows || []).forEach(function(row) {
            if (row.id === 'otc_status') status = row.data || {};
            else if (row.id === 'otc_prices') prices = row.data || {};
          });
          self._onOtcData(status, prices);
        })
        /* STATE 6 — Supabase itself isn't responding. */
        .catch(function() { if (!self._destroyed) self._otcMsg('supabase'); });
    }
    poll();
    this._otcPriceTimer = setInterval(poll, 1000);
  };

  Chart.prototype._onOtcData = function(status, prices) {
    var sym   = toOtcSym(this.symbol);
    var now   = Date.now();
    var hbAge = status.updatedAt ? (now - Date.parse(status.updatedAt)) : Infinity;
    var entry = prices ? prices[sym] : null;

    /* ── Macro (whole scraper / server) states ── */
    /* STATE 8 — auto-repair gave up / token truly dead → manual re-capture. */
    if (status.phase === 'login_failed') { this._otcMsg('login_failed'); return; }
    /* STATE 12 — Pocket Option blocked the server IP. */
    if (status.phase === 'ip_blocked')   { this._otcMsg('ip_blocked');   return; }
    /* SELF-REPAIR — token died, system is re-capturing it automatically. Keep
       last candles + calm banner; escalate the wording if it runs over a minute. */
    if (status.phase === 'repairing') {
      var since = status.phaseSince ? (now - Date.parse(status.phaseSince)) : 0;
      this._otcMsg(since > 60000 ? 'repairing_long' : 'repairing');
      return;
    }
    /* STATE 2 & 14 — scraper not heartbeating for long → server down / maintenance. */
    if (hbAge > 150000) { this._otcMsg('server'); return; }
    /* STATE 10 & 13 — short heartbeat gap → new deploy / restart / VPN hiccup. */
    if (hbAge > 45000)  { this._otcMsg('reconnecting'); return; }
    /* STATE 4 — re-establishing the Pocket Option session. */
    if (status.phase === 'relogin' || status.phase === 'reconnecting' ||
        status.connected === false) { this._otcMsg('relogin'); return; }

    /* ── Per-pair states ── */
    if (!entry) {
      /* Enabled pair with no price yet: warming if we already have some candles,
         otherwise genuinely unavailable on the platform (STATE 7 / 16). */
      if (this.candles.length) this._otcMsg('warming');
      else this._otcMsg('unavailable');
      return;
    }
    /* STATE 5 — circuit breaker open for this pair. */
    if (entry.st === 'circuit')   { this._otcMsg('circuit');   return; }
    /* STATE 3 — server up but the scraper can't read this pair's price. */
    if (entry.st === 'resolving') { this._otcMsg('resolving'); return; }
    /* STATE 16 — first-time: price flowing but not enough candles yet. */
    if (this.candles.length < 3) { this._feedOtcPrice(entry.p, true); this._otcMsg('warming'); return; }

    /* Live (STATE 1 market-closed is surfaced by the Flutter dialog, candles
       just stay frozen) → feed the real price into the candle series. */
    this._otcProblem = null;
    this._otcOverlay = null;     // clear any repair/reconnect banner
    this._feedOtcPrice(entry.p);
  };

  /* Feed one real OTC price into the candle series — same rule as the server:
     a new candle opens only when the frame elapsed AND the price changed. */
  Chart.prototype._feedOtcPrice = function(price, noDraw) {
    if (!isFinite(price) || !price) return;
    price = gwinAdjust(this, price);
    var cs    = candleSec(this.interval);
    var now   = Math.floor(Date.now() / 1000);   // UTC epoch
    var cTime = Math.floor(now / cs) * cs;
    if (!this.candles.length) {
      this.candles.push({ t: cTime, o: price, h: price, l: price, c: price });
      if (!noDraw) this._draw();
      return;
    }
    var last = this.candles[this.candles.length - 1];
    if (cTime === last.t) {
      if (price !== last.c) last.c = price;
      if (price >  last.h)  last.h = price;
      if (price <  last.l)  last.l = price;
    } else if (cTime > last.t && price !== last.c) {
      var nc = { t: cTime, o: price, h: price, l: price, c: price };
      if (!validCandle(nc)) return;
      this.candles.push(nc);
      if (this.candles.length > MAX_CANDLES) this.candles.shift();
    } else { return; }
    this._lastTVPrice = price;
    if (!noDraw) this._draw();
  };

  /* ── Live tick simulation ────────────────────────────────────── */
  Chart.prototype._startTick = function() {
    var self = this;
    if (this._tickTimer) clearInterval(this._tickTimer);

    var a  = asset(this.symbol);
    var cs = candleSec(this.interval);
    /* Tick sigma = 1/8 of candle sigma so each tick is a small move */
    var tickSigma = a.s * Math.sqrt(cs / 60) / 8;

    this._tickTimer = setInterval(function() {
      if (self._destroyed || !self.candles.length) return;

      var last  = self.candles[self.candles.length - 1];
      var nowSec = Math.floor(Date.now() / 1000);
      var cT     = Math.floor(nowSec / cs) * cs;

      if (cT > last.t) {
        /* New candle — drop oldest if window is full */
        var open = last.c;
        self.candles.push({ t: cT, o: open, h: open, l: open, c: open });
        if (self.candles.length > MAX_CANDLES) self.candles.shift();
        last = self.candles[self.candles.length - 1];
      }

      /* Price tick — walk the RAW (offset-free) price, then re-apply the eased
         guaranteed-win offset on top so it is never double-counted and candles
         stay continuous. */
      var raw   = last.c - (self._gwinBias || 0);
      var move  = tickSigma * randn();
      /* Gentle pull toward base price */
      move += (a.p - raw) * 0.0008;
      raw = raw + move;

      var price = gwinAdjust(self, raw);

      last.c = price;
      if (price > last.h) last.h = price;
      if (price < last.l) last.l = price;

      self._draw();
    }, 500); // new tick every 500 ms
  };

  /* ── Loading screen (TV mode waiting for data) ───────────────── */
  Chart.prototype._drawLoading = function() {
    var ctx = this.ctx;
    var W = this.W || 400, H = this.H || 300, dpr = this.dpr || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = BG;
    ctx.fillRect(0, 0, W, H);
    drawWatermark(ctx, W, H);
    ctx.fillStyle = TEXT;
    ctx.font = '13px Outfit,sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('جاري الاتصال بالسوق...', W / 2, H / 2 - 10);
    ctx.font = '11px Outfit,sans-serif';
    ctx.fillStyle = GRID;
    var displaySym = this.symbol.replace(/^[A-Z]+:/, '').replace(/_/g, '/');
    ctx.fillText(displaySym, W / 2, H / 2 + 14);
  };

  /* ── Generic on-canvas message (status / error states) ───────── */
  /* Clears the canvas and draws `text` centered (word-wrapped if long) in
     `color` (default light gray). Used for all TV-mode status states. */
  Chart.prototype._drawMessage = function(text, color) {
    var ctx = this.ctx;
    var W = this.W || 400, H = this.H || 300, dpr = this.dpr || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = BG;
    ctx.fillRect(0, 0, W, H);
    drawWatermark(ctx, W, H);

    ctx.fillStyle = color || TEXT;
    ctx.font = '13px Outfit,sans-serif';
    ctx.textAlign = 'center';

    /* Word-wrap to fit width (with a small horizontal margin) */
    var maxW  = Math.max(40, W - 24);
    var words = ('' + text).split(' ');
    var lines = [];
    var line  = '';
    for (var i = 0; i < words.length; i++) {
      var test = line ? line + ' ' + words[i] : words[i];
      if (ctx.measureText(test).width > maxW && line) {
        lines.push(line); line = words[i];
      } else {
        line = test;
      }
    }
    if (line) lines.push(line);

    var lh = 18;
    var startY = H / 2 - ((lines.length - 1) * lh) / 2;
    for (var li = 0; li < lines.length; li++) {
      ctx.fillText(lines[li], W / 2, startY + li * lh);
    }

    /* Symbol caption underneath, like the loading screen */
    ctx.font = '11px Outfit,sans-serif';
    ctx.fillStyle = GRID;
    var displaySym = this.symbol.replace(/^[A-Z]+:/, '').replace(/_/g, '/');
    ctx.fillText(displaySym, W / 2, startY + lines.length * lh + 8);
  };

  /* ── Draw ────────────────────────────────────────────────────── */
  Chart.prototype._draw = function() {
    var ctx = this.ctx;
    var W = this.W, H = this.H, dpr = this.dpr || 1;

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = BG;
    ctx.fillRect(0, 0, W, H);
    drawWatermark(ctx, W, H);   /* faint brand logo behind everything */

    if (!this.candles.length) { this._drawLoading(); return; }

    var cl = LM, cr = W - RM, ct = TM, cb = H - BM;
    var cw = cr - cl, ch = cb - ct;
    var step = this.candleW + this.gap;

    /* Visible candles */
    var maxVis  = Math.max(1, Math.floor(cw / step));
    var total   = this.candles.length;
    var endIdx  = total - clamp(this.scrollRight, 0, total - 1);
    var startIdx = Math.max(0, endIdx - maxVis);
    var vis = this.candles.slice(startIdx, endIdx);
    if (!vis.length) return;

    /* Y range */
    var lo = Infinity, hi = -Infinity;
    for (var i = 0; i < vis.length; i++) {
      if (vis[i].l < lo) lo = vis[i].l;
      if (vis[i].h > hi) hi = vis[i].h;
    }
    var pad = (hi - lo) * 0.08 || 0.001;
    lo -= pad; hi += pad;

    function py(p) { return cb - ((p - lo) / (hi - lo)) * ch; }
    function cx(i) { return cl + i * step + Math.floor(step / 2); }

    this._vis = vis; this._startIdx = startIdx;
    this._py = py; this._cx = cx;
    this._cl = cl; this._cr = cr; this._ct = ct; this._cb = cb;
    this._lo = lo; this._hi = hi; this._ch = ch; this._step = step;

    var last = this.candles[this.candles.length - 1];
    var dec = last ? autoDec(last.c) : decimals(this.symbol);

    /* Candle countdown timer — pure wall-clock, same formula as signal_engine.dart:
       secsLeft = cs - (nowSec % cs)   → matches Flutter exactly */
    var cs2 = candleSec(this.interval);
    var nowSec2 = Math.floor(Date.now() / 1000);
    var secsLeft = cs2 - (nowSec2 % cs2);
    var minsLeft = Math.floor(secsLeft / 60);
    var secsPart = secsLeft % 60;
    var countdownStr = minsLeft > 0
      ? minsLeft + ':' + (secsPart < 10 ? '0' : '') + secsPart
      : secsPart + 's';

    /* Grid + Y labels */
    ctx.font = '11px Outfit,sans-serif';
    var ticks = niceTicks(lo, hi, 5);
    for (var ti = 0; ti < ticks.length; ti++) {
      var tv = ticks[ti];
      if (tv < lo || tv > hi) continue;
      var gy = py(tv);
      ctx.strokeStyle = GRID; ctx.lineWidth = 1; ctx.setLineDash([3,4]);
      ctx.beginPath(); ctx.moveTo(cl, gy); ctx.lineTo(cr, gy); ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = TEXT; ctx.textAlign = 'right';
      ctx.fillText(tv.toFixed(dec), W - 4, gy + 4);
    }
    /* Y axis border */
    ctx.strokeStyle = BORDER; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(cr, ct); ctx.lineTo(cr, H); ctx.stroke();

    /* X axis */
    ctx.strokeStyle = BORDER;
    ctx.beginPath(); ctx.moveTo(cl, cb); ctx.lineTo(cr, cb); ctx.stroke();
    ctx.fillStyle = TEXT; ctx.textAlign = 'center';
    var lastCX = vis.length > 0 ? cx(vis.length - 1) : -999;
    for (var li = 0; li < vis.length; li++) {
      if (showLabel(vis[li].t, this.interval)) {
        var lx = cx(li);
        // Skip label if it overlaps the countdown badge slot at the last candle
        if (secsLeft > 0 && Math.abs(lx - lastCX) < 28) continue;
        ctx.fillText(fmtShort(vis[li].t, this.interval), lx, cb + 18);
      }
    }

    /* ── Candle countdown badge on X axis (below last candle) ── */
    /* noTickYet: TV mode and fewer than 2 distinct price changes received yet → don't show countdown */
    var noTickYet    = false;
    var marketClosed = this.mode === 'tv' && this._tvDistinctPrices >= 1 &&
                       (Date.now() - this._lastTVTickTime) > 10000;
    if (!noTickYet && last && lastCX >= cl && lastCX <= cr && (secsLeft > 0 || marketClosed)) {
      var badgeLabel = marketClosed ? 'CLOSED' : countdownStr;
      var bW = marketClosed ? 58 : 46, bH = 18, bX = lastCX - bW / 2, bY = cb + 4;
      ctx.fillStyle = marketClosed ? 'rgba(255,60,60,0.15)' : 'rgba(0,255,240,0.15)';
      ctx.fillRect(bX, bY, bW, bH);
      ctx.strokeStyle = marketClosed ? 'rgba(255,60,60,0.5)' : 'rgba(0,255,240,0.45)';
      ctx.lineWidth = 1; ctx.setLineDash([]);
      ctx.strokeRect(bX, bY, bW, bH);
      ctx.fillStyle = marketClosed ? 'rgba(255,100,100,0.9)' : CROSS;
      ctx.font = 'bold 10px Outfit,monospace'; ctx.textAlign = 'center';
      ctx.fillText(badgeLabel, lastCX, bY + 13);
    }

    /* Candles */
    var halfW = Math.max(1, Math.floor(this.candleW / 2));
    for (var ci = 0; ci < vis.length; ci++) {
      var c     = vis[ci];
      var x     = cx(ci);
      var color = c.c >= c.o ? BULL : BEAR;
      ctx.strokeStyle = color; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x, py(c.h)); ctx.lineTo(x, py(c.l)); ctx.stroke();
      ctx.fillStyle = color;
      ctx.fillRect(x - halfW, py(Math.max(c.o,c.c)), this.candleW,
                   Math.max(1, py(Math.min(c.o,c.c)) - py(Math.max(c.o,c.c))));
    }

    /* Current price line */
    if (last) {
      var lpy = py(last.c);
      if (lpy >= ct && lpy <= cb) {
        ctx.strokeStyle = DASH; ctx.lineWidth = 1; ctx.setLineDash([4,4]);
        ctx.beginPath(); ctx.moveTo(cl, lpy); ctx.lineTo(cr, lpy); ctx.stroke();
        ctx.setLineDash([]);
        ctx.fillStyle = DASH;
        ctx.fillRect(cr, lpy - 10, RM, 20);
        ctx.fillStyle = BG; ctx.textAlign = 'center'; ctx.font = '11px Outfit,sans-serif';
        ctx.fillText(last.c.toFixed(dec), cr + RM / 2, lpy + 4);
        /* Countdown timer badge above price tag — hidden when no tick yet or market closed */
        if (!noTickYet && !marketClosed && secsLeft > 0 && secsLeft <= cs2) {
          ctx.fillStyle = 'rgba(30,20,60,0.85)';
          ctx.fillRect(cr, lpy - 28, RM, 16);
          ctx.fillStyle = CROSS; ctx.font = 'bold 10px Outfit,monospace';
          ctx.fillText(countdownStr, cr + RM / 2, lpy - 17);
        }
      }
    }

    /* Entry line */
    this._drawEntryLine(py, cl, cr, ct, cb, dec, last ? last.c : null);

    /* State 6: market-closed note near the top (candles stay visible). */
    if (this._marketClosedNote) {
      ctx.fillStyle = '#F0C040';
      ctx.font = 'bold 12px Outfit,sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('السوق مغلق حالياً', (cl + cr) / 2, ct + 14);
    }

    /* OTC transient overlay (self-repair / reconnecting): keep the last candles
       visible and show a calm translucent banner on top — not a full takeover. */
    if (this._otcOverlay) {
      ctx.fillStyle = 'rgba(10,7,20,0.74)';
      ctx.fillRect(cl, ct, cr - cl, 30);
      ctx.fillStyle = this._otcOverlay.color || '#F0C040';
      ctx.font = 'bold 12px Outfit,sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText(this._otcOverlay.text, (cl + cr) / 2, ct + 19);
    }

    /* Crosshair */
    if (this.mouse) this._crosshair(vis, dec, py, cx, cl, cr, ct, cb, lo, hi, ch);
  };

  Chart.prototype._crosshair = function(vis, _dec, py, cx, cl, cr, ct, cb, lo, hi, ch) {
    var dec = _dec; // passed from _draw (autoDec-based)
    var ctx = this.ctx;
    var mx  = this.mouse.x, my = this.mouse.y;
    var step = this._step;
    var W    = this.W;

    var li = clamp(Math.round((mx - cl - step/2) / step), 0, vis.length - 1);
    var c  = vis[li];
    if (!c) return;
    var x  = cx(li);
    var cursorPrice = hi - ((my - ct) / ch) * (hi - lo);

    /* Lines */
    ctx.strokeStyle = CROSS; ctx.lineWidth = 1; ctx.setLineDash([4,4]);
    ctx.beginPath(); ctx.moveTo(x, ct); ctx.lineTo(x, cb); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(cl, my); ctx.lineTo(cr, my); ctx.stroke();
    ctx.setLineDash([]);

    /* Y label */
    ctx.fillStyle = CROSS;
    ctx.fillRect(cr, my - 10, RM, 20);
    ctx.fillStyle = BG; ctx.textAlign = 'center'; ctx.font = '11px Outfit,sans-serif';
    ctx.fillText(cursorPrice.toFixed(dec), cr + RM/2, my + 4);

    /* X label */
    var lw = 84;
    ctx.fillStyle = CROSS;
    ctx.fillRect(x - lw/2, cb, lw, BM);
    ctx.fillStyle = BG; ctx.textAlign = 'center';
    ctx.fillText(fmtFull(c.t, this.interval), x, cb + 18);

    /* OHLC tooltip */
    var isUp = c.c >= c.o;
    var txL  = (x + 14 + 170 < W - RM) ? x + 14 : x - 184;
    var tyL  = ct + 8;
    ctx.fillStyle = 'rgba(10,7,20,0.92)';
    ctx.fillRect(txL, tyL, 170, 84);
    ctx.strokeStyle = isUp ? BULL : BEAR; ctx.lineWidth = 1;
    ctx.strokeRect(txL, tyL, 170, 84);
    var rows = ['O  '+c.o.toFixed(dec),'H  '+c.h.toFixed(dec),'L  '+c.l.toFixed(dec),'C  '+c.c.toFixed(dec)];
    ctx.fillStyle = TEXT; ctx.textAlign = 'left'; ctx.font = '11px "Courier New",monospace';
    for (var ri = 0; ri < rows.length; ri++) ctx.fillText(rows[ri], txL+10, tyL+20+ri*17);
  };

  /* ── Mouse events ────────────────────────────────────────────── */
  Chart.prototype._onMM = function(e) {
    var r = this.canvas.getBoundingClientRect();
    this.mouse = { x: e.clientX - r.left, y: e.clientY - r.top };
    this._draw();
  };

  /* ── Public methods ──────────────────────────────────────────── */
  Chart.prototype.update = function(symbol, interval, mode) {
    if (mode !== undefined) this.mode = mode;
    this.symbol      = symbol;
    this.interval    = interval;
    this.scrollRight  = 0;
    this.candles      = [];
    this._resolvedSym = null;
    /* Reset status-timing windows for the new symbol/interval. */
    this._loadStartedAt    = 0;
    this._sawEmptyResponse = false;
    this._marketClosedNote = false;

    if (this._tickTimer) { clearInterval(this._tickTimer); this._tickTimer = null; }
    if (this._tvTimer)   { clearInterval(this._tvTimer);   this._tvTimer   = null; }
    if (this._ws)        { try { this._ws.close(); } catch(_) {} this._ws = null; }
    clearTimeout(this._wsTimer); this._wsTimer = null;
    clearTimeout(this._retryTimer); this._retryTimer = null;
    if (this._otcHistTimer)  { clearInterval(this._otcHistTimer);  this._otcHistTimer  = null; }
    if (this._otcPriceTimer) { clearInterval(this._otcPriceTimer); this._otcPriceTimer = null; }
    this._otcProblem = null;
    this._otcOverlay = null;

    var self = this;
    if (this.mode === 'otc') {
      clearTimeout(this._simFallbackTimer);
      this._draw();   // loading screen until Supabase data arrives
      this._fetchOtcCandles();
      this._startOtcStream();
    } else if (this.mode === 'tv') {
      clearTimeout(this._simFallbackTimer);
      /* No sim-data fallback in tv mode — status/error states own the canvas. */
      this._draw();   // loading screen (candles are [])
      this._fetchTVCandles();
    } else {
      this.candles = buildHistory(this.symbol, this.interval, simCandleCount(self.interval));
      this._startTick();
      this._draw();
    }
  };

  Chart.prototype.destroy = function() {
    this._destroyed = true;
    if (this._tickTimer) clearInterval(this._tickTimer);
    if (this._tvTimer)   clearInterval(this._tvTimer);
    if (this._otcHistTimer)  clearInterval(this._otcHistTimer);
    if (this._otcPriceTimer) clearInterval(this._otcPriceTimer);
    if (this._ws)        { try { this._ws.close(); } catch(_) {} this._ws = null; }
    clearTimeout(this._wsTimer);
    clearTimeout(this._simFallbackTimer);
    clearTimeout(this._retryTimer);
    if (this._ro)        this._ro.disconnect();
    this.canvas.removeEventListener('mousemove',  this._mm);
    this.canvas.removeEventListener('mouseleave', this._ml);
    if (this.canvas.parentNode) this.canvas.parentNode.removeChild(this.canvas);
  };

  /* ── Entry line (drawn when trade is active) ────────────────── */
  Chart.prototype._drawEntryLine = function(py, cl, cr, ct, cb, dec, lastClose) {
    if (!this._entryLine) return;
    var ctx    = this.ctx;
    var ep     = this._entryLine.price;
    var isCall = this._entryLine.direction === 'CALL';
    var winning = lastClose != null ? (isCall ? lastClose > ep : lastClose < ep) : isCall;
    var color  = winning ? BULL : BEAR;
    var epy    = py(ep);
    if (epy < ct || epy > cb) return;

    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.setLineDash([8, 5]);
    ctx.beginPath(); ctx.moveTo(cl, epy); ctx.lineTo(cr, epy); ctx.stroke();
    ctx.setLineDash([]);

    ctx.fillStyle = color;
    ctx.fillRect(cr, epy - 10, RM, 20);
    ctx.fillStyle = BG; ctx.textAlign = 'center';
    ctx.font = 'bold 10px Outfit,sans-serif';
    ctx.fillText(ep.toFixed(autoDec(ep)), cr + RM / 2, epy + 4);
  };

  Chart.prototype._setTradeState = function(active, direction, entryPrice, secondsLeft, gwin) {
    if (!active) { this._trade = null; return; }
    var prev = this._trade;
    var t = { direction: direction, entryPrice: entryPrice, secondsLeft: secondsLeft, gwin: gwin };
    if (gwin) {
      // Reuse the win path while the SAME trade keeps ticking; (re)initialise it
      // only for a fresh trade (new entry/direction) so every trade wins by a
      // different, realistic amount.
      var same = prev && prev.gwin && prev.gwinTarget != null &&
                 prev.direction === direction && prev.entryPrice === entryPrice;
      if (same) {
        t.gwinTarget = prev.gwinTarget;
        t.gwinTotal  = Math.max(prev.gwinTotal, secondsLeft);
        t.gwinJit    = prev.gwinJit;
      } else {
        var isCall = direction === 'CALL';
        var margin = entryPrice * (0.00006 + Math.random() * 0.00040); // ~0.6–4.6 pip, varied
        t.gwinTarget = isCall ? entryPrice + margin : entryPrice - margin;
        t.gwinTotal  = Math.max(secondsLeft, 1);
        t.gwinJit    = entryPrice * 0.00002;            // micro-jitter on corrected ticks
      }
    }
    this._trade = t;
  };

  /* ── Public API ──────────────────────────────────────────────── */
  var instances = {};

  function _tryInit(id, sym, iv, mode, tries) {
    var el = document.getElementById(id);
    if (!el) {
      if (tries < 100) setTimeout(function() { _tryInit(id, sym, iv, mode, tries+1); }, 20);
      return;
    }
    if (instances[id]) { instances[id].destroy(); delete instances[id]; }
    instances[id] = new Chart(el, sym, iv, mode);
  }

  return {
    init:    function(id, sym, iv, mode) { _tryInit(id, sym, iv, mode || 'sim', 0); },
    update:  function(id, sym, iv, mode) {
      var i = instances[id];
      if (i) i.update(sym, iv, mode);
      else _tryInit(id, sym, iv, mode || 'sim', 0);
    },
    destroy: function(id) { if (instances[id]) { instances[id].destroy(); delete instances[id]; } },
    getLastPrice: function(id) {
      var inst = instances[id];
      if (!inst || !inst.candles.length) return 0;
      return inst.candles[inst.candles.length - 1].c;
    },
    setEntryLine: function(id, price, direction) {
      var inst = instances[id];
      if (!inst) return;
      inst._entryLine = (price && direction) ? { price: price, direction: direction } : null;
      inst._draw();
    },
    setTradeState: function(id, active, direction, entryPrice, secondsLeft, gwin) {
      var inst = instances[id];
      if (inst) inst._setTradeState(active, direction, entryPrice, secondsLeft, gwin);
    },
    /* Called directly from Dart signal engine — draws/clears entry line on ALL instances */
    setGlobalEntryLine: function(price, direction) {
      var hasLine = price != null && price !== 'null' && direction && direction !== 'null';
      Object.keys(instances).forEach(function(id) {
        var inst = instances[id];
        if (!inst) return;
        inst._entryLine = hasLine ? { price: Number(price), direction: String(direction) } : null;
        inst._draw();
      });
    },
    /* Sync a sim price to ALL sim-mode instances — used by guaranteed-win nudge */
    updateAllSimPrice: function(price) {
      var p = Number(price);
      if (!p) return;
      Object.keys(instances).forEach(function(id) {
        var inst = instances[id];
        if (!inst || inst.mode === 'tv' || !inst.candles.length) return;
        var last = inst.candles[inst.candles.length - 1];
        last.c = p;
        if (p > last.h) last.h = p;
        if (p < last.l) last.l = p;
        inst._draw();
      });
    },
  };
})();

window.setUserBroker = function(broker) {
  window.userBroker = broker;
};
