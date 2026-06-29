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

  // --- Trading Pairs (Always populated locally, independent of Firestore) ---
  static const List<Map<String, dynamic>> defaultCurrencyPairs = [
    // --- FOREX ---
    {'symbol': 'EUR/USD', 'chartSymbol': 'OANDA:EURUSD', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'GBP/USD', 'chartSymbol': 'OANDA:GBPUSD', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'USD/JPY', 'chartSymbol': 'OANDA:USDJPY', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'USD/CHF', 'chartSymbol': 'OANDA:USDCHF', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'AUD/USD', 'chartSymbol': 'OANDA:AUDUSD', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'USD/CAD', 'chartSymbol': 'OANDA:USDCAD', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'NZD/USD', 'chartSymbol': 'OANDA:NZDUSD', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'EUR/GBP', 'chartSymbol': 'OANDA:EURGBP', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'EUR/JPY', 'chartSymbol': 'OANDA:EURJPY', 'category': 'forex', 'type': 'forex'},
    {'symbol': 'GBP/JPY', 'chartSymbol': 'OANDA:GBPJPY', 'category': 'forex', 'type': 'forex'},

    // --- METALS ---
    {'symbol': 'XAU/USD', 'chartSymbol': 'OANDA:XAUUSD', 'category': 'metals', 'type': 'metals'},
    {'symbol': 'XAG/USD', 'chartSymbol': 'OANDA:XAGUSD', 'category': 'metals', 'type': 'metals'},
    {'symbol': 'XPT/USD', 'chartSymbol': 'OANDA:XPTUSD', 'category': 'metals', 'type': 'metals'},
    {'symbol': 'XPD/USD', 'chartSymbol': 'OANDA:XPDUSD', 'category': 'metals', 'type': 'metals'},

    // --- COMMODITIES ---
    {'symbol': 'BRENT/USD', 'chartSymbol': 'OANDA:BRENTUSD', 'category': 'commodities', 'type': 'commodities'},
    {'symbol': 'WTI/USD', 'chartSymbol': 'OANDA:WTICOUSD', 'category': 'commodities', 'type': 'commodities'},
    {'symbol': 'NGAS/USD', 'chartSymbol': 'OANDA:NATGASUSD', 'category': 'commodities', 'type': 'commodities'},
    {'symbol': 'XCU/USD', 'chartSymbol': 'OANDA:XCUUSD', 'category': 'commodities', 'type': 'commodities'},

    // --- CRYPTO ---
    {'symbol': 'BTC/USDT', 'chartSymbol': 'BINANCE:BTCUSDT', 'category': 'crypto', 'type': 'crypto'},
    {'symbol': 'ETH/USDT', 'chartSymbol': 'BINANCE:ETHUSDT', 'category': 'crypto', 'type': 'crypto'},
    {'symbol': 'BNB/USDT', 'chartSymbol': 'BINANCE:BNBUSDT', 'category': 'crypto', 'type': 'crypto'},
    {'symbol': 'SOL/USDT', 'chartSymbol': 'BINANCE:SOLUSDT', 'category': 'crypto', 'type': 'crypto'},
    {'symbol': 'XRP/USDT', 'chartSymbol': 'BINANCE:XRPUSDT', 'category': 'crypto', 'type': 'crypto'},
    {'symbol': 'ADA/USDT', 'chartSymbol': 'BINANCE:ADAUSDT', 'category': 'crypto', 'type': 'crypto'},
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
