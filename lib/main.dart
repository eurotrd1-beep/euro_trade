import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';
import 'constants.dart';
import 'screens/splash_screen.dart';

// TEMP DIAGNOSTIC: surface any startup error on screen instead of a blank page.
void _showErr(String where, Object e, StackTrace? st) {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF0A0714),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text(
            'STARTUP ERROR @ $where\n\n$e\n\n$st',
            style: const TextStyle(color: Color(0xFFFF5555), fontSize: 12, height: 1.4),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) => _showErr('FlutterError', d.exception, d.stack);
    ErrorWidget.builder = (d) => Material(
      color: const Color(0xFF0A0714),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text('WIDGET ERROR\n\n${d.exception}\n\n${d.stack}',
            style: const TextStyle(color: Color(0xFFFF5555), fontSize: 11)),
      ),
    );
    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
    } catch (e, st) {
      _showErr('Supabase.initialize', e, st);
      return;
    }
    await _loadAppTheme();
    runApp(const EuroTradeApp());
  }, (e, st) => _showErr('Zone', e, st));
}

Future<void> _loadAppTheme() async {
  try {
    final row = await Supabase.instance.client
        .from('configs')
        .select('data')
        .eq('id', 'theme')
        .maybeSingle()
        .timeout(const Duration(seconds: 3));
    if (row != null) {
      final data = row['data'] as Map<String, dynamic>? ?? {};
      final primary   = data['primaryColor']   as int?;
      final secondary = data['secondaryColor'] as int?;
      if (primary   != null) AppConstants.accentCyan = Color(primary);
      if (secondary != null) AppConstants.accentBlue = Color(secondary);
    }
  } catch (_) {}
}

class EuroTradeApp extends StatelessWidget {
  const EuroTradeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Euro Trade - Premium VIP Signals',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppConstants.spaceBackground,
        primaryColor: AppConstants.accentCyan,
        colorScheme: ColorScheme.dark(
          primary: AppConstants.accentCyan,
          secondary: AppConstants.accentBlue,
          surface: AppConstants.cardBgColor,
        ),
        dividerTheme: const DividerThemeData(
          color: AppConstants.borderGlow,
          thickness: 1.0,
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}
