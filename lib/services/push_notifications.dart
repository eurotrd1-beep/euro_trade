import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push_web_stub.dart' if (dart.library.js) 'push_web.dart' as pushweb;

/// Web Push notifications (works on Android via the browser/PWA — no APK).
///
/// Flow:
///  1. [requestPermissionOnce] — asked once, right after language selection.
///  2. [registerForUser] — once the account id is known (on the signals
///     screen): subscribes via the push service worker and stores the
///     subscription in Supabase `push_subscriptions`.
///  3. [notifyNewSignal] — when the engine fires a new signal, invokes the
///     `send-signal-notification` Edge Function, which delivers the push (so it
///     shows even when the tab/app is backgrounded).
///
/// The public VAPID key is read from the Supabase `configs` row `push`
/// (`{"vapidPublicKey": "..."}`), so keys can be rotated without shipping code.
class PushNotifications {
  static const String _promptedKey = 'push_permission_prompted';
  static String _vapidPublicKey = '';

  /// Whether the current platform/browser can do Web Push at all.
  static bool get isSupported => pushweb.isSupported();

  static Future<String> _getVapidPublicKey() async {
    if (_vapidPublicKey.isNotEmpty) return _vapidPublicKey;
    try {
      final row = await Supabase.instance.client
          .from('configs')
          .select('data')
          .eq('id', 'push')
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      final data = row?['data'] as Map<String, dynamic>? ?? {};
      _vapidPublicKey = (data['vapidPublicKey'] as String?)?.trim() ?? '';
    } catch (_) {}
    return _vapidPublicKey;
  }

  /// Prompts for notification permission a single time (guarded by a local
  /// flag). Best called from a user gesture — e.g. right after the user taps a
  /// language on the language screen.
  static Future<void> requestPermissionOnce() async {
    if (!isSupported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_promptedKey) == true) return;
      await prefs.setBool(_promptedKey, true);
      await pushweb.requestPermission();
    } catch (_) {}
  }

  /// Subscribes this device to push and upserts the subscription for [userId].
  /// Safe to call repeatedly; does nothing if unsupported, permission isn't
  /// granted, or the admin hasn't configured a VAPID public key yet.
  static Future<void> registerForUser(String userId) async {
    // Temporary diagnostic: records exactly where the subscribe flow stops in
    // configs('push_debug') so issues can be diagnosed without device console.
    final dbg = <String, dynamic>{
      'userId': userId,
      'supported': isSupported,
    };
    try {
      if (!isSupported) {
        dbg['stop'] = 'unsupported';
        await _writeDebug(dbg);
        return;
      }
      if (userId.isEmpty || userId == '----') {
        dbg['stop'] = 'no_user';
        await _writeDebug(dbg);
        return;
      }
      final key = await _getVapidPublicKey();
      dbg['vapidLen'] = key.length;
      if (key.isEmpty) {
        dbg['stop'] = 'no_vapid';
        await _writeDebug(dbg);
        return;
      }
      final subJson = await pushweb.subscribe(key);
      dbg['subLen'] = subJson?.length ?? 0;
      dbg['jsError'] = pushweb.lastError();
      if (subJson == null || subJson.isEmpty) {
        dbg['stop'] = 'subscribe_null';
        await _writeDebug(dbg);
        return;
      }
      final sub = jsonDecode(subJson) as Map<String, dynamic>;
      final endpoint = sub['endpoint'] as String?;
      if (endpoint == null || endpoint.isEmpty) {
        dbg['stop'] = 'no_endpoint';
        await _writeDebug(dbg);
        return;
      }
      await Supabase.instance.client.from('push_subscriptions').upsert(
        {
          'user_id': userId,
          'endpoint': endpoint,
          'subscription': sub,
        },
        onConflict: 'endpoint',
      );
      dbg['stop'] = 'ok';
      await _writeDebug(dbg);
    } catch (e) {
      dbg['stop'] = 'exception';
      dbg['error'] = e.toString();
      try {
        await _writeDebug(dbg);
      } catch (_) {}
    }
  }

  static Future<void> _writeDebug(Map<String, dynamic> d) async {
    try {
      await Supabase.instance.client
          .from('configs')
          .upsert({'id': 'push_debug', 'data': d});
    } catch (_) {}
  }

  /// Asks the Edge Function to deliver a push for a freshly-fired signal.
  /// Targets only [userId]'s subscriptions (pass an empty [userId] server-side
  /// to broadcast — see the function). [title]/[body] are already localized.
  static Future<void> notifyNewSignal({
    required String userId,
    required String title,
    required String body,
    String tag = 'euro-signal',
  }) async {
    if (userId.isEmpty || userId == '----') return;
    try {
      await Supabase.instance.client.functions.invoke(
        'send-signal-notification',
        body: {
          'user_id': userId,
          'title': title,
          'body': body,
          'url': pushweb.appUrl(),
          'tag': tag,
        },
      );
    } catch (_) {}
  }
}
