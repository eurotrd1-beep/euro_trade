import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Holds the backend server URLs, sourced dynamically from Supabase `configs`
/// so the admin can switch which Render server the app talks to — instantly,
/// with no rebuild or redeploy.
///
/// Only the **TradingView** proxy URL affects the app's data path (candles /
/// tick / websocket). OTC data flows through Supabase itself, so the OTC URL is
/// admin-side monitoring only and isn't read here.
class ServerConfig {
  /// Fallback used until the config loads (matches the previously hardcoded URL,
  /// so behaviour is unchanged on first paint / if Supabase is unreachable).
  static const String defaultTvUrl = 'https://euro-trade-proxy-1.onrender.com';

  /// Current TradingView proxy base URL (no trailing slash). Listen to this to
  /// react to admin changes (reconnect chart / re-fetch).
  static final ValueNotifier<String> tvServerUrl =
      ValueNotifier<String>(defaultTvUrl);

  static StreamSubscription? _sub;

  static String _clean(String? url) {
    final u = (url ?? '').trim();
    if (u.isEmpty) return '';
    // Strip a trailing slash so `$base/api/...` never doubles up.
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// One-shot load at startup so the correct URL is ready before the chart builds.
  static Future<void> load() async {
    try {
      final row = await Supabase.instance.client
          .from('configs')
          .select('data')
          .eq('id', 'tv_server_url')
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      final data = row?['data'] as Map<String, dynamic>? ?? {};
      final url = _clean(data['url'] as String?);
      if (url.isNotEmpty) tvServerUrl.value = url;
    } catch (_) {}
  }

  /// Realtime subscription — pushes admin changes to every open app instantly.
  static void startRealtime() {
    _sub?.cancel();
    try {
      _sub = Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'tv_server_url')
          .listen((rows) {
        if (rows.isEmpty) return;
        final data = rows.first['data'] as Map<String, dynamic>? ?? {};
        final url = _clean(data['url'] as String?);
        if (url.isNotEmpty && url != tvServerUrl.value) {
          tvServerUrl.value = url;
        }
      });
    } catch (_) {}
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
