import 'dart:convert';
import 'package:http/http.dart' as http;
import 'market_data_service.dart';

class FinnhubService {
  static const String apiKey = 'd8vas59r01quam15jhq0d8vas59r01quam15jhqg';
  static const String _base = 'https://finnhub.io/api/v1';

  // Finnhub resolution strings
  static String resolution(String timeframe) {
    switch (timeframe) {
      case '5m':  return '5';
      case '15m': return '15';
      case '1h':  return '60';
      case '1D':  return 'D';
      default:    return '1'; // 1m
    }
  }

  // How far back to request candles (gives ~200 candles)
  static int fromTimestamp(String timeframe) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    switch (timeframe) {
      case '5m':  return now - 200 * 5   * 60;
      case '15m': return now - 200 * 15  * 60;
      case '1h':  return now - 200 * 3600;
      case '1D':  return now - 200 * 86400;
      default:    return now - 200 * 60; // 1m
    }
  }

  Future<List<OhlcvCandle>> fetchCandles({
    required String symbol,
    required String timeframe,
  }) async {
    final res = resolution(timeframe);
    final from = fromTimestamp(timeframe);
    final to = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final uri = Uri.parse('$_base/forex/candle').replace(queryParameters: {
      'symbol':     symbol,
      'resolution': res,
      'from':       '$from',
      'to':         '$to',
      'token':      apiKey,
    });

    // ignore: avoid_print
    print('[Finnhub] GET $uri');

    final response = await http.get(uri).timeout(const Duration(seconds: 15));

    // ignore: avoid_print
    print('[Finnhub] ${response.statusCode} — ${response.body}');

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    // Finnhub error format: {"error": "..."}
    if (json.containsKey('error')) {
      throw Exception('Finnhub error: ${json['error']}');
    }

    if (json['s'] != 'ok') {
      // 'no_data' = outside trading hours — return empty rather than throw
      if (json['s'] == 'no_data') return [];
      throw Exception('Finnhub status: ${json['s']} — body: ${response.body}');
    }

    final t = (json['t'] as List).cast<int>();
    final o = (json['o'] as List).map((v) => (v as num).toDouble()).toList();
    final h = (json['h'] as List).map((v) => (v as num).toDouble()).toList();
    final l = (json['l'] as List).map((v) => (v as num).toDouble()).toList();
    final c = (json['c'] as List).map((v) => (v as num).toDouble()).toList();

    return List.generate(
      t.length,
      (i) => OhlcvCandle(time: t[i], open: o[i], high: h[i], low: l[i], close: c[i]),
    );
  }
}
