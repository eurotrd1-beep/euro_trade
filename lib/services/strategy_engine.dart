import 'market_data_service.dart';

enum SignalDirection { call, put, none }

class StrategyResult {
  final SignalDirection direction;
  final double callScore;
  final double putScore;

  const StrategyResult({
    required this.direction,
    required this.callScore,
    required this.putScore,
  });

  static const StrategyResult none = StrategyResult(
    direction: SignalDirection.none,
    callScore: 0,
    putScore: 0,
  );
}

class StrategyEngine {
  final Map<String, dynamic> strategyJson;

  StrategyEngine(this.strategyJson);

  // ── Default strategy (admin can override) ───────────────────────────────────

  static Map<String, dynamic> get defaultStrategy => {
    'name': 'ICT Dual-Direction Strategy',
    'version': '2.0',
    'rules': [
      {
        'indicator': 'market_structure',
        'condition': 'eq',
        'signal': 'dominant',
        'score': 3,
        'enabled': true,
        'role': 'primary',
      },
      {
        'indicator': 'order_block',
        'condition': 'bullish',
        'signal': 'CALL',
        'score': 3,
        'enabled': true,
        'role': 'primary',
      },
      {
        'indicator': 'order_block',
        'condition': 'bearish',
        'signal': 'PUT',
        'score': 3,
        'enabled': true,
        'role': 'primary',
      },
      {
        'indicator': 'rsi',
        'condition': 'between',
        'signal': 'dominant',
        'score': 2,
        'enabled': true,
        'role': 'confirm',
        'period': 14,
        'value_min': 45,
        'value_max': 65,
      },
      {
        'indicator': 'macd_histogram',
        'condition': 'gt',
        'signal': 'CALL',
        'score': 2,
        'enabled': true,
        'role': 'confirm',
        'value': 0,
      },
      {
        'indicator': 'macd_histogram',
        'condition': 'lt',
        'signal': 'PUT',
        'score': 2,
        'enabled': true,
        'role': 'confirm',
        'value': 0,
      },
      {
        'indicator': 'kill_zone',
        'condition': 'eq',
        'signal': 'dominant',
        'score': 3,
        'enabled': true,
        'role': 'filter',
        'pattern': 'london_killzone',
      },
    ],
  };

  // ── Evaluate ─────────────────────────────────────────────────────────────────

  StrategyResult evaluate(List<OhlcvCandle> candles) {
    if (candles.length < 50) return StrategyResult.none;

    final rules = (strategyJson['rules'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['enabled'] == true)
        .toList();

    final closes = candles.map((c) => c.close).toList();
    final opens  = candles.map((c) => c.open).toList();
    final highs  = candles.map((c) => c.high).toList();
    final lows   = candles.map((c) => c.low).toList();

    final ind = _Indicators(
      rsi:              _calcRsi(closes, 14),
      macdHistogram:    _calcMacdHistogram(closes),
      marketStructure:  _calcMarketStructure(closes),
      hasBullishOB:     _calcBullishOB(opens, closes, highs),
      hasBearishOB:     _calcBearishOB(opens, closes, lows),
      inLondonKillZone: _inLondonKillZone(),
    );

    // Pass 1: rules with explicit CALL/PUT signal
    double callScore = 0, putScore = 0;
    for (final rule in rules.where((r) => r['signal'] != 'dominant')) {
      if (_evalSpecific(rule, ind)) {
        final score = (rule['score'] as num).toDouble();
        if (rule['signal'] == 'CALL') callScore += score;
        else if (rule['signal'] == 'PUT') putScore += score;
      }
    }

    // Dominant direction from pass 1
    final dominant = callScore > putScore
        ? 'CALL'
        : putScore > callScore
            ? 'PUT'
            : null;

    // Pass 2: "dominant" signal rules — add to winning side
    if (dominant != null) {
      for (final rule in rules.where((r) => r['signal'] == 'dominant')) {
        if (_evalDominant(rule, ind)) {
          final score = (rule['score'] as num).toDouble();
          if (dominant == 'CALL') callScore += score;
          else putScore += score;
        }
      }
    }

    final total = callScore + putScore;
    if (total == 0) return StrategyResult.none;

    if (callScore / total >= 0.60) {
      return StrategyResult(
          direction: SignalDirection.call,
          callScore: callScore,
          putScore: putScore);
    }
    if (putScore / total >= 0.60) {
      return StrategyResult(
          direction: SignalDirection.put,
          callScore: callScore,
          putScore: putScore);
    }
    return StrategyResult(
        direction: SignalDirection.none,
        callScore: callScore,
        putScore: putScore);
  }

  // ── Rule evaluators ───────────────────────────────────────────────────────────

  bool _evalSpecific(Map<String, dynamic> rule, _Indicators ind) {
    final indicator = rule['indicator'] as String;
    final condition = rule['condition'] as String;
    switch (indicator) {
      case 'order_block':
        return condition == 'bullish' ? ind.hasBullishOB : ind.hasBearishOB;
      case 'macd_histogram':
        final val = (rule['value'] as num).toDouble();
        if (condition == 'gt') return ind.macdHistogram > val;
        if (condition == 'lt') return ind.macdHistogram < val;
        return false;
      case 'rsi':
        if (condition == 'between') {
          final min = (rule['value_min'] as num).toDouble();
          final max = (rule['value_max'] as num).toDouble();
          return ind.rsi >= min && ind.rsi <= max;
        }
        return false;
      default:
        return false;
    }
  }

  bool _evalDominant(Map<String, dynamic> rule, _Indicators ind) {
    final indicator = rule['indicator'] as String;
    final condition = rule['condition'] as String;
    switch (indicator) {
      case 'market_structure':
        return condition == 'eq' && ind.marketStructure != 0;
      case 'rsi':
        if (condition == 'between') {
          final min = (rule['value_min'] as num).toDouble();
          final max = (rule['value_max'] as num).toDouble();
          return ind.rsi >= min && ind.rsi <= max;
        }
        return false;
      case 'kill_zone':
        if (condition == 'eq') {
          final pattern = rule['pattern'] as String? ?? '';
          return pattern == 'london_killzone' && ind.inLondonKillZone;
        }
        return false;
      default:
        return false;
    }
  }

  // ── Indicator calculations ────────────────────────────────────────────────────

  double _calcRsi(List<double> closes, int period) {
    if (closes.length < period + 1) return 50.0;
    double avgGain = 0, avgLoss = 0;
    for (int i = 1; i <= period; i++) {
      final d = closes[i] - closes[i - 1];
      if (d > 0) avgGain += d; else avgLoss -= d;
    }
    avgGain /= period;
    avgLoss /= period;
    for (int i = period + 1; i < closes.length; i++) {
      final d = closes[i] - closes[i - 1];
      avgGain = (avgGain * (period - 1) + (d > 0 ? d : 0)) / period;
      avgLoss = (avgLoss * (period - 1) + (d < 0 ? -d : 0)) / period;
    }
    if (avgLoss == 0) return 100.0;
    return 100.0 - (100.0 / (1.0 + avgGain / avgLoss));
  }

  double _calcMacdHistogram(List<double> closes) {
    if (closes.length < 35) return 0.0;
    final ema12 = _emaList(closes, 12);
    final ema26 = _emaList(closes, 26);
    if (ema12.isEmpty || ema26.isEmpty) return 0.0;
    final offset = ema12.length - ema26.length;
    final macdLine = List.generate(
        ema26.length, (i) => ema12[offset + i] - ema26[i]);
    if (macdLine.length < 9) return 0.0;
    final signal = _emaList(macdLine, 9);
    if (signal.isEmpty) return 0.0;
    return macdLine.last - signal.last;
  }

  // EMA(20) slope + price position → 1 bullish / -1 bearish / 0 neutral
  int _calcMarketStructure(List<double> closes) {
    if (closes.length < 22) return 0;
    final ema = _emaList(closes, 20);
    if (ema.length < 3) return 0;
    final slope = ema.last - ema[ema.length - 3];
    if (slope > 0 && closes.last > ema.last) return 1;
    if (slope < 0 && closes.last < ema.last) return -1;
    return 0;
  }

  // Bullish OB: last bearish candle followed by price breaking above its high
  bool _calcBullishOB(
      List<double> opens, List<double> closes, List<double> highs) {
    final n = closes.length;
    if (n < 10) return false;
    for (int i = n - 7; i < n - 2; i++) {
      if (closes[i] < opens[i]) {
        final obHigh = highs[i];
        for (int j = i + 1; j < n - 1; j++) {
          if (closes[j] > obHigh) return closes.last > opens[i];
        }
      }
    }
    return false;
  }

  // Bearish OB: last bullish candle followed by price breaking below its low
  bool _calcBearishOB(
      List<double> opens, List<double> closes, List<double> lows) {
    final n = closes.length;
    if (n < 10) return false;
    for (int i = n - 7; i < n - 2; i++) {
      if (closes[i] > opens[i]) {
        final obLow = lows[i];
        for (int j = i + 1; j < n - 1; j++) {
          if (closes[j] < obLow) return closes.last < opens[i];
        }
      }
    }
    return false;
  }

  // London killzone: 02:00 – 05:00 UTC
  bool _inLondonKillZone() {
    final h = DateTime.now().toUtc().hour;
    return h >= 2 && h < 5;
  }

  List<double> _emaList(List<double> data, int period) {
    if (data.length < period) return [];
    final k = 2.0 / (period + 1);
    double ema = data.take(period).reduce((a, b) => a + b) / period;
    final result = <double>[ema];
    for (int i = period; i < data.length; i++) {
      ema = data[i] * k + ema * (1 - k);
      result.add(ema);
    }
    return result;
  }
}

class _Indicators {
  final double rsi;
  final double macdHistogram;
  final int marketStructure;
  final bool hasBullishOB;
  final bool hasBearishOB;
  final bool inLondonKillZone;

  const _Indicators({
    required this.rsi,
    required this.macdHistogram,
    required this.marketStructure,
    required this.hasBullishOB,
    required this.hasBearishOB,
    required this.inLondonKillZone,
  });
}
