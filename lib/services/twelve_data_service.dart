import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'market_data_service.dart';

class TwelveDataService {
  static const String _apiKey = 'caa9557b9f84445690a451ca11a8d4da';
  static const String _base = 'https://api.twelvedata.com';

  // OANDA:EUR_USD → EUR/USD
  static String toTwelveSymbol(String symbol) =>
      symbol.replaceFirst(RegExp(r'^[A-Z]+:'), '').replaceAll('_', '/');

  static String toInterval(String tf) {
    switch (tf) {
      case '5m':  return '5min';
      case '15m': return '15min';
      case '1h':  return '1h';
      case '1D':  return '1day';
      default:    return '1min';
    }
  }

  Future<List<OhlcvCandle>> fetchCandles({
    required String symbol,
    required String timeframe,
    int outputsize = 300,
  }) async {
    final sym      = toTwelveSymbol(symbol);
    final interval = toInterval(timeframe);
    final url = '$_base/time_series'
        '?symbol=${Uri.encodeComponent(sym)}'
        '&interval=$interval'
        '&outputsize=$outputsize'
        '&apikey=$_apiKey';

    // ignore: avoid_print
    print('[TwelveData] GET $url');

    final req = await html.HttpRequest.request(url, method: 'GET')
        .timeout(const Duration(seconds: 20));

    if (req.status != 200) {
      throw Exception('HTTP ${req.status}: ${req.responseText}');
    }

    final body = jsonDecode(req.responseText ?? '') as Map<String, dynamic>;

    if (body['status'] == 'error') {
      throw Exception('Twelve Data: ${body['message']}');
    }

    // Values are newest-first — reverse for chart (oldest-first)
    final values = (body['values'] as List).reversed.toList();

    return values.map((v) {
      final m = v as Map<String, dynamic>;
      // datetime format: "2024-01-01 12:30:00" — treat as UTC
      final dtStr = (m['datetime'] as String).replaceAll(' ', 'T') + 'Z';
      final dt = DateTime.parse(dtStr);
      return OhlcvCandle(
        time:  dt.millisecondsSinceEpoch ~/ 1000,
        open:  double.parse(m['open']  as String),
        high:  double.parse(m['high']  as String),
        low:   double.parse(m['low']   as String),
        close: double.parse(m['close'] as String),
      );
    }).toList();
  }
}
