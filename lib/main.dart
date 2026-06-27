import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'constants.dart';
import 'screens/splash_screen.dart';
import 'services/fcm_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FcmService.setupBackgroundHandler();
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }
  await _loadAppTheme();
  runApp(const EuroTradeApp());
}

Future<void> _loadAppTheme() async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('configs')
        .doc('theme')
        .get()
        .timeout(const Duration(seconds: 3));
    if (doc.exists) {
      final data = doc.data()!;
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
