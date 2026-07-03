import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';
import 'constants.dart';
import 'services/language_service.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }
  await LanguageService.load();
  await _loadAppTheme();
  runApp(const EuroTradeApp());
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
    // Rebuild the whole app (and flip text direction) whenever the language
    // changes, so every inline tr() call re-evaluates.
    return ValueListenableBuilder<AppLanguage?>(
      valueListenable: LanguageService.language,
      builder: (context, lang, child) {
        return MaterialApp(
          title: 'Euro Trade - Premium VIP Signals',
          debugShowCheckedModeBanner: false,
          locale: LanguageService.locale,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('ar'), Locale('en')],
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
      },
    );
  }
}
