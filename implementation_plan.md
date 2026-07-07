# خطة تنفيذ "مضاعف الإجماع بين الفئات" (Category Consensus Multiplier)

هذه الخطة تشرح كيفية إقحام نظام "مضاعف الإجماع بين الفئات" الجديد فوق هرم القواعد الحالي في ملف [signal_engine.dart](file:///c:/projects/euro_trade/lib/services/signal_engine.dart) دون المساس بالملف المرجعي `المرجع_pro.json` أو تعديل منطق الهرم الأساسي.

---

## 1. التغييرات المقترحة في الكود

سنقوم بالتعديل على ملف واحد فقط وهو: [signal_engine.dart](file:///c:/projects/euro_trade/lib/services/signal_engine.dart).

### أ. تحديث نموذج قاعدة الاستراتيجية `StrategyRule`
* إضافة حقل `type` (النوع/الفئة) إلى فئة `StrategyRule` لاستقبال فئة المؤشر من ملف الـ JSON.
* في دالة `StrategyRule.fromJson` سنقوم بقراءة الحقل `type` أو `category` (لضمان التوافق الكامل مع أي مسمى مستخدم في ملف القواعد المرفوع).

```dart
class StrategyRule {
  final String indicator;
  final String condition;
  final String signal;
  final double score;
  final bool enabled;
  final String role;
  final String type; // الحقل الجديد لفئة التحليل للمؤشر

  // ... الحقول الأخرى ...

  const StrategyRule({
    required this.indicator,
    required this.condition,
    required this.signal,
    required this.score,
    this.enabled = true,
    this.role = '',
    this.type = '', // القيمة الافتراضية نص فارغ
    // ...
  });

  factory StrategyRule.fromJson(Map<String, dynamic> j) => StrategyRule(
    indicator: j['indicator'] as String,
    condition: j['condition'] as String,
    signal: j['signal'] as String,
    score: (j['score'] as num).toDouble(),
    enabled: j['enabled'] as bool? ?? true,
    role: j['role'] as String? ?? '',
    type: j['type'] as String? ?? j['category'] as String? ?? '', // يدعم كلا المفتاحين لضمان المرونة
    // ...
  );
}
```

---

### ب. إضافة دالة التقييم الموحدة `evaluateStrategyPro`
سنقوم بإضافة دالة جديدة داخل `SignalEngine` تقوم بتنفيذ الخطوات السبع بالترتيب المطلوب وإرجاع صيغة الـ JSON المحددة:

```dart
  /// الدالة الموحدة لتقييم الاستراتيجية بالكامل متضمنة مضاعف إجماع الفئات
  Map<String, dynamic> evaluateStrategyPro(DynamicStrategy strategy) {
    final cache = <String, dynamic>{};
    return evaluateStrategyProWithCache(strategy, cache);
  }

  Map<String, dynamic> evaluateStrategyProWithCache(
    DynamicStrategy strategy,
    Map<String, dynamic> cache,
  ) {
    final rules = strategy.rules.where((r) => r.enabled).toList();
    final primary = rules.where((r) => r.role == 'primary').toList();
    final confirm = rules.where((r) => r.role == 'confirm').toList();
    final filters = rules.where((r) => r.role == 'filter').toList();

    // ── [1] و [2]: تقييم قواعد primary وتحديد الفئات المتفقة لكل اتجاه ──
    double rawCall = 0.0;
    double rawPut = 0.0;
    final Set<String> categoriesCall = {};
    final Set<String> categoriesPut = {};

    for (final r in primary) {
      try {
        final raw = _computeIndicator(r, cache);
        if (!_checkCondition(r, raw)) continue;

        if (r.signal == 'CALL') {
          rawCall += r.score;
          if (r.type.isNotEmpty) categoriesCall.add(r.type);
        } else if (r.signal == 'PUT') {
          rawPut += r.score;
          if (r.type.isNotEmpty) categoriesPut.add(r.type);
        } else if (r.signal == 'dominant' || r.signal == 'confirm') {
          if (rawCall >= rawPut) {
            rawCall += r.score;
            if (r.type.isNotEmpty) categoriesCall.add(r.type);
          } else {
            rawPut += r.score;
            if (r.type.isNotEmpty) categoriesPut.add(r.type);
          }
        }
      } catch (_) {
        continue;
      }
    }

    // ── [3] تطبيق مضاعف الإجماع بين الفئات على مجموع النقاط ──
    double getMultiplier(int count) {
      if (count <= 1) return 1.0;
      if (count == 2) return 1.15;
      if (count == 3) return 1.3;
      return 1.5; // 4 فئات متفقة أو أكثر
    }

    final double multCall = getMultiplier(categoriesCall.length);
    final double multPut = getMultiplier(categoriesPut.length);

    final double multipliedCall = rawCall * multCall;
    final double multipliedPut = rawPut * multPut;

    // تحديد الاتجاه الغالب بناءً على النقاط المضاعفة
    final bool isPrimaryCall = multipliedCall >= multipliedPut;
    final String primaryDir = isPrimaryCall ? 'CALL' : 'PUT';
    final double winningPrimaryScore = isPrimaryCall ? multipliedCall : multipliedPut;

    // ── [4] بوابة الفلتر (filter) ──
    bool filterPassed = true;
    String? filterFailReason;
    for (final r in filters) {
      try {
        final raw = _computeIndicator(r, cache);
        if (!_checkCondition(r, raw)) {
          filterPassed = false;
          filterFailReason = 'فشل فلتر "${r.indicator}"';
          break;
        }
      } catch (_) {
        // إذا فشل الفلتر في الحساب يُعتبر غير مجتاز كبوابة أمان
        filterPassed = false;
        filterFailReason = 'خطأ أثناء حساب فلتر "${r.indicator}"';
        break;
      }
    }

    // ── [5] طبقة التأكيد (confirm) ──
    int agreed = 0;
    int totalConfirm = 0;
    int opposingTrue = 0;
    double confirmScoreAdded = 0.0;

    for (final r in confirm) {
      totalConfirm++;
      try {
        final raw = _computeIndicator(r, cache);
        final isTrue = _checkCondition(r, raw);
        final String ruleDir = (r.signal == 'dominant' || r.signal == 'confirm')
            ? primaryDir
            : r.signal;

        if (isTrue) {
          if (ruleDir == primaryDir) {
            agreed++;
            confirmScoreAdded += r.score;
          } else {
            opposingTrue++;
          }
        }
      } catch (_) {
        continue;
      }
    }

    // حساب النقاط النهائية (إضافة نقاط التأكيد للاتجاه الغالب فقط)
    double finalCall = multipliedCall;
    double finalPut = multipliedPut;
    if (primaryDir == 'CALL') {
      finalCall += confirmScoreAdded;
    } else {
      finalPut += confirmScoreAdded;
    }

    final double finalWinningScore = primaryDir == 'CALL' ? finalCall : finalPut;
    final double finalOppositeScore = primaryDir == 'CALL' ? finalPut : finalCall;
    final double gap = (finalWinningScore - finalOppositeScore).abs();

    // تحديد محاذاة التأكيد (confirm_alignment)
    String confirmAlignment = 'neutral';
    if (totalConfirm > 0) {
      if (opposingTrue > 0) {
        confirmAlignment = 'conflict';
      } else if (agreed > 0) {
        confirmAlignment = 'aligned';
      }
    }

    // ── [6] منطق القرار النهائي وتحديد البلوك ──
    String? reasonBlocked;
    final double minPrimary = strategy.pyramid?.minPrimaryScore ?? 3.0;

    if (winningPrimaryScore < minPrimary) {
      reasonBlocked = 'المرحلة الأولى (الأساس): النتيجة ${winningPrimaryScore.toStringAsFixed(1)} < الحد الأدنى $minPrimary';
    } else if (strategy.pyramid?.requireAllFilters == true && !filterPassed) {
      reasonBlocked = 'المرحلة الثالثة (الفلاتر): $filterFailReason';
    } else if (totalConfirm > 0 &&
        (agreed / totalConfirm) < (strategy.pyramid?.confirmationRatio ?? 0.5)) {
      final double ratio = agreed / totalConfirm;
      reasonBlocked = 'المرحلة الثانية (التأكيد): $agreed/$totalConfirm = ${(ratio * 100).round()}% < الحد الأدنى ${((strategy.pyramid?.confirmationRatio ?? 0.5) * 100).round()}%';
    } else if (gap < 4.0) {
      reasonBlocked = 'الفارق بين الاتجاهين ${gap.toStringAsFixed(1)} < حد الفارق الأدنى (4.0)';
    }

    final String resultStr = (reasonBlocked == null) ? 'SIGNAL' : 'NO_SIGNAL';
    final String? finalDirection = (reasonBlocked == null) ? primaryDir : null;

    // ── [7] تصنيف الثقة (confidence_tier) ──
    String? confidenceTier;
    if (reasonBlocked == null) {
      final int catCount = primaryDir == 'CALL' ? categoriesCall.length : categoriesPut.length;
      if (catCount >= 4 && confirmAlignment == 'aligned') {
        confidenceTier = 'STRONG';
      } else if ((catCount == 2 || catCount == 3) && confirmAlignment == 'aligned') {
        confidenceTier = 'MEDIUM';
      } else if (catCount >= 4 && confirmAlignment == 'neutral') {
        confidenceTier = 'MEDIUM';
      } else {
        confidenceTier = 'WEAK';
      }
    }

    final output = {
      'result': resultStr,
      'direction': finalDirection,
      'confidence_tier': confidenceTier,
      'raw_score': {'CALL': rawCall, 'PUT': rawPut},
      'final_score': {'CALL': finalCall, 'PUT': finalPut},
      'category_count': {'CALL': categoriesCall.length, 'PUT': categoriesPut.length},
      'gap': gap,
      'filter_passed': filterPassed,
      'confirm_alignment': confirmAlignment,
      'reason_blocked': reasonBlocked,
    };

    // حفظ النتيجة الأخيرة للاستعلام والمتابعة الخارجية
    _lastProResult = output;
    return output;
  }

  // تخزين النتيجة الأخيرة وإتاحتها خارجياً
  Map<String, dynamic>? _lastProResult;
  Map<String, dynamic>? get lastProResult => _lastProResult;
```

---

### ج. ربط الدالة بالهرم الحالي في `_evaluateRulesPyramid`
سنقوم بإعادة صياغة الدالة الحالية `_evaluateRulesPyramid` لتعتمد بالكامل على الدالة الموحدة `evaluateStrategyProWithCache` مما يضمن سريان منطق الفئات والمضاعفات والـ gap على المراقبة الفورية (Monitor) وأي استخدام آخر تلقائياً:

```dart
  double _evaluateRulesPyramid(
    DynamicStrategy strategy,
    Map<String, dynamic> cache,
  ) {
    final proResult = evaluateStrategyProWithCache(strategy, cache);
    
    // وضع سبب الرفض في المتغير المخصص للمهاد الذكي
    _pyramidRejectReason = proResult['reason_blocked'] ?? '';
    
    if (proResult['result'] == 'SIGNAL') {
      final double callScore = proResult['final_score']['CALL'] ?? 0.0;
      final double putScore = proResult['final_score']['PUT'] ?? 0.0;
      return callScore - putScore;
    } else {
      return 0.0;
    }
  }
```

---

## 2. خطة التحقق والاختبار (Verification Plan)

### التحقق التلقائي
1. سنقوم بكتابة اختبار وحدة (Unit Test) بسيط يحاكي تشغيل استراتيجية تتطابق مع شروط المضاعف للتأكد من حسابات:
   * النقاط الخام مقابل النقاط المضاعفة.
   * عدد الفئات المتفقة وتأثيرها على معامل الضرب.
   * التحقق من ثبات شروط الفلتر والـ gap المضاف حديثاً (gap >= 4).
   * إخراج الـ JSON بنفس الصيغة المطلوبة في البرومت.

### التحقق اليدوي
1. تشغيل التطبيق والتأكد من عدم وجود أي أخطاء تجميع (Build/Compile errors) في Flutter.
2. تتبع سجلات التحليل اللحظي للتأكد من عمل نظام المراقبة الذكي (Smart Monitoring) بشكل طبيعي دون تعثر.
