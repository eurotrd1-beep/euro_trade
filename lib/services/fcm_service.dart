import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Background message handler — must be a top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase is already initialized by this point on Android.
  // Nothing extra needed — system tray handles the notification display.
}

class FcmService {
  static bool _initialized = false;

  /// Call once after Firebase.initializeApp() in main().
  static void setupBackgroundHandler() {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  /// Request permission + save token. Call after the user successfully logs in.
  static Future<void> initAndSaveToken(String accountId) async {
    try {
      final messaging = FirebaseMessaging.instance;

      // Request permission (Android 13+, iOS)
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // Always get and save the current token (handles existing users too)
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveToken(accountId, token);
      }

      // Only subscribe to refresh once per session
      if (!_initialized) {
        _initialized = true;
        messaging.onTokenRefresh.listen((newToken) {
          _saveToken(accountId, newToken);
        });
      }
    } catch (e) {
      debugPrint('FCM init error: $e');
    }
  }

  static Future<void> _saveToken(String accountId, String token) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(accountId)
          .update({'fcmToken': token});
    } catch (_) {}
  }
}
