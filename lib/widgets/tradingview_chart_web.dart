import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'dart:math' show min;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants.dart';

class TradingViewChart extends StatefulWidget {
  final String  symbol;
  final String  interval;
  final String  mode;
  final bool    guaranteedWin;
  // Signal-driven trade (set by parent when signal fires)
  final String? signalDirection;   // 'CALL' | 'PUT' — null = no signal
  final double? signalEntryPrice;
  final int?    signalDurationMin;
  // Called once after JS init; provides a closure to read the latest TV price
  final void Function(double Function() priceGetter)? onReady;

  const TradingViewChart({
    super.key,
    required this.symbol,
    this.interval         = '1m',
    this.mode             = 'sim',
    this.guaranteedWin    = false,
    this.signalDirection,
    this.signalEntryPrice,
    this.signalDurationMin,
    this.onReady,
  });

  @override
  State<TradingViewChart> createState() => _TradingViewChartState();
}

enum _TradeState { idle, active }

class _TradingViewChartState extends State<TradingViewChart> {
  late final String _id;

  _TradeState _tradeState  = _TradeState.idle;
  String  _direction       = '';
  int     _durationMin     = 1;
  double  _entryPrice      = 0;
  double  _currentPrice    = 0;
  int     _secondsLeft     = 0;
  int     _totalSeconds    = 0;
  Timer?  _countdownTimer;

  String get _displaySymbol =>
      widget.symbol.replaceFirst(RegExp(r'^[A-Z]+:'), '').replaceAll('_', '/');

  @override
  void initState() {
    super.initState();
    _id = 'cc-${DateTime.now().millisecondsSinceEpoch}';
    ui.platformViewRegistry.registerViewFactory(_id, (_) {
      return html.DivElement()
        ..id = _id
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = '#0A0714';
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jsInit());
  }

  @override
  void didUpdateWidget(TradingViewChart old) {
    super.didUpdateWidget(old);

    // Symbol / interval / mode changed → restart chart
    if (old.symbol != widget.symbol ||
        old.interval != widget.interval ||
        old.mode != widget.mode) {
      if (_tradeState == _TradeState.active) _cancelTrade();
      _jsUpdate();
    }

    // Signal fired: direction changed to a new non-null value
    final newDir = widget.signalDirection;
    final oldDir = old.signalDirection;
    if (newDir != null &&
        newDir != 'WAIT' &&
        newDir != oldDir &&
        _tradeState == _TradeState.idle) {
      _autoOpenTrade(
        newDir,
        widget.signalEntryPrice ?? 0,
        widget.signalDurationMin ?? 1,
      );
    }
  }

  // ── JS bridge ─────────────────────────────────────────────────────────────

  void _jsInit() {
    try {
      js.context['CandleChart']
          ?.callMethod('init', [_id, widget.symbol, widget.interval, widget.mode]);
      widget.onReady?.call(_getLastPrice);
    } catch (_) {}
  }

  void _jsUpdate() {
    try {
      js.context['CandleChart']
          ?.callMethod('update', [_id, widget.symbol, widget.interval, widget.mode]);
    } catch (_) {}
  }

  double _getLastPrice() {
    try {
      final v = js.context['CandleChart']?.callMethod('getLastPrice', [_id]);
      if (v != null) return (v as num).toDouble();
    } catch (_) {}
    return 0;
  }

  void _setEntryLine(double? price, String direction) {
    try {
      js.context['CandleChart']?.callMethod(
        'setEntryLine',
        [_id, price, direction.isEmpty ? null : direction],
      );
    } catch (_) {}
  }

  void _jsTradeState({required bool active}) {
    try {
      js.context['CandleChart']?.callMethod('setTradeState', [
        _id,
        active,
        active ? _direction : '',
        active ? _entryPrice : 0.0,
        active ? _secondsLeft : 0,
        active && widget.guaranteedWin && widget.mode == 'tv',
      ]);
    } catch (_) {}
  }

  // ── Trade logic ────────────────────────────────────────────────────────────

  /// Auto-opens a trade driven by the signal engine.
  void _autoOpenTrade(String direction, double entryPrice, int durationMin) {
    if (entryPrice == 0) return;
    final totalSec = durationMin * 60;
    setState(() {
      _tradeState   = _TradeState.active;
      _direction    = direction;
      _durationMin  = durationMin;
      _entryPrice   = entryPrice;
      _currentPrice = entryPrice;
      _secondsLeft  = totalSec;
      _totalSeconds = totalSec;
    });
    _setEntryLine(entryPrice, direction);
    _jsTradeState(active: true);
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      final cp = _getLastPrice();
      setState(() {
        _secondsLeft--;
        if (cp > 0) _currentPrice = cp;
      });
      _jsTradeState(active: true);
      if (_secondsLeft <= 0) {
        t.cancel();
        _closeTrade();
      }
    });
  }

  void _cancelTrade() {
    _countdownTimer?.cancel();
    _jsTradeState(active: false);
    _setEntryLine(null, '');
    setState(() {
      _tradeState   = _TradeState.idle;
      _currentPrice = 0;
    });
  }

  void _closeTrade() {
    final exitPrice = _getLastPrice();
    final isCall    = _direction == 'CALL';
    final isWin     = isCall ? exitPrice > _entryPrice : exitPrice < _entryPrice;

    _jsTradeState(active: false);
    _setEntryLine(null, '');
    final dir      = _direction;
    final entry    = _entryPrice;
    final durMin   = _durationMin;
    setState(() {
      _tradeState   = _TradeState.idle;
      _currentPrice = 0;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showReviewDialog(
          direction:       dir,
          entryPrice:      entry,
          exitPrice:       exitPrice,
          durationMinutes: durMin,
          isWin:           isWin,
        );
      }
    });
  }

  // ── Review dialog ──────────────────────────────────────────────────────────

  void _showReviewDialog({
    required String direction,
    required double entryPrice,
    required double exitPrice,
    required int    durationMinutes,
    required bool   isWin,
  }) {
    final color       = isWin ? AppConstants.callGreen : AppConstants.putRed;
    final outcomeText = isWin ? 'صفقة ناجحة ✅' : 'صفقة خاسرة ❌';
    final dirText     = direction == 'CALL' ? 'صعود 🟢' : 'هبوط 🔴';

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppConstants.spaceBackground.withAlpha(220),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          width: min(MediaQuery.of(ctx).size.width, 420),
          decoration: BoxDecoration(
            color: AppConstants.cardBgColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppConstants.borderGlow, width: 1.5),
            boxShadow: [
              BoxShadow(color: color.withAlpha(25), blurRadius: 28, spreadRadius: 6),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isWin
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      color: color,
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
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: color.withAlpha(18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withAlpha(80)),
                  ),
                  child: Text(
                    outcomeText,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppConstants.spaceBackground.withAlpha(150),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppConstants.borderGlow.withAlpha(120)),
                  ),
                  child: Column(
                    children: [
                      _statRow('زوج العملات',  _displaySymbol),
                      const Divider(color: AppConstants.borderGlow, height: 16),
                      _statRow('نوع الاتجاه',  dirText),
                      const Divider(color: AppConstants.borderGlow, height: 16),
                      _statRow('سعر الدخول',   AppConstants.formatPrice(entryPrice)),
                      const Divider(color: AppConstants.borderGlow, height: 16),
                      _statRow('سعر الإغلاق',  AppConstants.formatPrice(exitPrice)),
                      const Divider(color: AppConstants.borderGlow, height: 16),
                      _statRow('المدة',         '$durationMinutes دقيقة'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.accentBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 8,
                    shadowColor: AppConstants.accentBlue.withAlpha(120),
                  ),
                  child: Text(
                    'متابعة الصفقة التالية 🚀',
                    style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label,
          style: GoogleFonts.outfit(fontSize: 12, color: AppConstants.textSecondary)),
      Text(value,
          style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppConstants.textPrimary)),
    ],
  );

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _countdownTimer?.cancel();
    try { js.context['CandleChart']?.callMethod('destroy', [_id]); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: 300, child: HtmlElementView(viewType: _id)),
        _buildTradeBar(),
      ],
    );
  }

  Widget _buildTradeBar() {
    if (_tradeState != _TradeState.active) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.cardBgColor,
        border: Border(top: BorderSide(color: AppConstants.borderGlow, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: _buildActiveBar(),
    );
  }

  // ── Active bar (with live P&L card) ───────────────────────────────────────

  Widget _buildActiveBar() {
    final isCall   = _direction == 'CALL';
    final color    = isCall ? AppConstants.callGreen : AppConstants.putRed;
    final progress = _totalSeconds > 0 ? _secondsLeft / _totalSeconds : 0.0;
    final mins     = _secondsLeft ~/ 60;
    final secs     = _secondsLeft % 60;
    final timeStr  =
        '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    // P&L
    final hasLive   = _currentPrice > 0 && _entryPrice > 0;
    final diff      = hasLive ? (_currentPrice - _entryPrice) : 0.0;
    final isWinning = isCall ? diff > 0 : diff < 0;
    final plColor   = isWinning ? AppConstants.callGreen : AppConstants.putRed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Top row: direction | entry | countdown ──
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withAlpha(25),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withAlpha(100)),
              ),
              child: Text(
                isCall ? '▲ CALL' : '▼ PUT',
                style: GoogleFonts.outfit(
                    fontSize: 13, fontWeight: FontWeight.bold, color: color),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('دخول',
                    style: GoogleFonts.outfit(
                        fontSize: 10, color: AppConstants.textSecondary)),
                Text(AppConstants.formatPrice(_entryPrice),
                    style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppConstants.textPrimary)),
              ],
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('الوقت المتبقي',
                    style: GoogleFonts.outfit(
                        fontSize: 10, color: AppConstants.textSecondary)),
                Text(timeStr,
                    style: GoogleFonts.outfit(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: _secondsLeft <= 10
                            ? AppConstants.putRed
                            : AppConstants.accentCyan,
                        fontFeatures: [const FontFeature.tabularFigures()])),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),

        // ── Progress bar ──
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: AppConstants.borderGlow,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),

        // ── Live P&L card ──
        if (hasLive) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: plColor.withAlpha(18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: plColor.withAlpha(70)),
            ),
            child: Row(
              children: [
                // Current price
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('السعر الحالي',
                        style: GoogleFonts.outfit(
                            fontSize: 9, color: AppConstants.textSecondary)),
                    Text(AppConstants.formatPrice(_currentPrice),
                        style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppConstants.textPrimary)),
                  ],
                ),
                const Spacer(),
                // Trend icon
                Icon(
                  isWinning
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded,
                  color: plColor,
                  size: 22,
                ),
                const SizedBox(width: 8),
                // Win / Loss label
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('النتيجة الآن',
                        style: GoogleFonts.outfit(
                            fontSize: 9, color: AppConstants.textSecondary)),
                    Text(
                      isWinning ? 'رابح ✅' : 'خاسر ❌',
                      style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: plColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
