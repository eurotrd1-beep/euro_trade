import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../utils/web_utils.dart';
import '../constants.dart';
import '../widgets/particles.dart';
import '../widgets/trading_background.dart';
import '../services/fcm_service.dart';
import 'main_screen.dart';
import 'notice_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _idController = TextEditingController();
  String _selectedBroker    = 'Quotex';
  String _selectedBrokerKey = 'quotex';
  bool _isVerifying = false;
  String _verificationStepText = '';
  double _verificationProgress = 0.0;
  String? _errorMessage;



  // Notify admin via FCM push when a new user registers
  Future<void> _pingAdminFcm(String accountId, String broker) async {
    try {
      final firestore = FirebaseFirestore.instance;
      // Read admin FCM token
      final tokenDoc = await firestore.collection('configs').doc('adminFcmToken').get();
      final adminToken = tokenDoc.data()?['token'] as String?;
      if (adminToken == null || adminToken.isEmpty) return;

      // Read Service Account credentials (stored by admin in push settings)
      final credsDoc = await firestore.collection('configs').doc('fcm').get();
      final clientEmail = credsDoc.data()?['clientEmail'] as String?;
      final privateKey  = credsDoc.data()?['privateKey']  as String?;
      final projectId   = credsDoc.data()?['projectId']   as String?;
      if (clientEmail == null || privateKey == null || projectId == null) return;

      // Generate signed JWT for Google OAuth2
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final jwt = JWT({
        'iss':   clientEmail,
        'scope': 'https://www.googleapis.com/auth/firebase.messaging',
        'aud':   'https://oauth2.googleapis.com/token',
        'iat':   now,
        'exp':   now + 3600,
      });
      final signed = jwt.sign(RSAPrivateKey(privateKey), algorithm: JWTAlgorithm.RS256);

      // Exchange JWT for access token
      final tokenRes = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$signed',
      );
      final accessToken = (jsonDecode(tokenRes.body) as Map<String, dynamic>)['access_token'] as String?;
      if (accessToken == null) return;

      // Send FCM HTTP v1 push to admin device
      await http.post(
        Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'message': {
            'token': adminToken,
            'notification': {
              'title': '🎉 مستخدم جديد!',
              'body': 'ID: $accountId — $broker',
            },
            'android': {
              'priority': 'high',
              'notification': {'channel_id': 'admin_alerts', 'sound': 'default'},
            },
          },
        }),
      );
    } catch (_) {
      // Silent fail — never block login flow
    }
  }

  // Generate or retrieve persistent device ID
  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('device_id');
    if (deviceId == null || deviceId.isEmpty) {
      // Generate a unique device fingerprint
      final rng = Random.secure();
      final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
      deviceId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('device_id', deviceId);
    }
    return deviceId;
  }

  // Execute verification handshake simulation
  void _startVerification() {
    final accountId = _idController.text.trim();
    if (accountId.isEmpty) {
      setState(() {
        _errorMessage = 'يرجى إدخال معرف حساب صحيح';
      });
      return;
    }
    
    // Simulate simple checks on ID length/characters
    if (accountId.length < 5) {
      setState(() {
        _errorMessage = 'يجب أن يتكون معرف الحساب من 5 أرقام على الأقل';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
      _verificationProgress = 0.0;
    });

    // Firestore Lookup query - started in parallel
    String role = 'standard';
    DateTime? vipExpiry;
    String? deviceMismatchError;
    Future<void> firestoreLookupFuture = Future(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final firestore = FirebaseFirestore.instance;
        final deviceId = await _getDeviceId();
        final doc = await firestore.collection('users').doc(accountId).get();
        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            role = data['role'] ?? 'standard';
            // vipExpiry يمكن أن تكون Timestamp (VIP) أو 0/null (Standard)
            final vipExpiryData = data['vipExpiry'];
            if (vipExpiryData is Timestamp) {
              vipExpiry = vipExpiryData.toDate();
            }

            final storedDeviceId = data['deviceId'];
            final storedClickedBroker = data['clickedBroker'];

            // تحقق من مطابقة الجهاز - VIP يعمل فقط على الجهاز المسجل
            if (role == 'vip' && storedDeviceId != null && storedDeviceId != '' && storedDeviceId != deviceId) {
              deviceMismatchError = 'هذا الحساب VIP مرتبط بجهاز آخر. لا يمكن تسجيل الدخول من هذا الجهاز.';
              return;
            }

            // تحديث deviceId للـ standard دائماً ليكون آخر جهاز استخدمه قبل الترقية،
            // أما للـ VIP فيتم التحديث فقط إذا كان فارغاً
            Map<String, dynamic> updates = {};
            if (role == 'standard' && storedDeviceId != deviceId) {
              updates['deviceId'] = deviceId;
            } else if (storedDeviceId == null || storedDeviceId == '') {
              updates['deviceId'] = deviceId;
            }
            if (data['broker'] != _selectedBroker) {
              updates['broker'] = _selectedBroker;
            }
            if (storedClickedBroker == null) {
              final lastClickedBroker = prefs.getString('last_clicked_broker') ?? '';
              updates['clickedBroker'] = lastClickedBroker;
            }
            if (updates.isNotEmpty) {
              await firestore.collection('users').doc(accountId).update(updates);
            }
          }
        } else {
          final lastClickedBroker = prefs.getString('last_clicked_broker') ?? '';

          // Check globalVip config — new users inherit VIP if it's active
          String newRole = 'standard';
          dynamic newVipExpiry = 0;
          try {
            final globalVipDoc = await firestore
                .collection('configs')
                .doc('globalVip')
                .get();
            if (globalVipDoc.exists) {
              final gd = globalVipDoc.data();
              if (gd?['enabled'] == true && gd?['expiry'] is Timestamp) {
                final expiry = (gd!['expiry'] as Timestamp).toDate();
                if (expiry.isAfter(DateTime.now())) {
                  newRole = 'vip';
                  newVipExpiry = gd['expiry'] as Timestamp;
                  vipExpiry = expiry;
                }
              }
            }
          } catch (_) {}

          role = newRole;
          await firestore.collection('users').doc(accountId).set({
            'accountId': accountId,
            'broker': _selectedBroker,
            'role': newRole,
            'vipExpiry': newVipExpiry,
            'deviceId': deviceId,
            'clickedBroker': lastClickedBroker,
            'createdAt': FieldValue.serverTimestamp(),
          });
          // Fire-and-forget: ping admin with FCM push — never blocks login
          _pingAdminFcm(accountId, _selectedBroker).catchError((_) {});

          // زيادة عداد تسجيلات الدخول — يستخدم clickKey المخزن
          final loginKey = _selectedBrokerKey.isNotEmpty ? _selectedBrokerKey
              : _selectedBroker.toLowerCase().contains('quotex') ? 'quotex'
              : _selectedBroker.toLowerCase().contains('expert') ? 'expert_option'
              : 'pocket_option';
          final loginField = '${loginKey}Logins';
          await firestore.collection('clicks').doc('brokers').set({
            loginField: FieldValue.increment(1),
          }, SetOptions(merge: true));

          // Increment click counter based on broker link clicked in notice screen
          if (lastClickedBroker.isNotEmpty) {
            final savedKey = prefs.getString('last_clicked_broker_key') ?? '';
            final clickField = savedKey.isNotEmpty ? savedKey
                : lastClickedBroker == 'Quotex' ? 'quotex'
                : lastClickedBroker == 'Expert Option' ? 'expert_option'
                : 'pocket_option';
            await firestore.collection('clicks').doc('brokers').set({
              clickField: FieldValue.increment(1),
            }, SetOptions(merge: true));
          }
        }
      } catch (e) {
        debugPrint('Firestore lookup error: $e');
        role = 'standard';
      }
    });

    final steps = [
      {'text': 'جاري الاتصال بخوادم منصة $_selectedBroker الآمنة...', 'progress': 0.15},
      {'text': 'جاري الاستعلام عن سجلات الإحالة النشطة للشركاء...', 'progress': 0.40},
      {'text': 'جاري مطابقة معرف الحساب في شبكة VIP المعتمدة...', 'progress': 0.65},
      {'text': 'تفعيل عضوية غرفة VIP الخاصة بحسابك...', 'progress': 0.85},
      {'text': 'تم تأكيد التفعيل بنجاح! جاري الانتقال لمنصة إشارات VIP...', 'progress': 1.0},
    ];

    int currentStep = 0;
    Timer.periodic(const Duration(milliseconds: 900), (timer) async {
      if (currentStep < steps.length) {
        setState(() {
          _verificationStepText = steps[currentStep]['text'] as String;
          _verificationProgress = steps[currentStep]['progress'] as double;
        });
        currentStep++;
      } else {
        timer.cancel();
        
        // Wait for Firestore lookup to finish if it hasn't already
        await firestoreLookupFuture;

        // Device mismatch check - VIP only works on registered device
        if (deviceMismatchError != null) {
          if (mounted) {
            setState(() {
              _isVerifying = false;
              _errorMessage = deviceMismatchError;
              _verificationProgress = 0.0;
              _verificationStepText = '';
            });
          }
          return;
        }

        // Save verified status in Shared Preferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(AppConstants.keyUserVerified, true);
        await prefs.setString(AppConstants.keyUserAccountId, accountId);
        await prefs.setString(AppConstants.keyUserBroker, _selectedBroker);
        await prefs.setString('user_role', role);
        if (vipExpiry != null) {
          await prefs.setString('vip_expiry', vipExpiry!.toIso8601String());
        } else {
          await prefs.remove('vip_expiry');
        }

        // Init FCM token in background — don't block navigation
        FcmService.initAndSaveToken(accountId).catchError((_) {});

        if (mounted) {
          // Play win/activation sound
          try {
            evalJs(
              "var ctx = new AudioContext(); var osc = ctx.createOscillator(); var g = ctx.createGain(); osc.type='sine'; osc.frequency.setValueAtTime(523, ctx.currentTime); osc.frequency.setValueAtTime(659, ctx.currentTime+0.1); osc.frequency.setValueAtTime(880, ctx.currentTime+0.2); g.gain.setValueAtTime(0.1, ctx.currentTime); g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime+0.5); osc.connect(g); g.connect(ctx.destination); osc.start(); osc.stop(ctx.currentTime+0.5);"
            );
          } catch (_) {}

          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => const MainScreen(),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                return FadeTransition(opacity: animation, child: child);
              },
              transitionDuration: const Duration(milliseconds: 600),
            ),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 700;

    return Scaffold(
      backgroundColor: AppConstants.spaceBackground,
      body: Stack(
        children: [
          const RepaintBoundary(child: TradingBackground()),
          const BackgroundParticles(),
          
          // Outer Glow
          Positioned(
            top: size.height * 0.1,
            left: size.width * 0.1,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppConstants.accentCyan.withAlpha(15),
                    blurRadius: 150,
                    spreadRadius: 20,
                  )
                ],
              ),
            ),
          ),

          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
              child: AnimatedCrossFade(
                crossFadeState: _isVerifying ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 400),
                firstChild: _buildLoginForm(isDesktop),
                secondChild: _buildVerificationHandshake(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // First View: Login & Registration Instructions
  Widget _buildLoginForm(bool isDesktop) {
    return Container(
      width: isDesktop ? 550 : double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppConstants.cardBgColor.withAlpha(220),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppConstants.borderGlow, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(150),
            blurRadius: 40,
            offset: const Offset(0, 20),
          )
        ],
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Logo
            Center(
              child: Container(
                width: 90,
                height: 90,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppConstants.accentCyan.withAlpha(80), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppConstants.accentCyan.withAlpha(20),
                      blurRadius: 15,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    'assets/logo.jpg',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            // Title
            Center(
              child: Column(
                children: [
                  Text(
                    'تسجيل الدخول للـ VIP',
                    style: GoogleFonts.outfit(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'أدخل معرف حساب التداول الخاص بك للتحقق وتفعيل الإشارات',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: AppConstants.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),

            // Step 1: Select Broker
            Text(
              '1. اختر منصة التداول المسجّل بها',
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppConstants.accentCyan,
              ),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('brokers')
                  .orderBy('order')
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData || snap.data!.docs.isEmpty) {
                  return Center(
                    child: Text('جاري تحميل المنصات...',
                        style: GoogleFonts.outfit(color: AppConstants.textSecondary, fontSize: 12)),
                  );
                }
                final docs = snap.data!.docs
                    .where((d) => (d.data() as Map<String, dynamic>)['isActive'] as bool? ?? true)
                    .toList();
                if (docs.isEmpty) {
                  return Center(child: Text('جاري تحميل المنصات...',
                      style: GoogleFonts.outfit(color: AppConstants.textSecondary, fontSize: 12)));
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 10.0;
                    final cardWidth = (constraints.maxWidth - spacing * (docs.length - 1)) / docs.length;
                    return Row(
                      children: docs.asMap().entries.expand((entry) {
                        final i   = entry.key;
                        final doc = entry.value;
                        final d        = doc.data() as Map<String, dynamic>;
                        final name     = d['name']     as String? ?? '';
                        final logoUrl  = d['logoUrl']  as String? ?? '';
                        final clickKey = d['clickKey'] as String? ?? name.toLowerCase().replaceAll(' ', '_');
                        return [
                          if (i > 0) const SizedBox(width: spacing),
                          SizedBox(
                            width: cardWidth,
                            child: _buildBrokerSelectionCard(
                              name: name,
                              logoUrl: logoUrl,
                              clickKey: clickKey,
                              isSelected: _selectedBroker == name,
                            ),
                          ),
                        ];
                      }).toList(),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 25),

            // Step 2: Enter account ID
            Text(
              '2. أدخل معرف حسابك (Account ID)',
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppConstants.accentCyan,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _idController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: GoogleFonts.outfit(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'مثال: 58392019',
                hintStyle: GoogleFonts.outfit(color: AppConstants.textSecondary.withAlpha(100)),
                filled: true,
                fillColor: AppConstants.spaceBackground.withAlpha(180),
                prefixIcon: const Icon(Icons.vpn_key_rounded, color: AppConstants.textSecondary, size: 18),
                errorText: _errorMessage,
                errorStyle: GoogleFonts.outfit(color: AppConstants.putRed),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppConstants.borderGlow),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppConstants.accentCyan),
                ),
              ),
            ),
            const SizedBox(height: 35),

            // Verify Button
            InkWell(
              onTap: _startVerification,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 55,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    colors: [AppConstants.accentCyan, AppConstants.accentBlue],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppConstants.accentCyan.withAlpha(80),
                      blurRadius: 15,
                      offset: const Offset(0, 5),
                    )
                  ],
                ),
                child: Center(
                  child: Text(
                    'التحقق وتنشيط الإشارات ⟵',
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.spaceBackground,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Redirection link back to NoticeScreen instructions
            TextButton(
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const NoticeScreen(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 600),
                  ),
                );
              },
              child: Text(
                'الرجوع لتعليمات تفعيل العضوية والتسجيل',
                style: GoogleFonts.outfit(
                  color: AppConstants.accentCyan,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Selectable Broker Cards
  Widget _buildBrokerSelectionCard({
    required String name,
    required String logoUrl,
    required String clickKey,
    required bool isSelected,
  }) {
    return InkWell(
      onTap: () => setState(() {
        _selectedBroker    = name;
        _selectedBrokerKey = clickKey;
      }),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppConstants.accentCyan.withAlpha(35),
                    AppConstants.accentBlue.withAlpha(22),
                  ],
                )
              : null,
          color: isSelected ? null : AppConstants.spaceBackground.withAlpha(120),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppConstants.accentCyan : AppConstants.borderGlow,
            width: isSelected ? 2.0 : 1.0,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: AppConstants.accentCyan.withAlpha(40), blurRadius: 12)]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? AppConstants.accentCyan : Colors.white.withAlpha(50),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isSelected ? AppConstants.accentCyan.withAlpha(60) : Colors.black.withAlpha(40),
                    blurRadius: isSelected ? 10 : 4,
                  ),
                ],
              ),
              child: ClipOval(
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: _buildLogoImage(logoUrl, fallbackSize: 20),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : AppConstants.textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            AnimatedOpacity(
              opacity: isSelected ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Icon(Icons.check_circle_rounded, color: AppConstants.accentCyan, size: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogoImage(String logoUrl, {double fallbackSize = 30}) {
    if (logoUrl.isEmpty) return Icon(Icons.storefront_rounded, color: Colors.grey, size: fallbackSize);
    if (logoUrl.startsWith('http') || logoUrl.startsWith('data:')) {
      return Image.network(logoUrl, fit: BoxFit.contain,
          errorBuilder: (ctx, err, stack) => Icon(Icons.storefront_rounded, color: Colors.grey, size: fallbackSize));
    }
    return Image.asset(logoUrl, fit: BoxFit.contain);
  }

  // Second View: Verification Progress Handshake Screen
  Widget _buildVerificationHandshake() {
    return Container(
      width: 450,
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppConstants.cardBgColor.withAlpha(220),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppConstants.accentCyan.withAlpha(100), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppConstants.accentCyan.withAlpha(20),
            blurRadius: 30,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: CircularProgressIndicator(
              color: AppConstants.accentCyan,
              strokeWidth: 5,
            ),
          ),
          const SizedBox(height: 40),
          Text(
            'جاري الاتصال والتحقق',
            style: GoogleFonts.outfit(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _verificationStepText,
              key: ValueKey<String>(_verificationStepText),
              textAlign: centerText(),
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: AppConstants.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 30),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: _verificationProgress,
              color: AppConstants.accentCyan,
              backgroundColor: AppConstants.borderGlow,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            'تمت المزامنة بنسبة ${(_verificationProgress * 100).toInt()}%',
            style: GoogleFonts.outfit(
              fontSize: 11,
              color: AppConstants.accentCyan,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  TextAlign centerText() => TextAlign.center;
}
