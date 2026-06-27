import 'package:flutter/material.dart';

class AppConstants {
  // Central price formatting helper
  static String formatPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(2);
    if (price >= 10) return price.toStringAsFixed(3);
    return price.toStringAsFixed(5);
  }

  // --- Broker Affiliate Links ---
  static const String quotexAffiliateLink = 'https://broker-qx.pro/sign-up/?lid=2154439';
  static const String pocketOptionAffiliateLink = 'https://pocketoption.com/register/?utm_source=affiliate&a=VIPTRADER';
  static const String expertOptionAffiliateLink = 'https://expertoption-track.com/143787056';

  // --- Local Storage Keys ---
  static const String keyUserVerified = 'user_verified';
  static const String keyUserAccountId = 'user_account_id';
  static const String keyUserBroker = 'user_broker';

  // --- Premium Styling Color System ---
  static const Color spaceBackground = Color(0xFF0A0714);
  static const Color cardBgColor = Color(0xFF161129);
  static Color accentCyan = const Color(0xFF00FFF0);
  static Color accentBlue = const Color(0xFF1A8CFF);

  static const Color callGreen = Color(0xFF00FF7F);
  static const Color putRed = Color(0xFFFF2A6D);
  static const Color warningOrange = Color(0xFFFFAD00);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8B88A0);
  static const Color borderGlow = Color(0xFF2C2250);

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [Color(0xFF06030C), Color(0xFF0E091F), Color(0xFF05030A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // --- Trading Pairs (loaded dynamically from Firestore by main_screen) ---
  static List<Map<String, dynamic>> currencyPairs = [];

  /// Maps a display pair name to its Finnhub symbol (e.g. "EUR/USD (OTC)" → "OANDA:EUR_USD").
  static String chartSymbolFor(String displaySymbol) {
    for (final p in currencyPairs) {
      if (p['symbol'] == displaySymbol) return p['chartSymbol'] as String;
    }
    // Fallback: strip OTC suffix and convert to OANDA format
    final base = displaySymbol.replaceAll(' (OTC)', '').replaceAll('/', '_');
    return 'OANDA:$base';
  }
}
