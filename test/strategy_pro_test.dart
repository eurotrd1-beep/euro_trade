import 'package:flutter_test/flutter_test.dart';
import 'package:euro_trade/services/signal_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Category Consensus Multiplier & Confidence Tier tests', () {
    late SignalEngine engine;

    setUp(() {
      engine = SignalEngine();
      final now = DateTime.now();
      final candles = List<Candle>.generate(100, (i) {
        final price = 10.0 + i; // strong rising trend
        return Candle(
          open: price - 0.5,
          high: price + 0.5,
          low: price - 1.0,
          close: price,
          time: now.subtract(Duration(minutes: 100 - i)),
          volume: (i == 99) ? 20.0 : 10.0, // Volume spike on last candle
        );
      });
      engine.setRealCandles(candles);
    });

    test('STRONG tier - 3 categories, aligned confirmation', () {
      final strategyJson = {
        'name': 'Pro Multiplier Test',
        'version': '1.0',
        'pyramid': {
          'min_primary_score': 3.0,
          'confirmation_ratio': 0.3,
          'require_all_filters': true,
        },
        'rules': [
          // Category 1: Oscillators (RSI > 30) -> true
          {
            'indicator': 'rsi',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 3.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Oscillators',
            'period': 14,
            'value': 30.0,
          },
          // Category 2: Trend (EMA > 50) -> true
          {
            'indicator': 'ema',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 2.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Trend',
            'period': 20,
            'value': 50.0,
          },
          // Category 3: Momentum (MACD main line > 0) -> true
          {
            'indicator': 'macd_line',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 1.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Momentum',
            'value': 0.0,
          },
          // Confirm rule: Volume > average (aligned)
          {
            'indicator': 'volume',
            'condition': 'gt_average',
            'signal': 'CALL',
            'score': 1.0,
            'enabled': true,
            'role': 'confirm',
          },
        ]
      };

      final strategy = DynamicStrategy.fromJson(strategyJson);
      final result = engine.evaluateStrategyPro(strategy);

      expect(result['result'], equals('SIGNAL'));
      expect(result['direction'], equals('CALL'));
      expect(result['category_count']['CALL'], equals(3));
      expect(result['confirm_alignment'], equals('aligned'));
      expect(result['confidence_tier'], equals('STRONG')); // >= 3 categories & aligned (no conflict)
    });

    test('MEDIUM tier - 2 categories, aligned confirmation', () {
      final strategyJson = {
        'name': 'Pro Multiplier Test',
        'version': '1.0',
        'pyramid': {
          'min_primary_score': 3.0,
          'confirmation_ratio': 0.3,
          'require_all_filters': true,
        },
        'rules': [
          // Category 1: Oscillators (RSI > 30) -> true
          {
            'indicator': 'rsi',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 3.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Oscillators',
            'period': 14,
            'value': 30.0,
          },
          // Category 2: Trend (EMA > 50) -> true
          {
            'indicator': 'ema',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 2.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Trend',
            'period': 20,
            'value': 50.0,
          },
          // Confirm rule: Volume > average (aligned)
          {
            'indicator': 'volume',
            'condition': 'gt_average',
            'signal': 'CALL',
            'score': 1.0,
            'enabled': true,
            'role': 'confirm',
          },
        ]
      };

      final strategy = DynamicStrategy.fromJson(strategyJson);
      final result = engine.evaluateStrategyPro(strategy);

      expect(result['result'], equals('SIGNAL'));
      expect(result['direction'], equals('CALL'));
      expect(result['category_count']['CALL'], equals(2));
      expect(result['confirm_alignment'], equals('aligned'));
      expect(result['confidence_tier'], equals('MEDIUM')); // 2 categories & aligned (no conflict)
    });

    test('MEDIUM tier - 3 categories but conflict confirmation', () {
      final strategyJson = {
        'name': 'Pro Multiplier Test',
        'version': '1.0',
        'pyramid': {
          'min_primary_score': 3.0,
          'confirmation_ratio': 0.0, // allow conflict to proceed
          'require_all_filters': true,
        },
        'rules': [
          // Category 1: Oscillators (RSI > 30) -> true
          {
            'indicator': 'rsi',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 3.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Oscillators',
            'period': 14,
            'value': 30.0,
          },
          // Category 2: Trend (EMA > 50) -> true
          {
            'indicator': 'ema',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 2.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Trend',
            'period': 20,
            'value': 50.0,
          },
          // Category 3: Momentum (MACD main line > 0) -> true
          {
            'indicator': 'macd_line',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 1.0,
            'enabled': true,
            'role': 'primary',
            'type': 'Momentum',
            'value': 0.0,
          },
          // Confirm rule: Volume > average, signal PUT -> evaluates to true but conflicts (PUT vs primary CALL)
          {
            'indicator': 'volume',
            'condition': 'gt_average',
            'signal': 'PUT',
            'score': 1.0,
            'enabled': true,
            'role': 'confirm',
          },
        ]
      };

      final strategy = DynamicStrategy.fromJson(strategyJson);
      final result = engine.evaluateStrategyPro(strategy);

      expect(result['category_count']['CALL'], equals(3));
      expect(result['confirm_alignment'], equals('conflict'));
      expect(result['confidence_tier'], equals('MEDIUM')); // >= 3 categories but conflict in confirmation
    });

    test('WEAK tier - 1 category, neutral confirmation', () {
      final strategyJson = {
        'name': 'Pro Multiplier Test',
        'version': '1.0',
        'pyramid': {
          'min_primary_score': 1.0,
          'confirmation_ratio': 0.0,
          'require_all_filters': true,
        },
        'rules': [
          // Category 1: Oscillators (RSI > 30) -> true
          {
            'indicator': 'rsi',
            'condition': 'gt',
            'signal': 'CALL',
            'score': 5.0, // High score to satisfy gap >= 4
            'enabled': true,
            'role': 'primary',
            'type': 'Oscillators',
            'period': 14,
            'value': 30.0,
          },
        ]
      };

      final strategy = DynamicStrategy.fromJson(strategyJson);
      final result = engine.evaluateStrategyPro(strategy);

      expect(result['result'], equals('SIGNAL'));
      expect(result['direction'], equals('CALL'));
      expect(result['category_count']['CALL'], equals(1));
      expect(result['confirm_alignment'], equals('neutral'));
      expect(result['confidence_tier'], equals('WEAK')); // 1 category
    });
    test('Direct category classification mapping test', () {
      // Trend
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'ichimoku', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'supertrend', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'vortex', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'aroon', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'parabolic_sar', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'mtf', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Trend'));
      
      // Price Levels
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'pivot', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Price Levels'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'pdh', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Price Levels'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'pdl', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Price Levels'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'orb', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Price Levels'));
      
      // Advanced Statistics
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'z_score', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Advanced Statistics'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'hurst_exponent', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Advanced Statistics'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'choppiness', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Advanced Statistics'));
      
      // Rare Patterns
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'three_bar_reversal', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Rare Patterns'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'island_reversal', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Rare Patterns'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'exhaustion_gap', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Rare Patterns'));
      expect(engine.getCategoryForIndicator(StrategyRule(indicator: 'gartley', signal: 'CALL', condition: 'gt', score: 1.0)), equals('Rare Patterns'));
    });

    test('Automatic category classification for untyped indicators in strategy', () {
      final strategyJson = {
        'name': 'Auto Category Test',
        'version': '1.0',
        'pyramid': {
          'min_primary_score': 1.0,
          'confirmation_ratio': 0.0,
          'require_all_filters': false,
        },
        'rules': [
          // Trend: supertrend (without type in JSON) -> resolves to Trend
          {
            'indicator': 'supertrend',
            'condition': 'neq',
            'signal': 'CALL',
            'score': 5.0, // High score to clear gap threshold >= 4
            'enabled': true,
            'role': 'primary',
            'period': 14,
            'pattern': 'xyz',
          },
          // Price Levels: bb_upper (without type in JSON) -> resolves to Price Levels
          {
            'indicator': 'bb_upper',
            'condition': 'gte',
            'signal': 'CALL',
            'score': 5.0,
            'enabled': true,
            'role': 'primary',
            'value': 0.0,
          },
        ]
      };

      final strategy = DynamicStrategy.fromJson(strategyJson);
      final result = engine.evaluateStrategyPro(strategy);

      print('Untyped indicator strategy result: $result');

      expect(result['result'], equals('SIGNAL'));
      expect(result['direction'], equals('CALL'));
      expect(result['category_count']['CALL'], equals(2));
      expect(result['confidence_tier'], equals('MEDIUM')); // 2 categories & aligned
    });
  });
}
