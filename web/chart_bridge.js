window.ChartBridge = (function () {
  var charts = {};

  function initChart(elementId, options) {
    var attempts = 0;
    function tryInit() {
      var container = document.getElementById(elementId);
      if (!container) {
        if (attempts++ < 40) { setTimeout(tryInit, 150); }
        return;
      }
      if (typeof LightweightCharts === 'undefined') {
        if (attempts++ < 40) { setTimeout(tryInit, 150); }
        return;
      }

      // Destroy existing instance if re-init
      if (charts[elementId]) {
        try { charts[elementId].chart.remove(); } catch (_) {}
        delete charts[elementId];
      }

      var chart = LightweightCharts.createChart(container, {
        autoSize: true,
        layout: {
          background: { color: options.bgColor || '#0A0714' },
          textColor: options.textColor || '#8B88A0',
          fontFamily: 'Outfit, sans-serif',
        },
        grid: {
          vertLines: { color: '#1E1736' },
          horzLines: { color: '#1E1736' },
        },
        crosshair: {
          mode: 0,
          vertLine: { color: '#00FFF0', width: 1, style: 3, labelBackgroundColor: '#161129' },
          horzLine: { color: '#00FFF0', width: 1, style: 3, labelBackgroundColor: '#161129' },
        },
        timeScale: {
          borderColor: '#2C2250',
          timeVisible: true,
          secondsVisible: false,
          rightOffset: 5,
          barSpacing: 8,
        },
        rightPriceScale: {
          borderColor: '#2C2250',
          textColor: '#8B88A0',
        },
        handleScroll: { mouseWheel: true, pressedMouseMove: true },
        handleScale: { mouseWheel: true, pinch: true },
      });

      var series = chart.addSeries(LightweightCharts.CandlestickSeries, {
        upColor:   options.upColor   || '#00FF7F',
        downColor: options.downColor || '#FF2A6D',
        borderVisible: false,
        wickUpColor:   options.upColor   || '#00FF7F',
        wickDownColor: options.downColor || '#FF2A6D',
      });

      // v5 markers API: createSeriesMarkers instead of series.setMarkers
      var seriesMarkers = LightweightCharts.createSeriesMarkers(series, []);
      charts[elementId] = { chart: chart, series: series, markers: seriesMarkers };
    }
    tryInit();
  }

  function setData(elementId, data) {
    var entry = charts[elementId];
    if (!entry) return false;
    try {
      entry.series.setData(data);
      entry.chart.timeScale().fitContent();
      return true;
    } catch (e) {
      console.error('ChartBridge.setData:', e);
      return false;
    }
  }

  function updateLast(elementId, candle) {
    var entry = charts[elementId];
    if (!entry) return false;
    try {
      entry.series.update(candle);
      return true;
    } catch (e) {
      return false;
    }
  }

  function destroyChart(elementId) {
    var entry = charts[elementId];
    if (!entry) return;
    try { entry.chart.remove(); } catch (_) {}
    delete charts[elementId];
  }

  // Fetches Finnhub candles via native browser fetch (avoids Flutter http CORS issues)
  // onSuccess(responseText: string), onError(errorMessage: string)
  function fetchFinnhubCandles(symbol, resolution, from, to, apiKey, onSuccess, onError) {
    var url = 'https://finnhub.io/api/v1/forex/candle' +
      '?symbol='     + encodeURIComponent(symbol) +
      '&resolution=' + encodeURIComponent(resolution) +
      '&from='       + from +
      '&to='         + to +
      '&token='      + apiKey;
    console.log('[ChartBridge] fetchFinnhubCandles:', url);
    fetch(url, { method: 'GET' })
      .then(function(r) { return r.text(); })
      .then(function(text) { onSuccess(text); })
      .catch(function(e) { onError(e ? e.toString() : 'fetch failed'); });
  }

  function setMarkers(elementId, markers) {
    var entry = charts[elementId];
    if (!entry) return false;
    try {
      entry.markers.setData(markers);
      return true;
    } catch (e) {
      console.error('ChartBridge.setMarkers:', e);
      return false;
    }
  }

  return {
    initChart: initChart,
    setData: setData,
    updateLast: updateLast,
    setMarkers: setMarkers,
    destroyChart: destroyChart,
  };
})();
