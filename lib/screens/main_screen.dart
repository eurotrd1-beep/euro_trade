import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/web_utils.dart';
import '../constants.dart';
import '../services/signal_engine.dart';
import '../widgets/particles.dart';
import '../widgets/trading_background.dart';
import '../widgets/tradingview_chart.dart';
import 'notice_screen.dart';
import 'maintenance_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late SignalEngine _signalEngine;
  String _userAccountId = '----';
  String _userBroker = 'Quotex';
  bool _soundEnabled = true;
  String _selectedCategory = 'forex';
  int _selectedMinutes = 1;
  double Function()? _tvPriceGetter;
  TradingSignal? _lastProcessedSignal;
  String _searchQuery = '';
  String _historyFilter = 'today';
  DateTimeRange? _customDateRange;
  StreamSubscription<DocumentSnapshot>? _roleListener;
  StreamSubscription<DocumentSnapshot>? _maintenanceListener;
  StreamSubscription<DocumentSnapshot>? _stdStrategyListener;
  StreamSubscription<DocumentSnapshot>? _vipStrategyListener;
  StreamSubscription<DocumentSnapshot>? _chartModeListener;
  StreamSubscription<QuerySnapshot>?    _pairsListener;
  String _chartMode = 'sim';
  String _activeChartSymbol = '';
  String _brokerLogoUrl = '';
  bool _updateChecked = false;

  // OTC pairs fetched from proxy server
  List<Map<String, String>> _otcPairs = [];
  bool _otcPairsLoading = false;

  @override
  void initState() {
    super.initState();
    _signalEngine = SignalEngine();
    _signalEngine.addListener(_onSignalEngineUpdate);
    _loadUserData();
    _startMaintenanceListener();

    _selectedCategory = 'forex';
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final accountId = prefs.getString(AppConstants.keyUserAccountId) ?? '8392019';
    final brokerName = prefs.getString(AppConstants.keyUserBroker) ?? 'Quotex';
    setState(() {
      _userAccountId = accountId;
      _userBroker    = brokerName;
    });
    _signalEngine.setAccountId(accountId);
    _startRoleListener(accountId);
    _startStrategyListeners();
    _startChartModeListener();
    _startPairsListener();
    _loadBrokerLogo(brokerName);
    setUserBroker(brokerName);
    // Delay update check so it doesn't block startup rendering
    Future.delayed(const Duration(seconds: 2), () => _checkForUpdate());
  }

  Future<void> _loadBrokerLogo(String brokerName) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('brokers')
          .where('name', isEqualTo: brokerName)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty && mounted) {
        final url = snap.docs.first.data()['logoUrl'] as String? ?? '';
        if (url.isNotEmpty) setState(() => _brokerLogoUrl = url);
      }
    } catch (_) {}
  }

  /// Fetches available OTC pairs for the user's broker from the proxy server.
  Future<void> _fetchOtcPairs() async {
    if (_otcPairsLoading) return;
    setState(() => _otcPairsLoading = true);
    try {
      final broker = Uri.encodeComponent(_userBroker);
      final res = await http
          .get(Uri.parse(
              'https://euro-trade-proxy.onrender.com/api/otc/pairs?broker=$broker'))
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final body   = jsonDecode(res.body) as Map<String, dynamic>;
        final raw    = (body['pairs'] as List<dynamic>? ?? []).cast<String>();
        final pairs  = raw.map((sym) => <String, String>{
          'symbol':      _otcSymToDisplay(sym),
          'chartSymbol': sym,
          'category':    'otc',
          'type':        'OTC',
          'label':       '',
        }).toList();
        setState(() { _otcPairs = pairs; _otcPairsLoading = false; });
      } else {
        setState(() => _otcPairsLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _otcPairsLoading = false);
    }
  }

  String _otcSymToDisplay(String sym) {
    // EURUSD_OTC → EUR/USD OTC
    final base = sym.replaceAll('_OTC', '').toUpperCase();
    if (base.length >= 6) return '${base.substring(0, 3)}/${base.substring(3)} OTC';
    return sym;
  }

  void _startRoleListener(String accountId) {
    _roleListener?.cancel();
    _roleListener = FirebaseFirestore.instance
        .collection('users')
        .doc(accountId)
        .snapshots()
        .listen((doc) async {
      if (!doc.exists || !mounted) return;
      final data = doc.data();
      if (data == null) return;

      // Real-time ban check
      final isBanned  = data['isBanned'] as bool? ?? false;
      final banReason = data['banReason'] as String? ?? '';
      if (isBanned) {
        _roleListener?.cancel();
        _maintenanceListener?.cancel();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showBanDialog(banReason);
        });
        return;
      }

      final newRole = data['role'] ?? 'standard';
      final vipExpiryData = data['vipExpiry'];
      DateTime? newExpiry;
      if (vipExpiryData is Timestamp) {
        newExpiry = vipExpiryData.toDate();
      }

      final guaranteedWin = data['guaranteedWin'] as bool? ?? false;
      _signalEngine.updateGuaranteedWin(guaranteedWin);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_role', newRole);
      if (newExpiry != null) {
        await prefs.setString('vip_expiry', newExpiry.toIso8601String());
      } else {
        await prefs.remove('vip_expiry');
      }

      _signalEngine.updateUserData(newRole, newExpiry);
    });
  }

  void _startMaintenanceListener() {
    _maintenanceListener?.cancel();
    _maintenanceListener = FirebaseFirestore.instance
        .collection('configs')
        .doc('maintenance')
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final d = doc.data();
      if (d == null) return;
      final isActive = d['isActive'] as bool? ?? false;
      if (!isActive) return;
      final endsAtRaw = d['endsAt'];
      final endsAt = endsAtRaw is Timestamp ? endsAtRaw.toDate() : null;
      if (endsAt != null && endsAt.isBefore(DateTime.now())) return;
      // Maintenance just activated — route away
      _roleListener?.cancel();
      _maintenanceListener?.cancel();
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (context, animation, _) => const MaintenanceScreen(),
        transitionsBuilder: (_, anim, secondary, child) => FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 600),
      ));
    });
  }

  Future<void> _checkForUpdate() async {
    if (_updateChecked || !mounted) return;
    _updateChecked = true;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('configs')
          .doc('appUpdate')
          .get();
      if (!doc.exists || !mounted) return;
      final d = doc.data();
      if (d == null) return;
      final hasUpdate = d['hasUpdate'] as bool? ?? false;
      if (!hasUpdate) return;
      final version  = d['version']      as String? ?? '';
      final link     = d['downloadLink'] as String? ?? '';
      final isForced = d['isForced']     as bool?   ?? false;
      final features = (d['features']    as List<dynamic>? ?? []).cast<String>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpdateDialog(version, features, link, isForced);
      });
    } catch (_) {}
  }

  void _showUpdateDialog(String version, List<String> features, String link, bool isForced) {
    showDialog(
      context: context,
      barrierDismissible: !isForced,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: AppConstants.cardBgColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: AppConstants.accentCyan.withAlpha(100), width: 1.5),
          ),
          title: Row(children: [
            Icon(Icons.system_update_alt_rounded, color: AppConstants.accentCyan, size: 22),
            const SizedBox(width: 10),
            Text('تحديث جديد متاح 🚀',
                style: GoogleFonts.outfit(color: AppConstants.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('النسخة الجديدة: $version',
                  style: GoogleFonts.outfit(color: AppConstants.accentCyan, fontWeight: FontWeight.bold)),
              if (features.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('المميزات الجديدة:', style: GoogleFonts.outfit(color: AppConstants.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                ...features.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('• ', style: GoogleFonts.outfit(color: AppConstants.callGreen)),
                    Expanded(child: Text(f, style: GoogleFonts.outfit(color: AppConstants.textSecondary, fontSize: 12, height: 1.5))),
                  ]),
                )),
              ],
              if (isForced) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppConstants.putRed.withAlpha(15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppConstants.putRed.withAlpha(60)),
                  ),
                  child: Text('⚠️ هذا التحديث إجباري ولا يمكن تخطيه',
                      style: GoogleFonts.outfit(color: AppConstants.putRed, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
          actions: [
            if (!isForced)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('لاحقاً', style: GoogleFonts.outfit(color: AppConstants.textSecondary)),
              ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                if (link.isNotEmpty) openBrowserTab(link);
              },
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text('تحميل التحديث', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.accentCyan,
                foregroundColor: AppConstants.spaceBackground,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brokerLogoFallback() {
    return Image.asset(
      _userBroker.toLowerCase().contains('quotex')
          ? 'assets/quotex.png'
          : _userBroker.toLowerCase().contains('expert')
              ? 'assets/expert_option.png'
              : 'assets/pocket_option.png',
      fit: BoxFit.contain,
    );
  }

  void _showBanDialog(String reason) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: AppConstants.cardBgColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: AppConstants.putRed.withAlpha(100), width: 1.5),
          ),
          title: Row(children: [
            const Icon(Icons.block_rounded, color: AppConstants.putRed, size: 22),
            const SizedBox(width: 10),
            Text('تم حظر حسابك', style: GoogleFonts.outfit(color: AppConstants.textPrimary, fontWeight: FontWeight.bold)),
          ]),
          content: Text(
            reason.isNotEmpty
                ? 'تم حظر حسابك من قِبَل الإدارة.\nالسبب: $reason'
                : 'تم حظر حسابك من قِبَل الإدارة.\nللمزيد من المعلومات تواصل مع الدعم.',
            style: GoogleFonts.outfit(color: AppConstants.textSecondary, height: 1.6),
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _logout();
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppConstants.putRed, foregroundColor: Colors.white),
              child: Text('موافق', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    _roleListener?.cancel();
    _maintenanceListener?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, _) => const NoticeScreen(),
          transitionsBuilder: (_, anim, secondary, child) => FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    }
  }

  void _onSignalEngineUpdate() {
    if (_signalEngine.vipJustExpired) {
      _signalEngine.clearVipJustExpired();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showVipExpiredDialog(context);
        }
      });
    }

    final activeSignal = _signalEngine.activeSignal;
    if (activeSignal != null &&
        (activeSignal.status == 'WIN' || activeSignal.status == 'LOSS') &&
        activeSignal != _lastProcessedSignal) {
      _lastProcessedSignal = activeSignal;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showTradeReviewDialog(context, activeSignal);
        }
      });
    }
  }

  void _showVipExpiredDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (BuildContext context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: AppConstants.cardBgColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: AppConstants.putRed.withAlpha(100), width: 1.5),
            ),
            title: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppConstants.putRed, size: 28),
                const SizedBox(width: 10),
                Text(
                  'انتهى اشتراك VIP ⚠️',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            content: Text(
              'انتهى اشتراكك الـ VIP الخاص بك. تم إعادتك للباقة القياسية (Standard) بنجاح. يمكنك الترقية مجدداً في أي وقت.',
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: AppConstants.textSecondary,
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: Text(
                  'موافق',
                  style: GoogleFonts.outfit(
                    color: AppConstants.accentCyan,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Map<String, int> _getVipCountdownParts(DateTime? expiry) {
    if (expiry == null) return {'d': 0, 'h': 0, 'm': 0, 's': 0};
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return {'d': 0, 'h': 0, 'm': 0, 's': 0};
    return {
      'd': diff.inDays,
      'h': diff.inHours % 24,
      'm': diff.inMinutes % 60,
      's': diff.inSeconds % 60,
    };
  }



  void _showTradeReviewDialog(BuildContext context, TradingSignal signal) {
    final isWin = signal.status == 'WIN';
    final profitColor = isWin ? AppConstants.callGreen : AppConstants.putRed;
    final outcomeText = isWin ? 'صفقة ناجحة' : 'صفقة خاسرة';

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          child: Container(
            width: min(MediaQuery.of(context).size.width, 420),
            decoration: BoxDecoration(
              color: AppConstants.cardBgColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppConstants.borderGlow, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: profitColor.withAlpha(20),
                  blurRadius: 25,
                  spreadRadius: 5,
                ),
              ],
            ),
            padding: const EdgeInsets.all(20),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Title / Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isWin
                            ? Icons.check_circle_outline_rounded
                            : Icons.info_outline_rounded,
                        color: profitColor,
                        size: 26,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'مراجعة الصفقة المغلقة',
                        style: GoogleFonts.outfit(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: AppConstants.borderGlow, height: 24),

                  // Big Outcome Badge
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: profitColor.withAlpha(15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: profitColor.withAlpha(80),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          outcomeText,
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: profitColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Trade Stats Table
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppConstants.spaceBackground.withAlpha(150),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppConstants.borderGlow.withAlpha(120),
                      ),
                    ),
                    child: Column(
                      children: [
                        _buildDialogStatRow(
                          'زوج العملات / الأصول',
                          signal.pair,
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'نوع الاتجاه',
                          signal.direction == 'CALL' ? 'صعود 🟢' : 'هبوط 🔴',
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'مستوى الدخول',
                          AppConstants.formatPrice(signal.entryPrice),
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'مستوى الإغلاق',
                          AppConstants.formatPrice(
                            signal.exitPrice ?? signal.currentPrice,
                          ),
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'المدة المحددة',
                          '${signal.durationMinutes} دقيقة',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Continue Button
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConstants.accentBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      shadowColor: AppConstants.accentBlue.withAlpha(120),
                      elevation: 8,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'متابعة الصفقة التالية 🚀',
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDialogStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 12,
            color: AppConstants.textSecondary,
          ),
        ),
        Text(
          value,
          style: GoogleFonts.outfit(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: AppConstants.textPrimary,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _roleListener?.cancel();
    _maintenanceListener?.cancel();
    _stdStrategyListener?.cancel();
    _vipStrategyListener?.cancel();
    _chartModeListener?.cancel();
    _pairsListener?.cancel();
    _signalEngine.removeListener(_onSignalEngineUpdate);
    _signalEngine.dispose();
    super.dispose();
  }

  void _startChartModeListener() {
    _chartModeListener?.cancel();
    _chartModeListener = FirebaseFirestore.instance
        .collection('configs')
        .doc('chart_settings')
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data();
      if (data == null) return;
      final mode = data['mode'] as String? ?? 'sim';
      final resolved = mode == 'tv' ? 'tv' : 'sim';
      if (resolved != _chartMode) {
        setState(() {
          _chartMode = resolved;
          // OTC tab/pairs are hidden in tv mode — fall back to forex
          if (resolved == 'tv' && _selectedCategory == 'otc') {
            _selectedCategory = 'forex';
          }
        });
      }
    });
  }

  void _startPairsListener() {
    _pairsListener?.cancel();
    _pairsListener = FirebaseFirestore.instance
        .collection('pairs')
        .orderBy('order')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final pairs = snap.docs.map((d) {
        final data = d.data();
        return <String, dynamic>{
          'id':          d.id,
          'symbol':      data['symbol']      as String? ?? '',
          'chartSymbol': data['chartSymbol'] as String? ?? '',
          'category':    data['category']    as String? ?? 'forex',
          'type':        data['type']        as String? ?? 'forex',
          'label':       data['label']       as String? ?? '',
        };
      }).where((p) => (p['symbol'] as String).isNotEmpty).toList();

      setState(() {
        AppConstants.currencyPairs = pairs;
        if (_activeChartSymbol.isEmpty && pairs.isNotEmpty) {
          _activeChartSymbol = pairs.first['chartSymbol'] as String? ?? '';
        }
      });
    });
  }

  void _startStrategyListeners() {
    _stdStrategyListener?.cancel();
    _vipStrategyListener?.cancel();

    _stdStrategyListener = FirebaseFirestore.instance
        .collection('configs')
        .doc('strategy_standard')
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data();
      if (data != null) _signalEngine.updateStandardStrategy(data);
    });

    _vipStrategyListener = FirebaseFirestore.instance
        .collection('configs')
        .doc('strategy_vip')
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data();
      if (data != null) _signalEngine.updateVipStrategy(data);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 950;

    return Scaffold(
      backgroundColor: AppConstants.spaceBackground,
      body: Stack(
        children: [
          // Static background layers — isolated from signal engine rebuilds
          const RepaintBoundary(child: TradingBackground()),
          const BackgroundParticles(),
          Positioned(
            top: -100,
            right: -100,
            child: IgnorePointer(
              child: SizedBox(
                width: 300,
                height: 300,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppConstants.accentBlue.withAlpha(15),
                        blurRadius: 100,
                        spreadRadius: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Dynamic content — only this subtree rebuilds when engine notifies
          SafeArea(
            child: AnimatedBuilder(
              animation: _signalEngine,
              builder: (context, child) {
                return Column(
                  children: [
                    _buildHeader(),
                    _buildAssetSelector(),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: isDesktop
                            ? _buildDesktopLayout()
                            : _buildMobileLayout(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // HEADER: VIP User Banner & Log Out
  Widget _buildHeader() {
    final isVip = _signalEngine.userRole == 'vip';
    final size = MediaQuery.of(context).size;
    final isSmall = size.width < 750;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppConstants.cardBgColor.withAlpha(180),
        border: const Border(
          bottom: BorderSide(color: AppConstants.borderGlow),
        ),
      ),
      child: isSmall
          ? Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildUserInfoSection(isVip),
                    _buildHeaderActionsRow(),
                  ],
                ),
                const SizedBox(height: 12),
                _buildVipBannerSection(isVip),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildUserInfoSection(isVip),
                _buildVipBannerSection(isVip),
                _buildHeaderActionsRow(),
              ],
            ),
    );
  }

  Widget _buildUserInfoSection(bool isVip) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppConstants.accentCyan.withAlpha(100),
              width: 1.2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.asset('assets/logo.jpg', fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isVip ? 'VIP USER: $_userAccountId' : 'USER: $_userAccountId',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isVip ? Colors.amber : Colors.grey.shade700,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isVip ? Colors.amberAccent : Colors.white.withAlpha(50),
                    ),
                    boxShadow: isVip
                        ? [
                            BoxShadow(
                              color: Colors.amber.withAlpha(80),
                              blurRadius: 4,
                            )
                          ]
                        : null,
                  ),
                  child: Text(
                    isVip ? 'VIP PREMIUM' : 'STANDARD',
                    style: GoogleFonts.outfit(
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                      color: isVip ? Colors.black : Colors.white70,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppConstants.borderGlow,
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(40),
                        blurRadius: 2,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Padding(
                      padding: const EdgeInsets.all(1.0),
                      child: _brokerLogoUrl.isNotEmpty
                          ? Image.network(_brokerLogoUrl, fit: BoxFit.contain,
                              errorBuilder: (ctx, err, stack) => _brokerLogoFallback())
                          : _brokerLogoFallback(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isVip ? 'منصة التداول: $_userBroker VIP' : 'منصة التداول: $_userBroker',
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppConstants.accentCyan,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVipBannerSection(bool isVip) {
    if (isVip) {
      final parts = _getVipCountdownParts(_signalEngine.vipExpiry);
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ينتهي الـ VIP خلال',
              style: GoogleFonts.outfit(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.amber.withAlpha(180),
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCountdownBox(parts['d']!, 'يوم'),
                _buildCountdownSeparator(),
                _buildCountdownBox(parts['h']!, 'ساعة'),
                _buildCountdownSeparator(),
                _buildCountdownBox(parts['m']!, 'دقيقة'),
                _buildCountdownSeparator(),
                _buildCountdownBox(parts['s']!, 'ثانية'),
              ],
            ),
          ],
        ),
      );
    } else {
      return InkWell(
        onTap: () => openBrowserTab('https://t.me/euro_trd1'),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Colors.amberAccent, Colors.orangeAccent],
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.amber.withAlpha(60),
                blurRadius: 12,
                offset: const Offset(0, 2),
              )
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded, color: Colors.black, size: 16),
              const SizedBox(width: 6),
              Text(
                'ترقية الحساب إلى VIP 👑',
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildCountdownBox(int value, String label) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.amber.withAlpha(20),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.amber.withAlpha(100), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.amber.withAlpha(30),
            blurRadius: 6,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.toString().padLeft(2, '0'),
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Colors.amberAccent,
              letterSpacing: 1,
            ),
          ),
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 8,
              fontWeight: FontWeight.w600,
              color: Colors.amber.withAlpha(180),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdownSeparator() {
    return Text(
      ':',
      style: GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: Colors.amber.withAlpha(150),
      ),
    );
  }

  Widget _buildHeaderActionsRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () {
            setState(() {
              _soundEnabled = !_soundEnabled;
            });
          },
          icon: Icon(
            _soundEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            color: _soundEnabled ? AppConstants.accentCyan : AppConstants.textSecondary,
            size: 20,
          ),
          tooltip: 'Sound Notifications',
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _logout,
          icon: const Icon(
            Icons.logout_rounded,
            color: AppConstants.putRed,
            size: 16,
          ),
          label: Text(
            'EXIT',
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppConstants.putRed,
            ),
          ),
        ),
      ],
    );
  }

  // Horizontal Categorized Asset/Currency Selector
  Widget _buildAssetSelector() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D0A1B),
        border: Border(bottom: BorderSide(color: AppConstants.borderGlow)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Category Selector Row
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E1736))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _buildCategoryTab(
                    'forex',
                    'فوركس',
                    Icons.currency_exchange_rounded,
                  ),
                  if (_chartMode != 'tv')
                    _buildCategoryTab(
                      'otc',
                      'OTC',
                      Icons.bolt_rounded,
                    ),
                  _buildCategoryTab(
                    'metals',
                    'معادن',
                    Icons.diamond_rounded,
                  ),
                  _buildCategoryTab(
                    'commodities',
                    'سلع',
                    Icons.local_gas_station_rounded,
                  ),
                  _buildCategoryTab(
                    'crypto',
                    'كريبتو',
                    Icons.currency_bitcoin_rounded,
                  ),
                ],
              ),
            ),
          ),

          // Dropdown Active Pair Selector Box
          Padding(
            padding: const EdgeInsets.all(12),
            child: InkWell(
              onTap: _showSearchableAssetBottomSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppConstants.cardBgColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppConstants.borderGlow),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(50),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(
                      Icons.arrow_drop_down_circle_outlined,
                      color: AppConstants.accentCyan,
                      size: 22,
                    ),
                    Row(
                      children: [
                        Text(
                          _signalEngine.activePair,
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_signalEngine.activePair.contains('OTC'))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppConstants.warningOrange.withAlpha(35),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'OTC',
                              style: GoogleFonts.outfit(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: AppConstants.warningOrange,
                              ),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.currency_exchange_rounded,
                          color: AppConstants.accentCyan,
                          size: 18,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSearchableAssetBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            // OTC category: use server-fetched pairs; others: use Firestore pairs
            final sourcePairs = _selectedCategory == 'otc'
                ? _otcPairs.cast<Map<String, dynamic>>()
                : AppConstants.currencyPairs
                    .where((pair) => pair['category'] == _selectedCategory)
                    .where((pair) => _chartMode != 'tv' || pair['type'] != 'OTC')
                    .toList();

            final filteredPairs = sourcePairs.where((pair) {
              if (_searchQuery.isEmpty) return true;
              return (pair['symbol'] as String)
                  .toLowerCase()
                  .contains(_searchQuery.toLowerCase());
            }).toList();

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: BoxDecoration(
                color: AppConstants.cardBgColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
                border: const Border(
                  top: BorderSide(color: AppConstants.borderGlow, width: 1.5),
                ),
              ),
              child: Column(
                children: [
                  // Drag Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 5,
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: AppConstants.textSecondary.withAlpha(80),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),

                  // Header with category title and close button
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'اختر الأصل للتداول',
                          style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),

                  // Search input field
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppConstants.spaceBackground,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppConstants.borderGlow),
                      ),
                      child: TextField(
                        style: GoogleFonts.outfit(color: Colors.white),
                        textAlign: TextAlign.right,
                        decoration: InputDecoration(
                          hintText: 'البحث عن أصول (مثال: USD)...',
                          hintStyle: GoogleFonts.outfit(
                            color: AppConstants.textSecondary,
                            fontSize: 13,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            color: AppConstants.accentCyan,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (val) {
                          setModalState(() {
                            _searchQuery = val;
                          });
                        },
                      ),
                    ),
                  ),

                  // List of pairs
                  Expanded(
                    child: _selectedCategory == 'otc' && _otcPairsLoading
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: AppConstants.warningOrange, strokeWidth: 2),
                                const SizedBox(height: 12),
                                Text('جاري جلب أزواج OTC من السيرفر...',
                                    style: GoogleFonts.outfit(color: AppConstants.textSecondary, fontSize: 12)),
                              ],
                            ),
                          )
                        : filteredPairs.isEmpty
                        ? Center(
                            child: Text(
                              _selectedCategory == 'otc'
                                  ? 'لا توجد أزواج OTC متاحة حالياً\nتأكد أن السيرفر شغال وفيه بيانات'
                                  : 'لا توجد أصول تطابق البحث',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.outfit(
                                color: AppConstants.textSecondary,
                                height: 1.5,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            itemCount: filteredPairs.length,
                            itemBuilder: (context, index) {
                              final pair = filteredPairs[index];
                              final isSelected =
                                  _signalEngine.activePair == pair['symbol'];

                              final payout =
                                  85 + (pair['symbol'].hashCode % 11);

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: InkWell(
                                  onTap: () {
                                    _signalEngine.selectPair(pair['symbol']);
                                    final cs = pair['chartSymbol'] as String? ?? '';
                                    if (cs.isNotEmpty) setState(() => _activeChartSymbol = cs);
                                    Navigator.pop(context);
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? AppConstants.accentBlue.withAlpha(
                                              25,
                                            )
                                          : AppConstants.spaceBackground
                                                .withAlpha(120),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? AppConstants.accentBlue
                                            : AppConstants.borderGlow,
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Left side: Payout percentage badge
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: AppConstants.callGreen
                                                    .withAlpha(25),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: AppConstants.callGreen
                                                      .withAlpha(80),
                                                ),
                                              ),
                                              child: Text(
                                                '$payout%',
                                                style: GoogleFonts.outfit(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: AppConstants.callGreen,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            if (pair['type'] == 'OTC')
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: AppConstants
                                                      .warningOrange
                                                      .withAlpha(30),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'OTC',
                                                  style: GoogleFonts.outfit(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: AppConstants
                                                        .warningOrange,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        // Right side: Symbol + optional label
                                        Row(
                                          children: [
                                            Text(
                                              pair['symbol'],
                                              style: GoogleFonts.outfit(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: isSelected
                                                    ? Colors.white
                                                    : AppConstants.textPrimary,
                                              ),
                                            ),
                                            if ((pair['label'] as String? ?? '').isNotEmpty) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: AppConstants.accentBlue.withAlpha(30),
                                                  borderRadius: BorderRadius.circular(4),
                                                  border: Border.all(color: AppConstants.accentBlue.withAlpha(80)),
                                                ),
                                                child: Text(
                                                  pair['label'] as String,
                                                  style: GoogleFonts.outfit(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w600,
                                                    color: AppConstants.accentBlue,
                                                  ),
                                                ),
                                              ),
                                            ],
                                            const SizedBox(width: 10),
                                            Icon(
                                              Icons.currency_exchange_rounded,
                                              color: AppConstants.accentCyan,
                                              size: 18,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      setState(() {
        _searchQuery = '';
      });
    });
  }

  Widget _buildCategoryTab(String categoryId, String label, IconData icon) {
    final isSelected = _selectedCategory == categoryId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () {
          setState(() => _selectedCategory = categoryId);
          if (categoryId == 'otc') _fetchOtcPairs();
        },
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? AppConstants.accentCyan.withAlpha(25)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? AppConstants.accentCyan.withAlpha(150)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected
                    ? AppConstants.accentCyan
                    : AppConstants.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : AppConstants.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // DESKTOP LAYOUT
  Widget _buildDesktopLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Column(
            children: [
              _buildChartCard(),
              const SizedBox(height: 20),
              _buildAIAnalysisCard(),
              const SizedBox(height: 20),
              _buildSignalHistoryCard(),
            ],
          ),
        ),
        const SizedBox(width: 20),
        Expanded(flex: 1, child: Column(children: [_buildLiveFeedCard()])),
      ],
    );
  }

  // MOBILE LAYOUT
  Widget _buildMobileLayout() {
    return Column(
      children: [
        _buildChartCard(),
        const SizedBox(height: 20),
        _buildAIAnalysisCard(),
        const SizedBox(height: 20),
        _buildSignalHistoryCard(),
        const SizedBox(height: 20),
        _buildLiveFeedCard(),
      ],
    );
  }

  // WIDGET: Chart + Signal Panel (combined card)
  Widget _buildChartCard() {
    final chartSymbol = _activeChartSymbol.isNotEmpty
        ? _activeChartSymbol
        : AppConstants.chartSymbolFor(_signalEngine.activePair);
    final tf = _signalEngine.chartTimeframe;
    final signal = _signalEngine.activeSignal;
    final isActive = signal?.status == 'ACTIVE';

    final accentColor = signal == null || _signalEngine.isAnalyzing
        ? AppConstants.accentCyan
        : signal.direction == 'WAIT'
            ? AppConstants.warningOrange
            : signal.direction == 'CALL'
                ? AppConstants.callGreen
                : AppConstants.putRed;

    return _buildGlassCard(
      borderColor: isActive ? accentColor.withAlpha(100) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Chart Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: AppConstants.accentCyan.withAlpha(15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.candlestick_chart_rounded,
                        color: AppConstants.accentCyan, size: 16),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('LIVE CHART',
                          style: GoogleFonts.outfit(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textSecondary,
                              letterSpacing: 1.5)),
                      Text(chartSymbol,
                          style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: Colors.white)),
                    ],
                  ),
                ]),
                Row(
                  children: ['1m', '5m', '15m', '1h', '1D']
                      .map(_buildTimeframeButton)
                      .toList(),
                ),
              ],
            ),
          ),

          // ── Chart ──
          TradingViewChart(
            symbol: chartSymbol,
            interval: tf,
            mode: _chartMode,
            guaranteedWin: _signalEngine.isGuaranteedWin,
            signalDirection: isActive ? signal!.direction : null,
            signalEntryPrice: signal?.entryPrice,
            signalDurationMin: signal?.durationMinutes,
            onReady: (getter) => _tvPriceGetter = getter,
          ),

          // ── Divider ──
          const Divider(color: AppConstants.borderGlow, height: 1),

          // ── Signal Panel ──
          _buildSignalPanel(),
        ],
      ),
    );
  }

  // WIDGET: Signal Panel (embedded inside chart card)
  Widget _buildSignalPanel() {
    // 1. Analyzing State
    if (_signalEngine.isAnalyzing) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 120,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: AppConstants.accentCyan,
                  strokeWidth: 2.0,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'VIP SYSTEM RADAR ANALYSIS',
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: AppConstants.textSecondary,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _signalEngine.analysisStageText,
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.accentCyan,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final signal = _signalEngine.activeSignal;

    // 2. Idle State
    if (signal == null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppConstants.accentCyan.withAlpha(15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.psychology_rounded,
                    color: AppConstants.accentCyan, size: 16),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('VIP ALGORITHM SENSOR',
                      style: GoogleFonts.outfit(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textSecondary,
                          letterSpacing: 1.5)),
                  const SizedBox(height: 2),
                  Text('التحليل جاهز للاستخراج',
                      style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: Colors.white)),
                ],
              ),
            ]),
            const Divider(color: AppConstants.borderGlow, height: 16),
            Text(
              'اضغط أدناه لبدء تحليل شامل للزوج ${_signalEngine.activePair} بفريم ${_signalEngine.chartTimeframe} واستخراج الصفقة ذات الاحتمالية الأكبر.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                  fontSize: 11, color: AppConstants.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            _buildDurationSelector(),
            const SizedBox(height: 12),
            _buildRequestButton(enabled: true, text: 'استخراج الإشارة التالية ⚡'),
          ],
        ),
      );
    }

    // 3. Active / Outcome State
    final isCall = signal.direction == 'CALL';
    final isWait = signal.direction == 'WAIT';
    final accentColor = isWait
        ? AppConstants.warningOrange
        : (isCall ? AppConstants.callGreen : AppConstants.putRed);
    final remainingTime = _signalEngine.secondsRemaining;
    final isActive = signal.status == 'ACTIVE';

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isWait
                    ? 'RECOMMENDED WAIT ⚠️'
                    : (isActive ? 'ACTIVE VIP SIGNAL' : 'SIGNAL COMPLETED'),
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isWait
                      ? AppConstants.warningOrange
                      : (isActive
                          ? AppConstants.textSecondary
                          : (signal.status == 'WIN'
                              ? AppConstants.callGreen
                              : AppConstants.putRed)),
                  letterSpacing: 2,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: accentColor.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: accentColor.withAlpha(80)),
                ),
                child: Row(children: [
                  Icon(
                    isWait
                        ? Icons.hourglass_empty_rounded
                        : (isCall
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded),
                    color: accentColor,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isWait ? 'انتظار (WAIT)' : (isCall ? 'صعود (CALL)' : 'هبوط (PUT)'),
                    style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: accentColor),
                  ),
                ]),
              ),
            ],
          ),
            const Divider(color: AppConstants.borderGlow, height: 16),

            // Grid of signals metrics
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildSignalMetric(
                  label: 'STRIKE ACCURACY',
                  value: isWait ? 'N/A' : '${signal.confidence.toStringAsFixed(1)}%',
                  valueColor: isWait ? AppConstants.textSecondary : AppConstants.accentCyan,
                ),
                _buildSignalMetric(
                  label: 'ENTRY PRICE',
                  value: isWait ? 'N/A' : AppConstants.formatPrice(signal.entryPrice),
                  valueColor: isWait ? AppConstants.textSecondary : Colors.white,
                ),
                _buildSignalMetric(
                  label: 'TIMEFRAME',
                  value: '${signal.durationMinutes} MIN',
                  valueColor: AppConstants.warningOrange,
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (isWait) ...[
              // No transaction progress or result badge
            ] else if (isActive) ...[
              // Expiry countdown progress
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        remainingTime > 0
                            ? 'ACTIVE TRANSACTION SECONDS'
                            : 'FINISHING TRANSACTION...',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          color: AppConstants.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '$remainingTime s',
                        style: GoogleFonts.outfit(
                          fontSize: 11,
                          color: accentColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: remainingTime / (signal.durationMinutes * 60),
                      color: remainingTime <= 10
                          ? AppConstants.warningOrange
                          : accentColor,
                      backgroundColor: AppConstants.spaceBackground,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _signalEngine.signalChangeNotice.isNotEmpty
                          ? _signalEngine.signalChangeNotice
                          : 'ملاحظة: بدأت هذه الصفقة مع بداية الشمعة الحالية',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(
                        fontSize: 10,
                        color: _signalEngine.signalChangeNotice.isNotEmpty
                            ? AppConstants.warningOrange
                            : AppConstants.accentCyan,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Completed Result Badge
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color:
                      (signal.status == 'WIN'
                              ? AppConstants.callGreen
                              : AppConstants.putRed)
                          .withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        (signal.status == 'WIN'
                                ? AppConstants.callGreen
                                : AppConstants.putRed)
                            .withAlpha(40),
                  ),
                ),
                child: Center(
                  child: Text(
                    signal.status == 'WIN'
                        ? 'SUCCESSFUL SIGNAL: WIN 🟢'
                        : 'COMPLETED SIGNAL: LOSS 🔴',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: signal.status == 'WIN'
                          ? AppConstants.callGreen
                          : AppConstants.putRed,
                    ),
                  ),
                ),
              ),
            ],

            // Recommendation Card (Market Condition & Action Recommendation)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: accentColor.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accentColor.withAlpha(40)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isWait ? Icons.warning_amber_rounded : Icons.gpp_good_rounded,
                        color: accentColor,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isWait ? 'حالة السوق: تذبذب وحالة غير آمنة ⚠️' : 'حالة السوق: دخول آمن ومستقر ✅',
                        style: GoogleFonts.outfit(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    signal.marketCondition,
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: AppConstants.textPrimary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'التوصية: ${signal.recommendation}',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isWait ? AppConstants.warningOrange : AppConstants.accentCyan,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            if (!isActive) ...[
              _buildDurationSelector(),
              const SizedBox(height: 12),
            ],
            _buildRequestButton(
              enabled: !isActive,
              text: isActive
                  ? 'الصفقة جارية حالياً...'
                  : 'تحليل الصفقة التالية ⚡',
            ),
          ],
        ),
    );
  }

  Widget _buildDurationSelector() {
    final options = [1, 2, 5, 10];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'مدة الصفقة المستهدفة:',
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: AppConstants.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$_selectedMinutes ${_selectedMinutes >= 5 ? "دقائق" : (_selectedMinutes == 1 ? "دقيقة واحدة" : "دقيقتين")}',
              style: GoogleFonts.outfit(
                fontSize: 11.5,
                color: AppConstants.accentCyan,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: options.map((minutes) {
            final isSelected = _selectedMinutes == minutes;
            String label = '$minutes د';
            return InkWell(
              onTap: () {
                setState(() {
                  _selectedMinutes = minutes;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 50,
                height: 30,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppConstants.accentCyan.withAlpha(25)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? AppConstants.accentCyan
                        : AppConstants.borderGlow,
                    width: 1.0,
                  ),
                ),
                child: Center(
                  child: Text(
                    label,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? Colors.white
                          : AppConstants.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildRequestButton({required bool enabled, required String text}) {
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppConstants.accentCyan.withAlpha(50),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: ElevatedButton(
          onPressed: enabled
              ? () {
                  _signalEngine.requestNextSignal(
                    _selectedMinutes,
                    tvPriceGetter: _chartMode == 'tv' ? _tvPriceGetter : null,
                  );
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: enabled
                ? AppConstants.accentCyan
                : const Color(0xFF1B1630),
            foregroundColor: enabled
                ? AppConstants.spaceBackground
                : AppConstants.textSecondary,
            disabledBackgroundColor: const Color(0xFF120E22),
            disabledForegroundColor: AppConstants.textSecondary.withAlpha(120),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: enabled ? Colors.transparent : AppConstants.borderGlow,
                width: 1,
              ),
            ),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!enabled &&
                  _signalEngine.activeSignal?.status == 'ACTIVE') ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppConstants.warningOrange,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                text,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSignalMetric({
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 9,
            color: AppConstants.textSecondary,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: GoogleFonts.outfit(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: valueColor,
          ),
        ),
      ],
    );
  }


  Widget _buildTimeframeButton(String tf) {
    final isSelected = _signalEngine.chartTimeframe == tf;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3.0),
      child: InkWell(
        onTap: () {
          setState(() {
            _signalEngine.setChartTimeframe(tf);
          });
        },
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? AppConstants.accentCyan.withAlpha(40)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected
                  ? AppConstants.accentCyan
                  : AppConstants.borderGlow,
            ),
          ),
          child: Text(
            tf,
            style: GoogleFonts.outfit(
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Colors.white : AppConstants.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  // WIDGET: AI Signal Sentiment Assistant (Advanced Liquidity-Based)
  Widget _buildAIAnalysisCard() {
    final hasActiveSignal = _signalEngine.activeSignal != null;
    final rsi = _signalEngine.rsiVal;
    final stochK = _signalEngine.stochK;
    final adx = _signalEngine.adxVal;
    final cmf = _signalEngine.cmfVal;
    final volDelta = _signalEngine.volumeDelta;

    String actionRecommendation = 'WAIT';
    Color recommendationColor = AppConstants.warningOrange;
    IconData recommendationIcon = Icons.hourglass_top_rounded;

    if (hasActiveSignal) {
      final isCall = _signalEngine.activeSignal!.direction == 'CALL';
      actionRecommendation = isCall ? 'CALL' : 'PUT';
      recommendationColor = isCall ? AppConstants.callGreen : AppConstants.putRed;
      recommendationIcon = isCall ? Icons.trending_up_rounded : Icons.trending_down_rounded;
    }

    return _buildGlassCard(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header Row with title and recommendation badge ──
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppConstants.accentCyan.withAlpha(15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.psychology_rounded, color: AppConstants.accentCyan, size: 14),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI ANALYSIS',
                    style: GoogleFonts.outfit(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: recommendationColor.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: recommendationColor.withAlpha(80)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(recommendationIcon, color: recommendationColor, size: 11),
                      const SizedBox(width: 4),
                      Text(
                        actionRecommendation,
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: recommendationColor,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ── Compact Indicators Grid (4 circular gauges) ──
            Row(
              children: [
                Expanded(child: _buildMiniIndicator(
                  'RSI', rsi.toStringAsFixed(0),
                  rsi / 100,
                  rsi > 70 ? AppConstants.putRed : (rsi < 30 ? AppConstants.callGreen : AppConstants.accentCyan),
                )),
                const SizedBox(width: 6),
                Expanded(child: _buildMiniIndicator(
                  'Stoch', stochK.toStringAsFixed(0),
                  stochK / 100,
                  stochK > 80 ? AppConstants.putRed : (stochK < 20 ? AppConstants.callGreen : AppConstants.accentCyan),
                )),
                const SizedBox(width: 6),
                Expanded(child: _buildMiniIndicator(
                  'ADX', adx.toStringAsFixed(0),
                  adx / 100,
                  adx > 35 ? AppConstants.callGreen : (adx > 20 ? AppConstants.warningOrange : AppConstants.textSecondary),
                )),
                const SizedBox(width: 6),
                Expanded(child: _buildMiniIndicator(
                  'LIQ', '${_signalEngine.liquidityScore.toStringAsFixed(0)}%',
                  _signalEngine.liquidityScore / 100,
                  _signalEngine.liquidityZone.contains('Demand') ? AppConstants.callGreen
                      : (_signalEngine.liquidityZone.contains('Supply') ? AppConstants.putRed : AppConstants.warningOrange),
                )),
              ],
            ),
            const SizedBox(height: 6),

            // ── Key Metrics Row ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppConstants.spaceBackground.withAlpha(120),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildKeyMetric('VWAP', AppConstants.formatPrice(_signalEngine.vwapVal),
                    _signalEngine.currentPrice > _signalEngine.vwapVal ? AppConstants.callGreen : AppConstants.putRed),
                  _buildKeyMetric('CMF', cmf.toStringAsFixed(3),
                    cmf > 0.05 ? AppConstants.callGreen : (cmf < -0.05 ? AppConstants.putRed : AppConstants.accentCyan)),
                  _buildKeyMetric('Vol\u0394', '${volDelta.toStringAsFixed(0)}%',
                    volDelta > 15 ? AppConstants.callGreen : (volDelta < -15 ? AppConstants.putRed : AppConstants.warningOrange)),
                  _buildKeyMetric('Sent.', _signalEngine.marketSentiment.split(' ').first,
                    _signalEngine.marketSentiment.contains('Bullish') || _signalEngine.marketSentiment.contains('Buy')
                        ? AppConstants.callGreen
                        : (_signalEngine.marketSentiment.contains('Bearish') || _signalEngine.marketSentiment.contains('Sell')
                            ? AppConstants.putRed : AppConstants.warningOrange)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Mini circular indicator widget for compact display
  Widget _buildMiniIndicator(String label, String value, double progress, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(25)),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  strokeWidth: 2.5,
                  backgroundColor: AppConstants.borderGlow,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
                Text(
                  value,
                  style: GoogleFonts.outfit(
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 8,
              color: AppConstants.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // Compact key metric chip
  Widget _buildKeyMetric(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.outfit(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 7,
            color: AppConstants.textSecondary,
          ),
        ),
      ],
    );
  }


  // WIDGET: Real-time scrolling feed of VIP winners
  Widget _buildLiveFeedCard() {
    final logs = _signalEngine.socialWinLogs;

    return _buildGlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.people_alt_rounded,
                  color: AppConstants.accentCyan,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'LIVE VIP ROOM TRANSACTIONS',
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 80,
              decoration: BoxDecoration(
                color: AppConstants.spaceBackground.withAlpha(150),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppConstants.borderGlow),
              ),
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        'Awaiting new trades...',
                        style: GoogleFonts.outfit(
                          color: AppConstants.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: logs.length,
                      padding: const EdgeInsets.all(8),
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4.0),
                          child: Row(
                            children: [
                              Icon(
                                Icons.chevron_right_rounded,
                                color: AppConstants.accentCyan,
                                size: 12,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  logs[index],
                                  style: GoogleFonts.outfit(
                                    fontSize: 10.5,
                                    color: Colors.white.withAlpha(200),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // WIDGET: Signal History & Statistics Dashboard
  Widget _buildSignalHistoryCard() {
    final history = _signalEngine.signalHistory;

    // Filter history based on current filter type
    final filtered = history.where((sig) {
      if (_historyFilter == 'today') {
        final today = DateTime.now();
        return sig.entryTime.year == today.year &&
            sig.entryTime.month == today.month &&
            sig.entryTime.day == today.day;
      } else if (_historyFilter == 'yesterday') {
        final yesterday = DateTime.now().subtract(const Duration(days: 1));
        return sig.entryTime.year == yesterday.year &&
            sig.entryTime.month == yesterday.month &&
            sig.entryTime.day == yesterday.day;
      } else if (_historyFilter == 'custom') {
        if (_customDateRange == null) return false;
        final start = DateTime(
          _customDateRange!.start.year,
          _customDateRange!.start.month,
          _customDateRange!.start.day,
        );
        final end = DateTime(
          _customDateRange!.end.year,
          _customDateRange!.end.month,
          _customDateRange!.end.day,
          23,
          59,
          59,
        );
        return sig.entryTime.isAfter(start) && sig.entryTime.isBefore(end);
      }
      return true;
    }).toList();

    // Calculate metrics
    final totalCount = filtered.length;
    final winsCount = filtered.where((sig) => sig.status == 'WIN').length;
    final lossesCount = totalCount - winsCount;
    final winRate = totalCount > 0 ? (winsCount / totalCount * 100) : 0.0;

    return _buildGlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    Icons.bar_chart_rounded,
                    color: AppConstants.accentCyan,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'إحصائيات وسجل صفقات الـ VIP',
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Filter Tabs
              Row(
                children: [
                  _buildFilterTab('صفقات اليوم', 'today'),
                  const SizedBox(width: 8),
                  _buildFilterTab('صفقات الأمس', 'yesterday'),
                  const SizedBox(width: 8),
                  _buildFilterTab('فترة مخصصة 🗓️', 'custom'),
                ],
              ),

              // Custom Date Range Display
              if (_historyFilter == 'custom' && _customDateRange != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppConstants.spaceBackground.withAlpha(120),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppConstants.borderGlow),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'الفترة الزمنية المحددة:',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: AppConstants.textSecondary,
                        ),
                      ),
                      Text(
                        '${_customDateRange!.start.year}/${_customDateRange!.start.month.toString().padLeft(2, '0')}/${_customDateRange!.start.day.toString().padLeft(2, '0')}  إلى  ${_customDateRange!.end.year}/${_customDateRange!.end.month.toString().padLeft(2, '0')}/${_customDateRange!.end.day.toString().padLeft(2, '0')}',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: AppConstants.accentCyan,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Summary Stats Widgets
              Row(
                children: [
                  // Win Rate Badge
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppConstants.spaceBackground.withAlpha(120),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppConstants.borderGlow),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'نسبة النجاح',
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: AppConstants.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${winRate.toStringAsFixed(1)}%',
                            style: GoogleFonts.outfit(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: winRate >= 70
                                  ? AppConstants.callGreen
                                  : AppConstants.putRed,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Score Ratio Badge
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppConstants.spaceBackground.withAlpha(120),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppConstants.borderGlow),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'إجمالي الصفقات',
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              color: AppConstants.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$winsCount رابحة / $lossesCount خاسرة',
                            style: GoogleFonts.outfit(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            '($totalCount صفقات إجمالية)',
                            style: GoogleFonts.outfit(
                              fontSize: 9,
                              color: AppConstants.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Log details list
              filtered.isEmpty
                  ? Container(
                      height: 120,
                      decoration: BoxDecoration(
                        color: AppConstants.spaceBackground.withAlpha(100),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppConstants.borderGlow.withAlpha(100),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          'لا توجد صفقات مسجلة في هذه الفترة.',
                          style: GoogleFonts.outfit(
                            color: AppConstants.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  : SizedBox(
                      height: 200,
                      child: ListView.builder(
                        shrinkWrap: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final sig = filtered[index];
                          final isWin = sig.status == 'WIN';
                          final outcomeColor = isWin
                              ? AppConstants.callGreen
                              : AppConstants.putRed;
                          final directionText = sig.direction == 'CALL'
                              ? 'صعود'
                              : 'هبوط';

                          final dateStr =
                              "${sig.entryTime.hour.toString().padLeft(2, '0')}:${sig.entryTime.minute.toString().padLeft(2, '0')}";

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AppConstants.spaceBackground.withAlpha(
                                150,
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: outcomeColor.withAlpha(80),
                                width: 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                // Status Pill
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: outcomeColor.withAlpha(20),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: outcomeColor.withAlpha(80),
                                    ),
                                  ),
                                  child: Text(
                                    isWin ? '✓ كسب' : '✗ خسارة',
                                    style: GoogleFonts.outfit(
                                      fontSize: 10,
                                      color: outcomeColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // Details Area
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            sig.pair,
                                            style: GoogleFonts.outfit(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: sig.direction == 'CALL'
                                                  ? AppConstants.callGreen
                                                        .withAlpha(30)
                                                  : AppConstants.putRed
                                                        .withAlpha(30),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              directionText,
                                              style: GoogleFonts.outfit(
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                                color: sig.direction == 'CALL'
                                                    ? AppConstants.callGreen
                                                    : AppConstants.putRed,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'دخول: ${AppConstants.formatPrice(sig.entryPrice)} | إغلاق: ${AppConstants.formatPrice(sig.exitPrice ?? sig.currentPrice)}',
                                        style: GoogleFonts.outfit(
                                          fontSize: 10,
                                          color: AppConstants.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Date / Time
                                Text(
                                  dateStr,
                                  style: GoogleFonts.outfit(
                                    fontSize: 11,
                                    color: AppConstants.textSecondary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTab(String label, String value) {
    final isSelected = _historyFilter == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (value == 'custom') {
            _selectCustomDateRange();
          } else {
            setState(() {
              _historyFilter = value;
            });
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppConstants.accentCyan.withAlpha(40)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? AppConstants.accentCyan
                  : AppConstants.borderGlow,
              width: 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : AppConstants.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectCustomDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2026),
      lastDate: DateTime(2027),
      initialDateRange:
          _customDateRange ??
          DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 7)),
            end: DateTime.now(),
          ),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: ColorScheme.dark(
              primary: AppConstants.accentCyan,
              onPrimary: AppConstants.spaceBackground,
              surface: AppConstants.cardBgColor,
              onSurface: Colors.white,
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: AppConstants.spaceBackground,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _customDateRange = picked;
        _historyFilter = 'custom';
      });
    }
  }

  // GLASSMORPHISM CARD DECORATION UTILITY
  Widget _buildGlassCard({required Widget child, Color? borderColor}) {
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.cardBgColor.withAlpha(200),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor ?? AppConstants.borderGlow,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
    );
  }
}
