import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
  StreamSubscription<List<Map<String, dynamic>>>? _roleListener;
  StreamSubscription<List<Map<String, dynamic>>>? _maintenanceListener;
  StreamSubscription<List<Map<String, dynamic>>>? _stdStrategyListener;
  StreamSubscription<List<Map<String, dynamic>>>? _vipStrategyListener;
  StreamSubscription<List<Map<String, dynamic>>>? _chartModeListener;
  StreamSubscription<List<Map<String, dynamic>>>? _pairsListener;
  String _chartMode = 'sim';
  String _activeChartSymbol = '';
  String _brokerLogoUrl = '';
  bool _updateChecked = false;

  // --- Server-driven market status (from proxy `marketOpen`) ---
  static const String _proxyBase = 'https://euro-trade-proxy.onrender.com';
  Timer? _marketStatusTimer;
  bool _marketOpen = true; // optimistic default until first poll
  bool _marketClosedDialogShown = false;
  bool _marketClosedDialogOpen = false;

  // --- VIP expiry handling ---
  Timer? _vipExpiryTimer;
  bool _vipExpiredDialogShown = false; // guard: expired dialog shows once
  bool _vipReminderShown = false; // guard: 24h reminder shows once per session
  bool _vipDowngradeInFlight = false; // avoid duplicate Supabase updates
  String _telegramContact = '';

  @override
  void initState() {
    super.initState();
    _signalEngine = SignalEngine();
    _signalEngine.addListener(_onSignalEngineUpdate);
    _loadUserData();
    _startMaintenanceListener();

    _selectedCategory = 'forex';
    if (AppConstants.currencyPairs.isNotEmpty) {
      final firstForex = AppConstants.currencyPairs.firstWhere(
        (p) => (p['category'] as String? ?? '') == 'forex',
        orElse: () => AppConstants.currencyPairs.first,
      );
      _activeChartSymbol = firstForex['chartSymbol'] as String? ?? '';
      final firstSymbol = firstForex['symbol'] as String? ?? '';
      if (firstSymbol.isNotEmpty) {
        _signalEngine.selectPair(firstSymbol);
      }
    }

    // Server-driven market status: poll immediately, then every 5s.
    _startMarketStatusPolling();
  }

  // ── Market status polling ────────────────────────────────────────────────

  /// Strips the exchange prefix and '/' to get the bare symbol the proxy expects
  /// (e.g. "OANDA:EURUSD" -> "EURUSD", "BTC/USDT" -> "BTCUSDT").
  String _bareSymbol() {
    var s = _activeChartSymbol.isNotEmpty
        ? _activeChartSymbol
        : AppConstants.chartSymbolFor(_signalEngine.activePair);
    final colon = s.indexOf(':');
    if (colon != -1) s = s.substring(colon + 1);
    return s.replaceAll('/', '').replaceAll(' (OTC)', '').trim();
  }

  void _startMarketStatusPolling() {
    _marketStatusTimer?.cancel();
    _pollMarketStatus(); // immediate poll so closed market shows instantly
    _marketStatusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollMarketStatus(),
    );
  }

  Future<void> _pollMarketStatus() async {
    final sym = _bareSymbol();
    if (sym.isEmpty) return;
    bool open;
    try {
      final resp = await http
          .get(Uri.parse('$_proxyBase/api/tv/tick?symbol=$sym'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return; // leave state unchanged on bad status
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      // Missing field → treat as open (safety). Otherwise honour marketOpen.
      open = data.containsKey('marketOpen') ? data['marketOpen'] == true : true;
    } catch (_) {
      // Network/parse error → leave current state unchanged (don't flip/spam).
      return;
    }
    if (!mounted) return;
    _applyMarketStatus(open);
  }

  void _applyMarketStatus(bool open) {
    final wasOpen = _marketOpen;
    _marketOpen = open;
    // Keep the engine flag reconciled with the server every poll (the engine may
    // also set it closed internally via its analysis path).
    _signalEngine.setMarketClosed(!open);

    if (!open) {
      // (Re-)entering closed state. Show dialog once per closed episode.
      if (wasOpen && !_marketClosedDialogShown) {
        _marketClosedDialogShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_marketClosedDialogOpen) {
            _showMarketClosedDialog(context);
          }
        });
      }
    } else if (!wasOpen) {
      // closed → open: reset guard and dismiss the dialog if it's showing.
      _marketClosedDialogShown = false;
      if (_marketClosedDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _marketClosedDialogOpen = false;
      }
    }
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final accountId =
        prefs.getString(AppConstants.keyUserAccountId) ?? '8392019';
    final brokerName = prefs.getString(AppConstants.keyUserBroker) ?? 'Quotex';
    setState(() {
      _userAccountId = accountId;
      _userBroker = brokerName;
    });
    _signalEngine.setAccountId(accountId);
    _loadTelegramContact();
    _startRoleListener(accountId);
    _startVipExpiryWatch(accountId);
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
      final rows = await Supabase.instance.client
          .from('brokers')
          .select('logo_url')
          .eq('name', brokerName)
          .limit(1);
      if ((rows as List).isNotEmpty && mounted) {
        final url = rows.first['logo_url'] as String? ?? '';
        if (url.isNotEmpty) setState(() => _brokerLogoUrl = url);
      }
    } catch (_) {}
  }

  void _startRoleListener(String accountId) {
    try {
      _roleListener?.cancel();
      _roleListener = Supabase.instance.client
          .from('users')
          .stream(primaryKey: ['id'])
          .eq('id', accountId)
          .listen((rows) async {
            if (rows.isEmpty || !mounted) return;
            final data = rows.first;

            final isBanned = data['is_banned'] as bool? ?? false;
            final banReason = data['ban_reason'] as String? ?? '';
            if (isBanned) {
              _roleListener?.cancel();
              _maintenanceListener?.cancel();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _showBanDialog(banReason);
              });
              return;
            }

            final newRole = data['role'] ?? 'standard';
            final vipExpiryStr = data['vip_expiry'] as String?;
            DateTime? newExpiry;
            if (vipExpiryStr != null) newExpiry = DateTime.tryParse(vipExpiryStr);

            final guaranteedWin = data['guaranteed_win'] as bool? ?? false;
            _signalEngine.updateGuaranteedWin(guaranteedWin);

            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('user_role', newRole);
            if (newExpiry != null) {
              await prefs.setString('vip_expiry', newExpiry.toIso8601String());
            } else {
              await prefs.remove('vip_expiry');
            }

            _signalEngine.updateUserData(newRole, newExpiry);

            // Re-evaluate VIP expiry whenever the row changes (covers admin
            // edits to role/vip_expiry while the session is open).
            _evaluateVipExpiry(newRole, newExpiry);
          });
    } catch (_) {}
  }

  // ── VIP expiry handling ────────────────────────────────────────────────────

  /// Reads the telegram contact from configs/social (used in the 24h reminder).
  /// Missing/empty value is fine — the contact line is then omitted.
  Future<void> _loadTelegramContact() async {
    try {
      final row = await Supabase.instance.client
          .from('configs')
          .select('data')
          .eq('id', 'social')
          .maybeSingle();
      if (row == null || !mounted) return;
      final d = row['data'] as Map<String, dynamic>? ?? {};
      final tg = (d['telegram'] as String? ?? '').trim();
      if (tg.isNotEmpty) _telegramContact = tg;
    } catch (_) {}
  }

  /// Periodic re-check so a session that crosses the expiry moment downgrades
  /// without a restart. Reads the engine's current role/expiry each tick.
  void _startVipExpiryWatch(String accountId) {
    _vipExpiryTimer?.cancel();
    // Evaluate immediately on app open, then every 60s.
    _evaluateVipExpiry(_signalEngine.userRole, _signalEngine.vipExpiry);
    _vipExpiryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      _evaluateVipExpiry(_signalEngine.userRole, _signalEngine.vipExpiry);
    });
  }

  /// Central VIP-status evaluation. Compares vip_expiry (parsed as UTC) against
  /// DateTime.now().toUtc(). Handles auto-downgrade (past) and 24h reminder.
  void _evaluateVipExpiry(String role, DateTime? expiry) {
    if (role != 'vip' || expiry == null) return;
    final expiryUtc = expiry.toUtc();
    final nowUtc = DateTime.now().toUtc();
    final remaining = expiryUtc.difference(nowUtc);

    if (remaining.isNegative || remaining == Duration.zero) {
      // Expired → downgrade + dialog once.
      _handleVipExpired();
    } else if (remaining <= const Duration(hours: 24)) {
      // Within the next 24h → informational reminder once per session.
      if (!_vipReminderShown) {
        _vipReminderShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showVipReminderDialog(context);
        });
      }
    }
  }

  /// Auto-downgrade the user to standard in Supabase + locally, then show the
  /// expired dialog once.
  Future<void> _handleVipExpired() async {
    // Reflect locally immediately (engine is the source of truth for role).
    _signalEngine.updateUserData('standard', null);

    if (!_vipDowngradeInFlight) {
      _vipDowngradeInFlight = true;
      try {
        await Supabase.instance.client
            .from('users')
            .update({'role': 'standard', 'vip_expiry': null})
            .eq('id', _userAccountId);
      } catch (_) {}
    }

    if (!_vipExpiredDialogShown) {
      _vipExpiredDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showVipExpiredDialog(context);
      });
    }
  }

  void _startMaintenanceListener() {
    try {
      _maintenanceListener?.cancel();
      _maintenanceListener = Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'maintenance')
          .listen((rows) {
            if (rows.isEmpty || !mounted) return;
            final d = rows.first['data'] as Map<String, dynamic>? ?? {};
            final isActive = d['isActive'] as bool? ?? false;
            if (!isActive) return;
            final endsAtStr = d['endsAt'] as String?;
            final endsAt = endsAtStr != null ? DateTime.tryParse(endsAtStr) : null;
            if (endsAt != null && endsAt.isBefore(DateTime.now())) return;
            _roleListener?.cancel();
            _maintenanceListener?.cancel();
            Navigator.of(context).pushReplacement(
              PageRouteBuilder(
                pageBuilder: (context, animation, _) => const MaintenanceScreen(),
                transitionsBuilder: (_, anim, secondary, child) =>
                    FadeTransition(opacity: anim, child: child),
                transitionDuration: const Duration(milliseconds: 600),
              ),
            );
          });
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    if (_updateChecked || !mounted) return;
    _updateChecked = true;
    try {
      final row = await Supabase.instance.client
          .from('configs')
          .select('data')
          .eq('id', 'appUpdate')
          .maybeSingle();
      if (row == null || !mounted) return;
      final d = row['data'] as Map<String, dynamic>? ?? {};
      final hasUpdate = d['hasUpdate'] as bool? ?? false;
      if (!hasUpdate) return;
      final version = d['version'] as String? ?? '';
      final link = d['downloadLink'] as String? ?? '';
      final isForced = d['isForced'] as bool? ?? false;
      final features = (d['features'] as List<dynamic>? ?? []).cast<String>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpdateDialog(version, features, link, isForced);
      });
    } catch (_) {}
  }

  void _showUpdateDialog(
    String version,
    List<String> features,
    String link,
    bool isForced,
  ) {
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
            side: BorderSide(
              color: AppConstants.accentCyan.withAlpha(100),
              width: 1.5,
            ),
          ),
          title: Row(
            children: [
              Icon(
                Icons.system_update_alt_rounded,
                color: AppConstants.accentCyan,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'تحديث جديد متاح 🚀',
                style: GoogleFonts.outfit(
                  color: AppConstants.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'النسخة الجديدة: $version',
                style: GoogleFonts.outfit(
                  color: AppConstants.accentCyan,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (features.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'المميزات الجديدة:',
                  style: GoogleFonts.outfit(
                    color: AppConstants.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...features.map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• ',
                          style: GoogleFonts.outfit(
                            color: AppConstants.callGreen,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            f,
                            style: GoogleFonts.outfit(
                              color: AppConstants.textSecondary,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (isForced) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppConstants.putRed.withAlpha(15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppConstants.putRed.withAlpha(60),
                    ),
                  ),
                  child: Text(
                    '⚠️ هذا التحديث إجباري ولا يمكن تخطيه',
                    style: GoogleFonts.outfit(
                      color: AppConstants.putRed,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (!isForced)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'لاحقاً',
                  style: GoogleFonts.outfit(color: AppConstants.textSecondary),
                ),
              ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                if (link.isNotEmpty) openBrowserTab(link);
              },
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(
                'تحميل التحديث',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.accentCyan,
                foregroundColor: AppConstants.spaceBackground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
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
            side: BorderSide(
              color: AppConstants.putRed.withAlpha(100),
              width: 1.5,
            ),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.block_rounded,
                color: AppConstants.putRed,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'تم حظر حسابك',
                style: GoogleFonts.outfit(
                  color: AppConstants.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(
            reason.isNotEmpty
                ? 'تم حظر حسابك من قِبَل الإدارة.\nالسبب: $reason'
                : 'تم حظر حسابك من قِبَل الإدارة.\nللمزيد من المعلومات تواصل مع الدعم.',
            style: GoogleFonts.outfit(
              color: AppConstants.textSecondary,
              height: 1.6,
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _logout();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.putRed,
                foregroundColor: Colors.white,
              ),
              child: Text(
                'موافق',
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
              ),
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
          transitionsBuilder: (_, anim, secondary, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    }
  }

  void _onSignalEngineUpdate() {
    if (_signalEngine.vipJustExpired) {
      _signalEngine.clearVipJustExpired();
      // Route through the central handler so Supabase is updated and the dialog
      // is guarded (shown once).
      _handleVipExpired();
    }

    // Market closed (driven by server poll or engine analysis path). Show the
    // dialog once; do NOT clear the flag here — the closed state must persist so
    // the Live Room stays closed. Clearing happens when the poll sees it reopen.
    if (_signalEngine.isMarketClosed && !_marketClosedDialogShown) {
      _marketClosedDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showMarketClosedDialog(context);
      });
    }

    final activeSignal = _signalEngine.activeSignal;
    if (activeSignal != null &&
        (activeSignal.status == 'WIN' || activeSignal.status == 'LOSS') &&
        activeSignal != _lastProcessedSignal) {
      _lastProcessedSignal = activeSignal;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTradeReviewDialog(context, activeSignal);
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
              side: BorderSide(
                color: AppConstants.putRed.withAlpha(100),
                width: 1.5,
              ),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppConstants.putRed,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Text(
                  'انتهت عضويتك VIP ⚠️',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            content: Text(
              'تم تحويل حسابك إلى Standard. يمكنك الترقية مجدداً في أي وقت.',
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

  // Informational reminder shown when VIP expires within the next 24h.
  // Non-blocking: a single "حسناً" button (and optional telegram link).
  void _showVipReminderDialog(BuildContext context) {
    final tg = _telegramContact;
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (BuildContext context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: AppConstants.cardBgColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: AppConstants.warningOrange.withAlpha(100),
                width: 1.5,
              ),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.access_time_rounded,
                  color: AppConstants.warningOrange,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'تنبيه انتهاء VIP ⏳',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'عضويتك VIP ستنتهي خلال أقل من 24 ساعة.',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: AppConstants.textSecondary,
                    height: 1.5,
                  ),
                ),
                if (tg.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'للتجديد تواصل معنا: $tg',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: AppConstants.accentCyan,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (tg.isNotEmpty)
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    openBrowserTab(tg);
                  },
                  icon: Icon(
                    Icons.send_rounded,
                    size: 16,
                    color: AppConstants.accentCyan,
                  ),
                  label: Text(
                    'تواصل معنا',
                    style: GoogleFonts.outfit(
                      color: AppConstants.accentCyan,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'حسناً',
                  style: GoogleFonts.outfit(
                    color: AppConstants.textSecondary,
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

  void _showMarketClosedDialog(BuildContext context) {
    if (_marketClosedDialogOpen) return; // singleton guard
    _marketClosedDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppConstants.spaceBackground.withAlpha(230),
      builder: (_) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 40,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppConstants.cardBgColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppConstants.borderGlow, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4A3A7A).withAlpha(60),
                  blurRadius: 40,
                  spreadRadius: 8,
                ),
              ],
            ),
            padding: const EdgeInsets.all(28),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon + glowing circle
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF1E1640),
                      border: Border.all(
                        color: AppConstants.warningOrange.withAlpha(100),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppConstants.warningOrange.withAlpha(40),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.lock_clock_outlined,
                      color: AppConstants.warningOrange,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'السوق مغلق مؤقتاً',
                    style: GoogleFonts.outfit(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'السعر ثابت أو السوق خارج أوقات التداول الرسمية.\nانتظر حتى يُفتح السوق ثم أعد المحاولة.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: AppConstants.textSecondary,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '💡 جرب أزواج OTC — متاحة 24/7 حتى في عطلات نهاية الأسبوع',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: AppConstants.accentCyan,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Status indicator
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppConstants.warningOrange.withAlpha(15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppConstants.warningOrange.withAlpha(60),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppConstants.warningOrange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'السوق: مغلق',
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppConstants.warningOrange,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppConstants.accentBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 6,
                      ),
                      child: Text(
                        'حسناً، سأنتظر',
                        style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).then((_) {
      // Dialog dismissed (by button, barrier, or programmatic pop on re-open).
      _marketClosedDialogOpen = false;
    });
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
    final isCall = signal.direction == 'CALL';
    final profitColor = isWin ? AppConstants.callGreen : AppConstants.putRed;
    final exitP = signal.exitPrice ?? signal.currentPrice;

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
                  // ── Header ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isWin
                            ? Icons.check_circle_outline_rounded
                            : Icons.cancel_outlined,
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

                  // ── Outcome badge ──
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: profitColor.withAlpha(15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: profitColor.withAlpha(80),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      isWin ? '✅  صفقة ناجحة' : '❌  صفقة خاسرة',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: profitColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // ── Mini price chart ──
                  _buildMiniPriceChart(
                    signal,
                    isWin,
                    isCall,
                    profitColor,
                    exitP,
                  ),
                  const SizedBox(height: 14),

                  // ── Stats table ──
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
                          'زوج العملات',
                          signal.pair.replaceAll(' (OTC)', ''),
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'الاتجاه',
                          isCall ? 'صعود  🟢' : 'هبوط  🔴',
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'سعر الدخول',
                          AppConstants.formatPrice(signal.entryPrice),
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'سعر الإغلاق',
                          AppConstants.formatPrice(exitP),
                        ),
                        const Divider(
                          color: AppConstants.borderGlow,
                          height: 16,
                        ),
                        _buildDialogStatRow(
                          'المدة',
                          '${signal.durationMinutes} دقيقة',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Continue button ──
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _signalEngine.clearActiveSignal();
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
                    child: Text(
                      'متابعة الصفقة التالية 🚀',
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
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

  Widget _buildMiniPriceChart(
    TradingSignal signal,
    bool isWin,
    bool isCall,
    Color profitColor,
    double exitP,
  ) {
    final diff = exitP - signal.entryPrice;
    final absDiff = diff.abs();
    // Pips for forex (4-decimal): multiply by 10000. For JPY: multiply by 100. Fallback: raw diff.
    final isJpy = signal.pair.toUpperCase().contains('JPY');
    double pipsVal;
    String pipsLabel;
    if (absDiff < 1.0) {
      pipsVal = isJpy ? absDiff * 100 : absDiff * 10000;
      pipsLabel = '${diff >= 0 ? '+' : '-'}${pipsVal.toStringAsFixed(1)} pips';
    } else {
      pipsLabel = '${diff >= 0 ? '+' : ''}${absDiff.toStringAsFixed(5)}';
    }

    // Positions: entry in center, exit above/below based on movement
    // For CALL WIN: exit > entry → exit is on top
    // For CALL LOSS: exit < entry → exit is on bottom
    final exitOnTop = exitP >= signal.entryPrice;

    return Container(
      height: 112,
      decoration: BoxDecoration(
        color: AppConstants.spaceBackground.withAlpha(200),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppConstants.borderGlow.withAlpha(100)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Background painted layer (shaded zone + lines)
            Positioned.fill(
              child: CustomPaint(
                painter: _MiniPricePainter(
                  entryPrice: signal.entryPrice,
                  exitPrice: exitP,
                  profitColor: profitColor,
                ),
              ),
            ),
            // Price labels & arrow overlay
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left column: top price / bottom price labels
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppConstants.formatPrice(
                          exitOnTop ? exitP : signal.entryPrice,
                        ),
                        style: GoogleFonts.outfit(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: exitOnTop
                              ? profitColor
                              : AppConstants.textSecondary,
                        ),
                      ),
                      Text(
                        exitOnTop ? 'إغلاق' : 'دخول',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          color: exitOnTop
                              ? profitColor
                              : AppConstants.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        exitOnTop ? 'دخول' : 'إغلاق',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          color: exitOnTop
                              ? AppConstants.textSecondary
                              : profitColor,
                        ),
                      ),
                      Text(
                        AppConstants.formatPrice(
                          exitOnTop ? signal.entryPrice : exitP,
                        ),
                        style: GoogleFonts.outfit(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: exitOnTop
                              ? AppConstants.textSecondary
                              : profitColor,
                        ),
                      ),
                    ],
                  ),
                  // Center: arrow + pips
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          exitOnTop
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          color: profitColor,
                          size: 22,
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: profitColor.withAlpha(25),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: profitColor.withAlpha(80),
                            ),
                          ),
                          child: Text(
                            pipsLabel,
                            style: GoogleFonts.outfit(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: profitColor,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isCall ? '▲ CALL' : '▼ PUT',
                          style: GoogleFonts.outfit(
                            fontSize: 9,
                            color: isCall
                                ? AppConstants.callGreen
                                : AppConstants.putRed,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Right column: mirror labels
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        exitOnTop ? 'سعر الخروج' : 'سعر الدخول',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          color: exitOnTop
                              ? profitColor.withAlpha(180)
                              : AppConstants.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        exitOnTop ? 'سعر الدخول' : 'سعر الخروج',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          color: exitOnTop
                              ? AppConstants.textSecondary
                              : profitColor.withAlpha(180),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
    _marketStatusTimer?.cancel();
    _vipExpiryTimer?.cancel();
    _signalEngine.removeListener(_onSignalEngineUpdate);
    _signalEngine.dispose();
    super.dispose();
  }

  void _startChartModeListener() {
    try {
      _chartModeListener?.cancel();
      _chartModeListener = Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'chart_settings')
          .listen((rows) {
            if (rows.isEmpty || !mounted) return;
            final data = rows.first['data'] as Map<String, dynamic>? ?? {};
            final mode = data['mode'] as String? ?? 'sim';
            final resolved = mode == 'tv' ? 'tv' : 'sim';
            if (resolved != _chartMode) setState(() { _chartMode = resolved; });
          });
    } catch (_) {}
  }

  void _startPairsListener() {
    try {
      _pairsListener?.cancel();
      _pairsListener = Supabase.instance.client
          .from('pairs')
          .stream(primaryKey: ['id'])
          .listen((rows) {
            if (!mounted) return;
            final pairs = rows
                .map((d) => <String, dynamic>{
                      'id': d['id'],
                      'symbol': d['symbol'] as String? ?? '',
                      'chartSymbol': d['chart_symbol'] as String? ?? '',
                      'category': d['category'] as String? ?? 'forex',
                      'type': d['type'] as String? ?? 'forex',
                      'order': d['order'] as int? ?? 0,
                    })
                .where((p) => (p['symbol'] as String).isNotEmpty)
                .toList()
              ..sort((a, b) => (a['order'] as int).compareTo(b['order'] as int));

            setState(() {
              AppConstants.currencyPairs = pairs;

              // Verify active pair is still in the new list
              final activeExists = pairs.any(
                (p) => p['symbol'] == _signalEngine.activePair,
              );
              if (!activeExists && pairs.isNotEmpty) {
                final firstForex = pairs.firstWhere(
                  (p) => (p['category'] as String? ?? '') == 'forex',
                  orElse: () => pairs.first,
                );
                _activeChartSymbol =
                    firstForex['chartSymbol'] as String? ?? '';
                final firstSymbol = firstForex['symbol'] as String? ?? '';
                if (firstSymbol.isNotEmpty)
                  _signalEngine.selectPair(firstSymbol);
              }
            });
          });
    } catch (_) {}
  }

  void _startStrategyListeners() {
    try {
      _stdStrategyListener?.cancel();
      _vipStrategyListener?.cancel();

      _stdStrategyListener = Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'strategy_standard')
          .listen((rows) {
            if (rows.isEmpty || !mounted) return;
            final data = rows.first['data'] as Map<String, dynamic>? ?? {};
            if (data.isNotEmpty) _signalEngine.updateStandardStrategy(data);
          });

      _vipStrategyListener = Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'strategy_vip')
          .listen((rows) {
            if (rows.isEmpty || !mounted) return;
            final data = rows.first['data'] as Map<String, dynamic>? ?? {};
            if (data.isNotEmpty) _signalEngine.updateVipStrategy(data);
          });
    } catch (_) {}
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
                    Expanded(child: _buildUserInfoSection(isVip)),
                    const SizedBox(width: 8),
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
                Expanded(child: _buildUserInfoSection(isVip)),
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
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      isVip
                          ? 'VIP USER: $_userAccountId'
                          : 'USER: $_userAccountId',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
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
                        color: isVip
                            ? Colors.amberAccent
                            : Colors.white.withAlpha(50),
                      ),
                      boxShadow: isVip
                          ? [
                              BoxShadow(
                                color: Colors.amber.withAlpha(80),
                                blurRadius: 4,
                              ),
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
                            ? Image.network(
                                _brokerLogoUrl,
                                fit: BoxFit.contain,
                                errorBuilder: (ctx, err, stack) =>
                                    _brokerLogoFallback(),
                              )
                            : _brokerLogoFallback(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      isVip
                          ? 'منصة التداول: $_userBroker VIP'
                          : 'منصة التداول: $_userBroker',
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppConstants.accentCyan,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
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
              ),
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
          BoxShadow(color: Colors.amber.withAlpha(30), blurRadius: 6),
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
            color: _soundEnabled
                ? AppConstants.accentCyan
                : AppConstants.textSecondary,
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
            height: 88,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E1736))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _buildCategoryTab(
                    'forex',
                    'فوركس',
                    Icons.currency_exchange_rounded,
                  ),
                  _buildCategoryTab('metals', 'معادن', Icons.diamond_rounded),
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
                          _signalEngine.activePair.replaceAll(' (OTC)', ''),
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 8),
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
            final sourcePairs = AppConstants.currencyPairs
                .where((pair) => pair['category'] == _selectedCategory)
                .toList();

            final filteredPairs = sourcePairs.where((pair) {
              if (_searchQuery.isEmpty) return true;
              return (pair['symbol'] as String).toLowerCase().contains(
                _searchQuery.toLowerCase(),
              );
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
                    child: filteredPairs.isEmpty
                        ? Center(
                            child: Text(
                              'لا توجد أصول تطابق البحث',
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
                                    final cs =
                                        pair['chartSymbol'] as String? ?? '';
                                    if (cs.isNotEmpty)
                                      setState(() => _activeChartSymbol = cs);
                                    Navigator.pop(context);
                                    // Re-evaluate market status for the new pair right away.
                                    _pollMarketStatus();
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
                                          ],
                                        ),
                                        // Right side: Symbol + optional label
                                        Row(
                                          children: [
                                            Text(
                                              (pair['symbol'] as String)
                                                  .replaceAll(' (OTC)', ''),
                                              style: GoogleFonts.outfit(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: isSelected
                                                    ? Colors.white
                                                    : AppConstants.textPrimary,
                                              ),
                                            ),
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
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        onTap: () {
          setState(() => _selectedCategory = categoryId);
        },
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 95,
          height: 64,
          decoration: BoxDecoration(
            color: isSelected
                ? AppConstants.accentCyan.withAlpha(20)
                : AppConstants.cardBgColor.withAlpha(150),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? AppConstants.accentCyan
                  : AppConstants.borderGlow,
              width: 1.5,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppConstants.accentCyan.withAlpha(30),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : [],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
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
        const SizedBox(height: 20),
        _buildSocialCards(),
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
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppConstants.accentCyan.withAlpha(15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.candlestick_chart_rounded,
                    color: AppConstants.accentCyan,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LIVE CHART',
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textSecondary,
                          letterSpacing: 1.5,
                        ),
                      ),
                      Text(
                        chartSymbol
                            .replaceFirst(RegExp(r'^[A-Z]+:'), '')
                            .replaceAll('_', '/'),
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      '1m',
                      '5m',
                      '15m',
                      '1h',
                      '1D',
                    ].map(_buildTimeframeButton).toList(),
                  ),
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
            signalSecondsRemaining: isActive
                ? _signalEngine.secondsRemaining
                : null,
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
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppConstants.accentCyan.withAlpha(15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.psychology_rounded,
                    color: AppConstants.accentCyan,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VIP ALGORITHM SENSOR',
                      style: GoogleFonts.outfit(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: AppConstants.textSecondary,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'التحليل جاهز للاستخراج',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(color: AppConstants.borderGlow, height: 16),
            Text(
              'اضغط أدناه لبدء تحليل شامل للزوج ${_signalEngine.activePair.replaceAll(' (OTC)', '')} بفريم ${_signalEngine.chartTimeframe} واستخراج الصفقة ذات الاحتمالية الأكبر.',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 11,
                color: AppConstants.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            _buildDurationSelector(),
            const SizedBox(height: 12),
            _buildRequestButton(
              enabled: true,
              text: 'استخراج الإشارة التالية ⚡',
            ),
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
                child: Row(
                  children: [
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
                      isWait
                          ? 'انتظار (WAIT)'
                          : (isCall ? 'صعود (CALL)' : 'هبوط (PUT)'),
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
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
                value: isWait
                    ? 'N/A'
                    : '${signal.confidence.toStringAsFixed(1)}%',
                valueColor: isWait
                    ? AppConstants.textSecondary
                    : AppConstants.accentCyan,
              ),
              _buildSignalMetric(
                label: 'ENTRY PRICE',
                value: isWait
                    ? 'N/A'
                    : AppConstants.formatPrice(signal.entryPrice),
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
                      isWait
                          ? Icons.warning_amber_rounded
                          : Icons.gpp_good_rounded,
                      color: accentColor,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isWait
                          ? 'حالة السوق: تذبذب وحالة غير آمنة ⚠️'
                          : 'حالة السوق: دخول آمن ومستقر ✅',
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
                    color: isWait
                        ? AppConstants.warningOrange
                        : AppConstants.accentCyan,
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
                  // Block analysis when the market is closed.
                  if (!_marketOpen || _signalEngine.isMarketClosed) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'السوق مغلق الان حاول في وقت لاحق',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        backgroundColor: AppConstants.warningOrange,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }
                  _signalEngine.requestNextSignal(
                    _selectedMinutes,
                    tvPriceGetter:
                        _tvPriceGetter, // always pass — correct for both sim & TV
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
      recommendationColor = isCall
          ? AppConstants.callGreen
          : AppConstants.putRed;
      recommendationIcon = isCall
          ? Icons.trending_up_rounded
          : Icons.trending_down_rounded;
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
                  child: Icon(
                    Icons.psychology_rounded,
                    color: AppConstants.accentCyan,
                    size: 14,
                  ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: recommendationColor.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: recommendationColor.withAlpha(80),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        recommendationIcon,
                        color: recommendationColor,
                        size: 11,
                      ),
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
                Expanded(
                  child: _buildMiniIndicator(
                    'RSI',
                    rsi.toStringAsFixed(0),
                    rsi / 100,
                    rsi > 70
                        ? AppConstants.putRed
                        : (rsi < 30
                              ? AppConstants.callGreen
                              : AppConstants.accentCyan),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildMiniIndicator(
                    'Stoch',
                    stochK.toStringAsFixed(0),
                    stochK / 100,
                    stochK > 80
                        ? AppConstants.putRed
                        : (stochK < 20
                              ? AppConstants.callGreen
                              : AppConstants.accentCyan),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildMiniIndicator(
                    'ADX',
                    adx.toStringAsFixed(0),
                    adx / 100,
                    adx > 35
                        ? AppConstants.callGreen
                        : (adx > 20
                              ? AppConstants.warningOrange
                              : AppConstants.textSecondary),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildMiniIndicator(
                    'LIQ',
                    '${_signalEngine.liquidityScore.toStringAsFixed(0)}%',
                    _signalEngine.liquidityScore / 100,
                    _signalEngine.liquidityZone.contains('Demand')
                        ? AppConstants.callGreen
                        : (_signalEngine.liquidityZone.contains('Supply')
                              ? AppConstants.putRed
                              : AppConstants.warningOrange),
                  ),
                ),
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
                  _buildKeyMetric(
                    'VWAP',
                    AppConstants.formatPrice(_signalEngine.vwapVal),
                    _signalEngine.currentPrice > _signalEngine.vwapVal
                        ? AppConstants.callGreen
                        : AppConstants.putRed,
                  ),
                  _buildKeyMetric(
                    'CMF',
                    cmf.toStringAsFixed(3),
                    cmf > 0.05
                        ? AppConstants.callGreen
                        : (cmf < -0.05
                              ? AppConstants.putRed
                              : AppConstants.accentCyan),
                  ),
                  _buildKeyMetric(
                    'Vol\u0394',
                    '${volDelta.toStringAsFixed(0)}%',
                    volDelta > 15
                        ? AppConstants.callGreen
                        : (volDelta < -15
                              ? AppConstants.putRed
                              : AppConstants.warningOrange),
                  ),
                  _buildKeyMetric(
                    'Sent.',
                    _signalEngine.marketSentiment.split(' ').first,
                    _signalEngine.marketSentiment.contains('Bullish') ||
                            _signalEngine.marketSentiment.contains('Buy')
                        ? AppConstants.callGreen
                        : (_signalEngine.marketSentiment.contains('Bearish') ||
                                  _signalEngine.marketSentiment.contains('Sell')
                              ? AppConstants.putRed
                              : AppConstants.warningOrange),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Mini circular indicator widget for compact display
  Widget _buildMiniIndicator(
    String label,
    String value,
    double progress,
    Color color,
  ) {
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

  // WIDGET: Social media follow cards
  Widget _buildSocialCards() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('configs')
          .stream(primaryKey: ['id'])
          .eq('id', 'social'),
      builder: (context, snap) {
        final rows = snap.data ?? [];
        final data = rows.isNotEmpty
            ? rows.first['data'] as Map<String, dynamic>? ?? {}
            : <String, dynamic>{};
        final ytUrl   = data['youtubeUrl']  as String? ?? 'https://www.youtube.com/@euro_trader';
        final tgUrl   = data['telegramUrl'] as String? ?? 'https://t.me/euro_trd1';
        final chatUrl = data['chatUrl']     as String? ?? 'https://t.me/euro_trd';

        return _buildGlassCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.share_rounded,
                        color: AppConstants.accentCyan,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'تابعنا على السوشيال ميديا',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textPrimary,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _socialBtn(
                          icon: Icons.play_circle_fill_rounded,
                          color: Colors.red,
                          label: 'يوتيوب',
                          sublabel: '@euro_trader',
                          url: ytUrl,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _socialBtn(
                          icon: Icons.send_rounded,
                          color: const Color(0xFF29B6F6),
                          label: 'تليجرام',
                          sublabel: '@euro_trd1',
                          url: tgUrl,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _socialBtn(
                          icon: Icons.chat_bubble_rounded,
                          color: AppConstants.warningOrange,
                          label: 'تواصل معنا',
                          sublabel: 'للتجديد والدعم',
                          url: chatUrl,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _socialBtn({
    required IconData icon,
    required Color color,
    required String label,
    required String sublabel,
    required String url,
  }) {
    return GestureDetector(
      onTap: () => openBrowserTab(url),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 5),
            Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppConstants.textPrimary,
              ),
            ),
            Text(
              sublabel,
              style: GoogleFonts.outfit(
                fontSize: 9,
                color: AppConstants.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // WIDGET: Real-time scrolling feed of VIP winners
  Widget _buildLiveFeedCard() {
    final logs = _signalEngine.socialWinLogs;

    // Market closed — show closed room message instead of fake winners
    if (_signalEngine.isWeekendClosed) {
      return _buildGlassCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_clock_rounded,
                    color: AppConstants.textSecondary.withAlpha(120),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'VIP LIVE ROOM',
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textSecondary,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Icon(
                Icons.schedule_rounded,
                color: AppConstants.putRed.withAlpha(160),
                size: 32,
              ),
              const SizedBox(height: 8),
              Text(
                'السوق مغلق حالياً',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppConstants.putRed.withAlpha(200),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'الغرفة ستعود للعمل مع فتح الأسواق',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 10,
                  color: AppConstants.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _buildGlassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──
            Row(
              children: [
                _LivePulseDot(),
                const SizedBox(width: 8),
                Text(
                  'VIP LIVE ROOM',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppConstants.callGreen.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppConstants.callGreen.withAlpha(60),
                    ),
                  ),
                  child: Text(
                    '${12 + (logs.length % 8)} ONLINE',
                    style: GoogleFonts.outfit(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.callGreen,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Feed ──
            SizedBox(
              height: 140,
              child: logs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.hourglass_empty_rounded,
                            color: AppConstants.textSecondary.withAlpha(100),
                            size: 24,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'في انتظار أولى الصفقات...',
                            style: GoogleFonts.outfit(
                              color: AppConstants.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: logs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 5),
                      padding: EdgeInsets.zero,
                      itemBuilder: (context, index) {
                        return _buildWinCard(logs[index]);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWinCard(String log) {
    // Parse: "VIP Name (ID***) won +$profit on ASSET DIR"
    final isCall = log.contains('CALL');
    final dirColor = isCall ? AppConstants.callGreen : AppConstants.putRed;
    final dirIcon = isCall
        ? Icons.arrow_upward_rounded
        : Icons.arrow_downward_rounded;
    // Extract profit amount
    final profitMatch = RegExp(r'\+\$(\d+)').firstMatch(log);
    final profit = profitMatch != null ? profitMatch.group(0)! : '+\$---';
    // Extract name
    final nameMatch = RegExp(r'VIP (\w+) \(').firstMatch(log);
    final name = nameMatch != null ? nameMatch.group(1)! : 'Trader';
    // Extract asset
    final assetMatch = RegExp(r' on (.+?) (CALL|PUT)').firstMatch(log);
    final asset = assetMatch != null ? assetMatch.group(1)! : '---';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: dirColor.withAlpha(10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: dirColor.withAlpha(40)),
      ),
      child: Row(
        children: [
          // Avatar circle
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dirColor.withAlpha(25),
              border: Border.all(color: dirColor.withAlpha(80)),
            ),
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : 'V',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: dirColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Name + Asset
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VIP $name',
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  asset,
                  style: GoogleFonts.outfit(
                    fontSize: 9,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Direction badge
          Icon(dirIcon, color: dirColor, size: 13),
          const SizedBox(width: 4),
          // Profit
          Text(
            profit,
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: dirColor,
            ),
          ),
        ],
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
                                            sig.pair.replaceAll(' (OTC)', ''),
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

// ── Live pulse dot (animated) ─────────────────────────────────────────────────

class _LivePulseDot extends StatefulWidget {
  @override
  State<_LivePulseDot> createState() => _LivePulseDotState();
}

class _LivePulseDotState extends State<_LivePulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppConstants.callGreen.withValues(alpha: _anim.value),
          boxShadow: [
            BoxShadow(
              color: AppConstants.callGreen.withValues(
                alpha: _anim.value * 0.5,
              ),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mini price chart painter ──────────────────────────────────────────────────

class _MiniPricePainter extends CustomPainter {
  final double entryPrice;
  final double exitPrice;
  final Color profitColor;

  const _MiniPricePainter({
    required this.entryPrice,
    required this.exitPrice,
    required this.profitColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final higher = entryPrice > exitPrice ? entryPrice : exitPrice;
    final lower = entryPrice < exitPrice ? entryPrice : exitPrice;
    final range = higher - lower;
    const vPad = 18.0;

    double entryY, exitY;
    if (range == 0) {
      entryY = size.height * 0.5;
      exitY = size.height * 0.5;
    } else {
      final scale = (size.height - 2 * vPad) / range;
      entryY = vPad + (higher - entryPrice) * scale;
      exitY = vPad + (higher - exitPrice) * scale;
    }

    // Shaded zone between entry and exit
    final top = exitY < entryY ? exitY : entryY;
    final bottom = exitY > entryY ? exitY : entryY;
    final shadeH = (bottom - top).clamp(4.0, size.height);
    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, shadeH),
      Paint()..color = profitColor.withAlpha(22),
    );

    // Dashed entry line (neutral)
    _dashedLine(
      canvas,
      size.width,
      entryY,
      const Color(0xFF8899AA),
      dashed: true,
    );
    // Solid exit line (colored)
    _dashedLine(canvas, size.width, exitY, profitColor);

    // Dots
    canvas.drawCircle(
      Offset(size.width / 2, entryY),
      3.5,
      Paint()..color = const Color(0xFF8899AA),
    );
    canvas.drawCircle(
      Offset(size.width / 2, exitY),
      4.5,
      Paint()..color = profitColor,
    );
  }

  void _dashedLine(
    Canvas canvas,
    double width,
    double y,
    Color color, {
    bool dashed = false,
  }) {
    final p = Paint()
      ..color = color.withAlpha(dashed ? 120 : 200)
      ..strokeWidth = dashed ? 1.0 : 1.5;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(width, y), p);
      return;
    }
    double x = 0;
    while (x < width) {
      canvas.drawLine(Offset(x, y), Offset((x + 5).clamp(0, width), y), p);
      x += 10;
    }
  }

  @override
  bool shouldRepaint(_MiniPricePainter old) =>
      old.entryPrice != entryPrice || old.exitPrice != exitPrice;
}
