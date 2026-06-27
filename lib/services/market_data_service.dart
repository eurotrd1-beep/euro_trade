import 'dart:convert';
import 'package:http/http.dart' as http;

class OhlcvCandle {
  final int time; // Unix seconds (TradingView format)
  final double open;
  final double high;
  final double low;
  final double close;

  const OhlcvCandle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });
}

typedef OhlcvParser = List<OhlcvCandle> Function(dynamic json);

class MarketDataConfig {
  /// URL template — use {symbol}, {interval}, {apiKey} as placeholders.
  /// Example: "https://api.example.com/v2/history?symbol={symbol}&interval={interval}&token={apiKey}&outputsize=200"
  final String urlTemplate;
  final String apiKey;
  final String symbol;
  final String interval;
  final Map<String, String>? headers;

  /// Custom parser — if null, auto-detection is used.
  /// Receives the raw decoded JSON and must return sorted OhlcvCandle list.
  final OhlcvParser? customParser;

  const MarketDataConfig({
    required this.urlTemplate,
    required this.apiKey,
    required this.symbol,
    required this.interval,
    this.headers,
    this.customParser,
  });

  MarketDataConfig copyWith({String? symbol, String? interval}) {
    return MarketDataConfig(
      urlTemplate: urlTemplate,
      apiKey: apiKey,
      symbol: symbol ?? this.symbol,
      interval: interval ?? this.interval,
      headers: headers,
      customParser: customParser,
    );
  }

  String buildUrl() {
    return urlTemplate
        .replaceAll('{symbol}', Uri.encodeComponent(symbol))
        .replaceAll('{interval}', Uri.encodeComponent(interval))
        .replaceAll('{apiKey}', apiKey);
  }
}

class MarketDataService {
  MarketDataConfig? _config;

  void configure(MarketDataConfig config) => _config = config;

  Future<List<OhlcvCandle>> fetchCandles() async {
    final cfg = _config;
    if (cfg == null) throw Exception('MarketDataService not configured');

    final url = cfg.buildUrl();
    final response = await http
        .get(Uri.parse(url), headers: cfg.headers)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body);

    if (cfg.customParser != null) {
      return cfg.customParser!(json);
    }

    return _autoParse(json);
  }

  /// Auto-detects common OHLCV JSON formats:
  /// 1. Top-level array of objects with time/open/high/low/close fields
  /// 2. Top-level array of arrays [time, open, high, low, close, ...]
  /// 3. Object with a 'data', 'candles', 'values', or 'ohlcv' array key
  List<OhlcvCandle> _autoParse(dynamic json) {
    List<dynamic> raw;

    if (json is List) {
      raw = json;
    } else if (json is Map) {
      raw = _extractArray(json);
    } else {
      throw Exception('Unrecognised JSON format');
    }

    if (raw.isEmpty) return [];

    final first = raw.first;
    if (first is List) {
      return _parseArrayOfArrays(raw);
    } else if (first is Map) {
      return _parseArrayOfObjects(raw);
    }

    throw Exception('Unrecognised OHLCV array element format');
  }

  List<dynamic> _extractArray(Map<dynamic, dynamic> obj) {
    for (final key in ['data', 'candles', 'values', 'ohlcv', 'result', 'bars', 'timeSeries']) {
      if (obj[key] is List) return obj[key] as List;
    }
    // Try any List value
    for (final v in obj.values) {
      if (v is List && v.isNotEmpty) return v;
    }
    throw Exception('Cannot find candle array in response object. Keys: ${obj.keys.toList()}');
  }

  List<OhlcvCandle> _parseArrayOfObjects(List<dynamic> list) {
    final candles = <OhlcvCandle>[];
    for (final item in list) {
      final m = item as Map;
      final t = _extractTime(m);
      if (t == null) continue;
      candles.add(OhlcvCandle(
        time: t,
        open:  _toDouble(m['open']  ?? m['o']) ?? 0,
        high:  _toDouble(m['high']  ?? m['h']) ?? 0,
        low:   _toDouble(m['low']   ?? m['l']) ?? 0,
        close: _toDouble(m['close'] ?? m['c']) ?? 0,
      ));
    }
    candles.sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  List<OhlcvCandle> _parseArrayOfArrays(List<dynamic> list) {
    final candles = <OhlcvCandle>[];
    for (final item in list) {
      final arr = item as List;
      if (arr.length < 5) continue;
      final t = _toUnixSeconds(arr[0]);
      if (t == null) continue;
      candles.add(OhlcvCandle(
        time:  t,
        open:  _toDouble(arr[1]) ?? 0,
        high:  _toDouble(arr[2]) ?? 0,
        low:   _toDouble(arr[3]) ?? 0,
        close: _toDouble(arr[4]) ?? 0,
      ));
    }
    candles.sort((a, b) => a.time.compareTo(b.time));
    return candles;
  }

  int? _extractTime(Map m) {
    final raw = m['time'] ?? m['t'] ?? m['timestamp'] ?? m['datetime'] ?? m['date'];
    return _toUnixSeconds(raw);
  }

  int? _toUnixSeconds(dynamic v) {
    if (v == null) return null;
    if (v is int) {
      // Milliseconds → seconds if needed
      return v > 9999999999 ? v ~/ 1000 : v;
    }
    if (v is double) {
      final i = v.toInt();
      return i > 9999999999 ? i ~/ 1000 : i;
    }
    if (v is String) {
      final n = int.tryParse(v);
      if (n != null) return _toUnixSeconds(n);
      final dt = DateTime.tryParse(v);
      if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
