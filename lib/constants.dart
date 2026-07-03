import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppConstants {
  // Central price formatting helper
  static String formatPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(2);
    if (price >= 10) return price.toStringAsFixed(3);
    return price.toStringAsFixed(5);
  }

  // A stable per-device/browser id (generated once, persisted locally). Used to
  // lock a VIP account to a single device.
  static const String keyDeviceId = 'device_id';
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(keyDeviceId);
    if (id == null || id.isEmpty) {
      id = 'd${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '${Random().nextInt(0x7fffffff).toRadixString(36)}';
      await prefs.setString(keyDeviceId, id);
    }
    return id;
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

  // --- Trading Pairs (Always populated locally, independent of Firestore) ---
  // Pre-load fallback (TradingView source). Uses the unified 5-category taxonomy
  // + source/enabled/is_otc keys; the Supabase `pairs` stream replaces this list
  // once it loads. Kept in sync with the admin's category names.
  static const List<Map<String, dynamic>> defaultCurrencyPairs = [
    // --- CURRENCIES ---
    {'symbol': 'EUR/USD', 'chartSymbol': 'OANDA:EURUSD', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'GBP/USD', 'chartSymbol': 'OANDA:GBPUSD', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'USD/JPY', 'chartSymbol': 'OANDA:USDJPY', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'USD/CHF', 'chartSymbol': 'OANDA:USDCHF', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'AUD/USD', 'chartSymbol': 'OANDA:AUDUSD', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'USD/CAD', 'chartSymbol': 'OANDA:USDCAD', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'NZD/USD', 'chartSymbol': 'OANDA:NZDUSD', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'EUR/GBP', 'chartSymbol': 'OANDA:EURGBP', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'EUR/JPY', 'chartSymbol': 'OANDA:EURJPY', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'GBP/JPY', 'chartSymbol': 'OANDA:GBPJPY', 'category': 'currencies', 'type': 'currencies', 'source': 'tv', 'is_otc': false, 'enabled': true},

    // --- COMMODITIES (metals + energy) ---
    {'symbol': 'XAU/USD', 'chartSymbol': 'OANDA:XAUUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'XAG/USD', 'chartSymbol': 'OANDA:XAGUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'XPT/USD', 'chartSymbol': 'OANDA:XPTUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'XPD/USD', 'chartSymbol': 'OANDA:XPDUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'BRENT/USD', 'chartSymbol': 'OANDA:BRENTUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'WTI/USD', 'chartSymbol': 'OANDA:WTICOUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'NGAS/USD', 'chartSymbol': 'OANDA:NATGASUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'XCU/USD', 'chartSymbol': 'OANDA:XCUUSD', 'category': 'commodities', 'type': 'commodities', 'source': 'tv', 'is_otc': false, 'enabled': true},

    // --- CRYPTO ---
    {'symbol': 'BTC/USDT', 'chartSymbol': 'BINANCE:BTCUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'ETH/USDT', 'chartSymbol': 'BINANCE:ETHUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'BNB/USDT', 'chartSymbol': 'BINANCE:BNBUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'SOL/USDT', 'chartSymbol': 'BINANCE:SOLUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'XRP/USDT', 'chartSymbol': 'BINANCE:XRPUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
    {'symbol': 'ADA/USDT', 'chartSymbol': 'BINANCE:ADAUSDT', 'category': 'crypto', 'type': 'crypto', 'source': 'tv', 'is_otc': false, 'enabled': true},
  ];

  static List<Map<String, dynamic>> currencyPairs = List.from(defaultCurrencyPairs);

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
