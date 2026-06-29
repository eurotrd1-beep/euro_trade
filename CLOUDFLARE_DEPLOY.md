# نشر على Cloudflare Pages (طريقة ربط GitHub — مضمونة)

> الرفع المباشر بـ `wrangler pages deploy` من جهازك بيفشل بسبب timeout في الشبكة
> لـ endpoint بتاع Cloudflare (مسار النت من مزود الخدمة عندك بطيء/محجوب لرفع الملفات).
> الحل: خلي Cloudflare يبني المشروع على سيرفراته من GitHub — كده ميمرّش على شبكتك خالص.

## الخطوات (مرة واحدة لكل تطبيق)

1. ادخل: https://dash.cloudflare.com → **Workers & Pages**
2. المشروع `euro-trade` موجود بالفعل → افتحه → تاب **Settings** → قسم **Builds & deployments**
   - أو اعمل: **Create application → Pages → Connect to Git**
3. اربط حساب **GitHub** واختار الريبو: **eurotrd1-beep/euro_trade**
4. إعدادات البناء (Build settings):
   - **Framework preset:** None
   - **Build command:**
     ```
     git clone https://github.com/flutter/flutter.git --depth 1 -b stable && export PATH="$PATH:$(pwd)/flutter/bin" && flutter build web --release
     ```
   - **Build output directory:** `build/web`
   - **Root directory:** (سيبها فاضية = جذر الريبو)
5. اضغط **Save and Deploy**

Cloudflare هيـ clone الـ Flutter، يبني، وينشر. الرابط هيكون:
`https://euro-trade.pages.dev`

## ملاحظات
- الـ `supabase_config.dart` (مفتاح anon) موجود في الريبو، فالبناء هيشتغل من غير أي إعداد إضافي.
- كل push جديد على `master` هيعمل deploy تلقائي.
- لو عايز تجرب الرفع المباشر تاني، جرّبه من شبكة تانية (موبايل هوت سبوت مثلاً):
  `npx wrangler pages deploy build/web --project-name=euro-trade --branch=main --commit-dirty=true`
