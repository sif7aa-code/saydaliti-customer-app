import { EV, publish } from './events.js';

const int = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d);

/** النصّ العربي لحالة الطلب — يُكتب في إشعار FCM الظاهر على الشاشة. */
const AR_STATUS = {
  pending: 'قيد الانتظار',
  accepted: 'تم القبول',
  delivering: 'قيد التوصيل',
  delivered: 'تم التوصيل',
  rejected: 'مرفوض',
  cancelled: 'ملغى',
};

const arOf = (st) => AR_STATUS[String(st || '').trim()] || String(st || '');

/**
 * ★★ نوع صفّ الإشعار في القاعدة — لا اسم الحالة.
 *   التطبيق يبني مفتاح منع التكرار من (orderId + type)، والمشغّل
 *   يكتب نوعاً مختلفاً عن الحالة في موضعين: طلب جديد ⇒ new_order،
 *   وإعادة إلى الانتظار ⇒ reopened. لو أرسلنا اسم الحالة لأنشأ
 *   التطبيق مفتاحاً لا يطابق الصف أبداً ⇒ صوت مكرّر.
 */
function rowTypeFor(st, isNew) {
  if (isNew) return 'new_order';
  if (st === 'pending') return 'reopened';
  // ★ `notify_order_status` تكتب صفوف البنود بنوع واحد `item_changed`
  //   لكل أنواعها الثلاثة — فلو أرسلنا اسم الحالة لأنشأ التطبيق
  //   مفتاحاً لا يلتقي بالمفتاح المكرّر أبداً.
  if (st === 'item_replaced' || st === 'price_changed' || st === 'item_deleted') {
    return 'item_changed';
  }
  return String(st || '');
}

/** مفتاح الصوت/القناة — مطابق لما تكتبه `notify_order_status`. */
function soundKeyFor(st, isNew) {
  if (isNew) return 'new_order';
  if (st === 'pending') return 'accepted';
  if (st === 'cancelled') return 'rejected';
  if (st === 'item_replaced' || st === 'item_deleted') return 'replaced';
  return String(st || '');
}

/**
 * مراقب Supabase: يكشف تغيّر الطلبات والأسعار ثم يبثّها.
 *
 * ★ REST كل ثانيتين بدل LISTEN/NOTIFY: الأخير يحتاج DATABASE_URL
 *   (كلمة مرور). يحتاج هذا service_role فقط.
 *   التوصيل للجهاز شبه فوري لأن الاستطلاع واحد ثم يُبثّ لكل العملاء،
 *   بدل أن يسأل كل جهاز القاعدة بنفسه.
 *
 * ★ البصمة: نقرأ آخر N صفاً ونقارن (updated_at, status/price).
 *   لا نحتفظ بكل الجدول ولا نقرأ آلاف الصفوف.
 *
 * ★ لا نكتب بيانات ولا نعدّل صفوفاً — القراءة فقط. الاستثناءات:
 *   علامة `pushed_at` عبر دالة محميّة (`mark_notification_pushed`)
 *   بعد نجاح FCM، وقراءة «هل الصفّ حيّ؟» عبر
 *   (`notification_rows_live`) قبل الإرسال — حتى يستهلك التطبيق
 *   الصف بصمت ولا يُرسل FCM لمن رآه بالفعل.
 */
export class SupabaseWatcher {
  constructor({
    url,
    key,
    pollMs = 2000,
    idleMs = 5000,
    idleMaxMs = 10000,
    limit = 60,
    sweepMs = 60000,
    purgeMs = 300000,
    fcm = null,
    adminPhones = '',
    onError = () => {},
    onLog = () => {},
  }) {
    this.url = String(url || '').replace(/\/$/, '');
    this.key = String(key || '');
    this.pollMs = int(pollMs, 2000);
    this.limit = int(limit, 60);
// ★ مُرسِل FCM — هو ما يوصل الإشعار والتطبيق **مغلق**. بدونه
    //   لا يخرج شيء من الجهاز أصلاً: بثّ SSE يصل التطبيق المفتوح
    //   وحده، فيبقى الإشعار محصوراً داخله.
    this.fcm = fcm;
    // ★ فترة السكون: نُبطئ الاستطلاع عندما لا يتغيّر شيء.
    //
    // ★★ خُفّضت من أجل السرعة (طلب ٢٠٢٦-١٠-١٠): كانت ٢٠٠٠٠/٣٠٠٠٠،
    //   أي أن أول طلب جديد قد لا يُبثّ ولا يرسل FCM إلا بعد ٢٠-٣٠
    //   ثانية من خمول السيرفر — وهو بالضبط «يتأخر الطلب» الذي شكا
    //   منه. الآن السكون ٥٠٠٠ مللي وحدّه الأقصى ١٠٠٠٠: أسوأ حال
    //   ١٠ ثوانٍ لا ٣٠، ومع أول حدث ترجع السرعة الكاملة فوراً.
    //   القيمتان قابلتان للضبط من systemd دون لمس الكود:
    //   `WATCH_IDLE_MS` و`WATCH_IDLE_MAX_MS`.
    this.baseIdleMs = int(idleMs, 5000);
    this.idleMaxMs = int(idleMaxMs, 10000);
    this.idleMs = this.baseIdleMs;
    this._idleStreak = 0;
    this._lastWait = null;
    // ★ بوابة الجولة (٢٠٢٦-١١-٠٦ — خفض Egress، رسالة حصة Supabase).
    //
    //   الجولة الكاملة كانت ١٣٫١٣ كيلوبايت تُدفع كل ٢–١٠ ثوانٍ على
    //   مدار الساعة، أي ٣٫٢–٦٫٥ غيغابايت شهرياً من الاستهلاك **وهي
    //   تقيس الفراغ**: النوافذ الثلاث كلها صفوف قديمة لم يمسها أحد.
    //   البوابة تسأل سؤالاً أصغر وأرخص: «هل تحرّك شيء في القاعدة؟»
    //   بأربعة قياسات (٤٫٢٩ كيلوبايت) ثم لا تفتح النوافذ إلا إذا
    //   تحرّك فعلاً، فالإشعار يبقى في وقته تماماً والاستهلاك يقل.
    //
    //   لا تُفقد أي إشارة، لأن البوابة تتجاوزها ثلاث حالات:
    //     · طلب نشط (`activeOrders > 0`) ⇒ جولة كاملة دائماً: تغيير
    //       الحالة أو البند أو السعر لا يحدث إلا و الطلب معلّق، و
    //       هناك نبقى بالسرعة القصوى بلا وسطاء.
    //     · `sweepMs` (دقيقة) ⇒ جولة كاملة إجبارية، حتى تُرى الحذف
    //       والتعديلات التي لا يظهرها الطابع (أسعار البنود لا تغيّر
    //       `created_at`) و حتى تُعاد النافذة إلى حجمها الطبيعي.
    //     · فشل القياس نفسه ⇒ جولة كاملة (`_changed` ترجع true).
    //   أي أن أسوأ ما تفعله البوابة هو استهلاك زائد، لا ضياع إشعار.
    this.sweepMs = int(sweepMs, 60000);
    this._marks = null;
    this._sweepAt = 0;
    // ★★ تنظيف صفحة «التنبيهات والإشعارات» (طلب ٢٠٢٦-١١-٠٦): حذف
    //   صفوف `notifications` الأقدم من `purgeMs` كل `purgeMs` — على
    //   السيرفر وحده، لا يعتمد على بقاء التطبيق مفتوحاً. الجدول هذا
    //   وحده: لا يُمسّ `orders` ولا أي جدول آخر، والطلب يُقيَّد بعمود
    //   `created_at` في `notifications` فقط. قابل للضبط من systemd
    //   بلا لمس الكود: `WATCH_PURGE_MS`.
    this.purgeMs = int(purgeMs, 300000);
    this._purgeAt = 0;
    // ★ بعد أي «نبضة» من الجهاز الذي كتب التغيير نبقى بالسرعة الكاملة
    //   هذه المدة، فلا يضيع حدث لاحق في دورة سكون.
    this.hotAfterPokeMs = 8000;
    this._hotUntil = 0;
    // ★ عمر التوكن المسموح **للصفوف المعطَّلة فقط**: صف لم يظهر صاحبه
    //   في التطبيق منذ هذا الوقت = جهاز مهجور، ولا يكون «حسابه الثاني
    //   على نفس الهاتف حيّاً» ⇒ لا يُرسَل له. الحيّ (`is_active=true`)
    //   لا يُشترط فيه ظهور حديث: التطبيق المغلق هو الغاية من المُرسِل.
    this.tokenStaleMs = 21 * 24 * 3600 * 1000;
    // طلبات غير منجَزة (pending/accepted/delivering) ⇒ إبقاء السرعة.
    this.activeOrders = 0;
    this.onError = onError;
    this.onLog = onLog;

    this.timer = null;
    this.busy = false;
    this.seen = {
      orders: new Map(),
      products: new Map(),
      productNames: new Map(),
      items: new Map(),
    };
    // shop_id => { name, image, owner } — نُخزّنه لأن الصنف المحذوف من
    // الطلب لا يُرجَع بعد الحذف، فنحتاج شعار المتجر من الذاكرة،
    // وصاحبه (`owner_phone`) يحتاج إشعار الطلب الجديد فوراً.
    this.shops = new Map();
    // ★ طلبات جديدة لم تُحسم متاجرها بعد (الطلب يُقيد قبل بنوده):
    //   orderId => { serial, phone, at, driverPushed }
    this.pendingOwners = new Map();
    // ★ أرقام الحسابات التي تُشعَر بالطلبات الجديدة. مصدرها دوال
    //   محميّة في القاعدة (`notify_driver_phones` / `notify_admin_phones`)
    //   لأن مفتاح anon لم يعد يرى جدول users بعد SQL_HARDEN_STAGE2 —
    //   والنتيجة كانت مجموعة مندوبين **فارغة** صامتة: صفر إشعار
    //   FCM لكل الهواتف، وهو عين «لا تأتي لكل الهواتف».
    this.drivers = new Set();
    this.admins = new Set();
    // ★ أدمن من الإعدادات (env `NOTIFY_ADMIN_PHONES`) — يبثّ الإشعار
    //   لهاتف الأدمن حتى قبل تنفيذ دوال الأرقام في القاعدة.
    for (const p of String(adminPhones || '').split(/[,\s]+/)) {
      if (p.trim()) this.admins.add(p.trim());
    }
    this._driversAt = 0;
    this._adminsAt = 0;
    this.tokens = new Map();
    // ★ توكن ⇒ منصته ('android'|'web') — بها يُختار مشروع FCM.
    this.tokenPlatform = new Map();
    this._tokensAt = 0;
    this.stats = {
      ticks: 0, orderEvents: 0, productEvents: 0, deletedEvents: 0,
      itemEvents: 0, errors: 0, lastAt: 0,
      // ★ أرقام قابلة للقراءة من /api/health — بها يُعرف العطل نفسه
      //   بدل تخمينه: كم مندوباً مُحمّلاً، كم صفاً حيّاً، كم نبضة.
      drivers: 0, admins: 0, tokenRows: 0, tokenPhones: 0, tokenInactive: 0,
      tokenWeb: 0,
      pokes: 0,
      // ★ إشعارات أصحاب المتاجر الناجحة — يظهر في /api/health
      //   فلا يبقى «هل وصل صاحب المتجر؟» تخميناً.
      ownerPushes: 0,
      // ★ جسر الإشعارات العامة (غير الطلبات): كم دُفع، كم وُسِم،
      //   وكم محاولة باءت بالفشل لأن الدالتين غير منفّذتين.
      notifyPushed: 0,
      notifyMarked: 0,
      notifyUnavailable: 0,
      // ★ جولة كاملة مقابل بوابة (للقراءة من /api/health): `gated`
      //   كم مرة اكتفت البوابة بالقياس، و`fullRounds` كم جولة كاملة
      //   فُتحت نافذتها. منهما يُحسب الاستهلاك الحقيقي بلا تخمين.
      gated: 0,
      fullRounds: 0,
      // ★ التنظيف الدوري للإشعارات (٥ دقائق): كم دورة تنظيف، وكم
      //   صفّاً حُذف — يُقرآن من /api/health فلا يبقى «هل يعمل؟»
      //   تخميناً.
      purgeRuns: 0,
      purgedRows: 0,
    };
    // ★ جسر الإشعارات العامة: علامة البداية يضعها أول دورة بنفسه
    //   (`_pushNotificationRows`) عند «الآن» ناقص هذه النافذة، فلا
    //   يُنبَّه على ما كُتب قبل أن يعمل السيرفر.
    this.notifyLookbackMs = 15000;
    this._notifyAfter = '';
    this._notifyDisabled = false;
    // الإطفاء بعد ثلاث **متتاليات** لا ثلاث في العمر كله: عطل شبكة
    // عابر عند الإقلاع لا ينبغي أن يعدم الجسر إلى الأبد.
    this._notifyFails = 0;
    this.lastStatus = 0;
  }

  get enabled() {
    return this.url.startsWith('https://') && this.key.length > 20;
  }

  start() {
    if (!this.enabled || this.timer) return false;
    this.stats.admins = this.admins.size;
    this.onLog(
      `المراقب يعمل كل ${this.pollMs}ms — سكون ${this.baseIdleMs}ms/حد ${this.idleMaxMs}ms — أدمن من الإعدادات ${this.admins.size} — url=${this.url}`,
    );
    // ★★ تحميل مسبق للمندوبين والأدمن والأجهزة.
    //   كان هذا التحميل يحدث لأول مرة **داخل** أول إشعار، فيُضاف
    //   زمن ثلاث قراءات للقاعدة إلى ثانية الإرسال الأولى بعد كل
    //   تشغيل — ونحن نعد المستخدم بأنها «بنفس الثانية». الآن
    //   الأهداف جاهزة قبل أول حدث، ويظهر عددها في /api/health
    //   فوراً فتُرى الحالة الحقيقية بلا انتظار.
    this._preloadTargets();
    // أول فحص فوراً (لا انتظار)، ثم [_loop] يقرر الباقي.
    this._lastWait = 0;
    this._loop();
    return true;
  }

  /**
   * ★ يحمّل أهداف الإشعار عند الإقلاع ويسجّلها في الصفحة الأولى من
   *   notify.log — بها يُعرف العطل من السطر لا بالتخمين:
   *   «مندوبون 0» = دوال الأرقام لم تُنفَّذ، «أجهزة 0» = لا توكن حيّ.
   */
  async _preloadTargets() {
    try {
      await Promise.all([
        this._loadDrivers(),
        this._loadAdmins(),
        this._loadTokens(),
        // ★ المتاجر وأرقام أصحابها: بلا تحميل مبكر قد يصل أول طلب
        //   قبل أن نعرف صاحب متجره، فلا يصله شيء — وهو عين
        //   «وصلت الطلبية ولا أحد يعلم».
        this._loadShops(),
      ]);
    } catch {
      // لا يُفشل الإقلاع: المصادر الاحتياطية داخل كل دالة تحمينا.
    }
    this._driversAt = Date.now();
    this._adminsAt = Date.now();
    this._tokensAt = Date.now();
    this._shopsAt = Date.now();
    const ownerCount = [...this.shops.values()].filter((s) => s.owner).length;
    this.onLog(
      `أهداف الإشعار — مندوبون ${this.drivers.size} (مصدر: ${this._driversSource || 'لا شيء'}) · أدمن ${this.admins.size} · أجهزة ${this.stats.tokenPhones}/${this.stats.tokenRows} · متاجر ${this.shops.size} (أصحابها ${ownerCount})`,
    );
  }

  /**
   * ★★ نبضة فورية — «لا تنتظر دورتك، انظر الآن».
   *
   *   السبب: مهما خُفّضت مدة الاستطلاع (٢ ثانية هنا) يبقى أسوأ حال
   *   = مدة الدورة + وقت اكتشاف التغيير، فيقول صاحب الهاتف «تأخّر
   *   الطلب ثانية أو ثانيتين». لكن الجهاز الذي **كتب** التغيير يعلم
   *   بها لحظة كتابته: فيضرِب هذه النبضة على `/api/poke` فيُفحص
   *   الجدول فوراً ويُرسل FCM خلال أقل من ثانية من الضغط.
   *
   *   الاستطلاع نفسه يبقى شبكة أمان: أي تغيير لا تُسبقه نبضة
   *   (تعديل من لوحة الأدمن مثلاً) يُلتقط في الدورة التالية كعادته.
   */
  poke(reason = '') {
    if (!this.enabled) return false;
    this.stats.pokes += 1;
    // ★ نبقى بالسرعة الكاملة فترة بعد النبضة: الطلب يُكتب ثم يتغيّر
    //   حالته بعد لحظات، فلا يستيقظ الجهاز من سكون بينهما.
    this._hotUntil = Date.now() + this.hotAfterPokeMs;
    this.idleMs = this.baseIdleMs;
    this._idleStreak = 0;
    if (this.busy) {
      // دورة جارية قد تكون بدأت **قبل** الكتابة ⇒ نعيدها بعدها مباشرة
      // (مرّة واحدة، فلا تكرار لا نهائي إن تعطّلت الشبكة).
      if (!this._pokeRetry) {
        this._pokeRetry = true;
        setTimeout(() => {
          this._pokeRetry = false;
          this.poke('بعد انشغال');
        }, 900).unref?.();
      }
      return true;
    }
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this._lastWait = 0;
    this._loop();
    this.onLog(`نبضة (${reason}) — فحص فوري`);
    return true;
  }

  /** استدعاء RPC يعيد مصفوفة نصوص (أو null إن لم تكن موجودة). */
  async _rpcArray(name, params = {}) {
    try {
      const res = await fetch(`${this.url}/rest/v1/rpc/${name}`, {
        method: 'POST',
        headers: {
          apikey: this.key,
          Authorization: `Bearer ${this.key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(params),
      });
      if (!res.ok) return null;
      const rows = await res.json();
      if (!Array.isArray(rows)) return null;
      return rows.map((p) => String(p ?? '').trim()).filter(Boolean);
    } catch {
      return null;
    }
  }

  /**
   * ★ استطلاع تكيّفي بدل `setInterval` الثابت.
   *
   *   كان كل دورتين (أو ٣ لو مع الشعارات) كل ثانيتين، بلا شرط ⇒
   *   ~٤.٦ مليون استعلام/شهر حتى لو كان المشروع خاملاً تماماً.
   *
   *   الآن نهدأ تلقائياً: إن لم يتغيّر شيء، نتباعد إلى `baseIdleMs`
   *   ثم إلى `idleMaxMs` بعد ٦ دورات ساكنة (٥٠٠٠/١٠٠٠٠ مللي افتراضاً).
   *   وبمجرد أن يتغيّر طلب أو منتج، ترجع السرعة فوراً (فصل ≈ ثانيتان).
   *
   *   النتيجة العملية: الاستهلاك يتبع النشاط الفعلي، لا عدد الثواني.
   */
  _loop() {
    if (this.timer) clearTimeout(this.timer);
    // ★ المؤقّت يُجدول بـ [this._lastWait]، ثم نمسحه بعد الجدولة
    //   (قيمة لمرة واحدة) ⇒ أول دورة تنتظر ٠ وتبدأ فوراً.
    const wait = this._lastWait ?? this.pollMs;
    this._lastWait = null;
    this.timer = setTimeout(async () => {
      let changed = false;
      try {
        changed = await this.tick();
      } catch (_) {
        this._loop();
        return;
      }
      this._idleStreak = changed ? 0 : this._idleStreak + 1;
      // تهدئة تدريجية: كلما طال السكون تباعد الفحص أكثر، ومع أول
      // حدث حقيقي نرجع للسرعة الفورية (فصل ≈ ثانيتان).
      //
      // ★ وجود طلب نشط يُبقي السرعة كاملة حتى لو لم يتغيّر شيء
      //  الآن: الطلب المعلّق ينتظر قرار المندوب، والإشعار يجب أن
      //   يبقى فورياً (يقول «طلبك في الطريق» خلال ثوانٍ).
      const hot =
        changed ||
        (this.activeOrders ?? 0) > 0 ||
        Date.now() < this._hotUntil;
      if (hot) {
        this.idleMs = this.baseIdleMs;
      } else if (this._idleStreak > 6) {
        this.idleMs = this.idleMaxMs;
      }
      // ★ هذه هي القيمة التي كانت تُحسب وتُهمل: مدة الانتظار التالية.
      this._lastWait = hot ? this.pollMs : this.idleMs;
      this._loop();
    }, wait);
    this.timer.unref?.();
  }

  stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  /**
   * ★ كل جدول يُرتَّب بعمود موجود فعلاً:
   *   - orders/products فيهما `updated_at`
   *   - order_items **لا يحتوي `updated_at`** (عموده `created_at` فقط)
   *     والاستعلام كان يرمي 42703 فيسقط الاستطلاع كله بـPromise.all.
   *     لذلك نمرّر عمود الترتيب صريحاً.
   */
  async get(table, columns, limit, orderCol) {
    const n = int(limit, this.limit);
    const ord = orderCol || 'updated_at';
    const res = await fetch(
      `${this.url}/rest/v1/${table}` +
        `?select=${columns}&order=${ord}.desc,id.desc&limit=${n}`,
      {
        headers: { apikey: this.key, Authorization: `Bearer ${this.key}` },
      },
    );
    if (!res.ok) {
      const body = (await res.text()).slice(0, 200);
      // 401/403 مع anon بعد SQL_HARDEN_STAGE2 — ننبّه مرة واحدة بشدة.
      if ((res.status === 401 || res.status === 403) && this.lastStatus !== res.status) {
        this.onError(
          `Supabase ردّ ${res.status} — المفتاح الحالي لا يقرأ الجداول. ` +
            'يلزم service_role لا anon (Supabase → Settings → API).',
        );
      }
      this.lastStatus = res.status;
      throw new Error(`${table} ${res.status}: ${body}`);
    }
    this.lastStatus = 200;
    return res.json();
  }

  /**
   * ★ قياس خفيف لجدول واحد: كم صفاً فيه + ما أحدث طابع زمني.
   *
   *   العدد لا يحتاج سطراً — `Prefer: count=exact` يكتبه في ترويسة
   *   `content-range`، والردّ يبقى صفاً واحداً بالعمود وحده. هكذا
   *   تعرف البوابة الحالتين اللتين تعنيان «حدث جديد»:
   *     · العدد تغيّر ⇒ أُدرج صف أو حُذف (والحذف هو ما لا تراه
   *       النوافذ إطلاقاً، لأنه ببساطة يختفي منها).
   *     · الطابع تقدّم ⇒ عُدّل صف (حالة طلب، سعر، إيقاف منتج،
   *       إشعار كُتب). `updated_at` تتقدّم فعلاً مع كل كتابة، و
   *       مُتحقَّق من القاعدة بتاريخ ٢٠٢٦-١١-٠٦.
   */
  async _probeMark(table, stampCol) {
    const res = await fetch(
      `${this.url}/rest/v1/${table}` +
        `?select=${stampCol}&order=${stampCol}.desc&limit=1`,
      {
        headers: {
          apikey: this.key,
          Authorization: `Bearer ${this.key}`,
          Prefer: 'count=exact',
        },
      },
    );
    if (!res.ok) {
      this.lastStatus = res.status;
      throw new Error(`${table} probe ${res.status}`);
    }
    const range = String(res.headers.get('content-range') || '');
    const count = Number(range.split('/')[1]) || 0;
    const rows = await res.json();
    const stamp = rows.length ? String(rows[0][stampCol] ?? '') : '';
    this.lastStatus = 200;
    return { count, stamp };
  }

  /**
   * ★ «هل تحرّك شيء؟» — الترجع true إن وجب فتح النوافذ، و false إن
   *   اكتُفي بالقياس. أول نداء بعد الإقلاع أو بعد أي فشل يرجع true
   *   دائماً: البوابة تنحاز للإرسال، فأسوأ حالاتها جولة زائدة.
   */
  async _changed() {
    try {
      const [orders, products, items, notes] = await Promise.all([
        this._probeMark('orders', 'updated_at'),
        this._probeMark('products', 'updated_at'),
        // بنود الطلب بلا `updated_at`، و العدد + أحدث تاريخ يكفيان
        // للبند الجديد؛ تعديل سعر بند لا يُرى هنا — وهو لا يحدث إلا
        // و الطلب نشط، و عندئذٍ تُتجاوز البوابة أصلاً، و يغطّيه فوق
        // ذلك المسح الإلزامي كل `sweepMs`.
        this._probeMark('order_items', 'created_at'),
        // جسر الإشعارات العامة (أكواد، عجلة، محفظة، حجوزات): صف
        // جديد = إدراج، فالعدد و الطابع عليه كافيان بلا فتح نافذة.
        this._probeMark('notifications', 'created_at'),
      ]);
      const prev = this._marks;
      this._marks = { orders, products, items, notes };
      if (!prev) return true;
      const moved = (a, b) => (a.count === null || b.count === null
        ? a.stamp !== b.stamp
        : a.count !== b.count || a.stamp !== b.stamp);
      return (
        moved(this._marks.orders, prev.orders) ||
        moved(this._marks.products, prev.products) ||
        moved(this._marks.items, prev.items) ||
        moved(this._marks.notes, prev.notes)
      );
    } catch (err) {
      // القياس نفسه فشل ⇒ لا نثق بأي «لا تغيير» بعدها: تُمسح
      // العلامات فتبدأ المقارنة من جديد، و هذه الجولة كاملة.
      this._marks = null;
      this.onError(`بوابة الجولة: ${err.message} — فحص كامل`);
      return true;
    }
  }

  /**
   * ★ تُبنى العلامات من النافذة التي قُرئت للتو، بلا طلب إضافي.
   *
   *   الطابع جاهز: كل نافذة مرتّبة `<الطابع>.desc`، فسطرُها الأول
   *   هو أحدث طابع في الجدول كله لا في النافذة وحدها. أما العدد
   *   فيُعرف يقيناً حين لم تمتلئ النافذة فقط (صفوف أقل من الحد =
   *   نرى الجدول كله)؛ ولو امتلأت يظل `count` مجهولاً فتقارن
   *   البوابة الطابع وحده — و هي بذلك لا تفقد إشارة لم تكن النافذة
   *   نفسها تراها من قبل، لأن ما خرج من النافذة لا يُرى فيها.
   *
   *   بلا هذا البناء كانت كل جولة كاملة تُتبع بجولة كاملة أخرى
   *   «للتأسيس» — أي ضعف الفاتورة في كل حدث وكل مسح.
   *
   *   الشرط: يُزرع الطابع فقط من نافذة **تقرأ عمود الطابع**. نافذة
   *   `order_items` لا تقرأ `created_at` (ترتّب به بلا جلبه، لتبقى
   *   صفوفها أصغر)، فزرعُها كان يرجع طابعاً فارغاً في كل مرة،
   *   والمقارنة بطابع القياس الحقيقي تراه «تغيّراً» أبد الآبدين —
   *   والبوابة تصير ضريبة فوق النوافذ لا بديلاً عنها (رُصد حيّاً
   *   ٢٠٢٦-١١-٠٦: `gated:0` و`ticks` ينمو كل دورة). فبنود الطلب
   *   تبقى على سلطان قياسها، كإشعارات العامة.
   */
  _seedMarks(orders, products) {
    const mark = (rows, col, limit) => ({
      count: rows.length < limit ? rows.length : null,
      stamp: rows.length ? String(rows[0][col] ?? '') : '',
    });
    const prev = this._marks;
    this._marks = {
      orders: mark(orders, 'updated_at', this.limit),
      products: mark(products, 'updated_at', this.limit),
      // بلا عمود طابع في النافذة ⇒ سلطانه القياس وحده.
      items: prev?.items ?? { count: null, stamp: '' },
      notes: prev?.notes ?? { count: null, stamp: '' },
    };
  }


  /**
   * يقارن الصفوف ببصمتها السابقة. أول قراءة تُسجَّل فقط بلا أحداث،
   * وإلا بُثّ 60 حدثاً وهمياً عند كل إقلاع.
   */
  diff(table, rows, mapFn) {
    const prev = this.seen[table];
    const primed = prev.size > 0;
    const next = new Map();
    const changed = [];
    for (const row of rows) {
      const m = mapFn(row);
      if (!m) continue;
      next.set(m.key, m.fingerprint);
      if (!primed) continue;
      const before = prev.get(m.key);
      if (before === undefined) changed.push({ ...m, isNew: true });
      // ★ البصمة السابقة تُمرَّر مع الحدث: منها نعرف هل تغيّر
      //   `status` أم أُسند مندوب فقط (تسجيل بصمة الطلب صار
      //   يحمل `assigned_driver_phone` — تغيّر الإسناد وحده حدثٌ
      //   للمندوب، وتغيّر الحالة حدثٌ للزبون).
      else if (before !== m.fingerprint) {
        changed.push({ ...m, isNew: false, before });
      }
    }
    this.seen[table] = next;
    return changed;
  }

  /**
   * ★ أرقام المندوبين.
   *
   *   ★★ المصدر الأول دالة محميّة في القاعدة (`notify_driver_phones`)،
   *   لأن قراءة `users` بمفتاح anon صارت **ممنوعة** بعد
   *   `SQL_HARDEN_STAGE2`: كانت ترد `200 []` بلا خطأ، فتُبنى مجموعة
   *   مندوبين فارغة بصمت ⇒ صفر إشعار FCM لكل المندوبين والتطبيق مغلق
   *   (`_pushDrivers` لم يكن يجد رقماً واحداً أصلاً).
   *   قراءة `users` القديمة بقيت احتياطاً للقواعد التي لم تنفّذ الملف.
   */
  async _loadDrivers() {
    const viaRpc = await this._rpcArray('notify_driver_phones');
    if (viaRpc) {
      this.drivers = new Set(viaRpc);
      this.drivers.delete('');
      this.stats.drivers = this.drivers.size;
      this._driversSource = 'rpc';
      return;
    }
    try {
      const rows = await this.get('users', 'phone,is_driver', 500, 'id');
      const list = rows.filter((r) => r.is_driver === true).map((r) => String(r.phone || '').trim());
      // مجموعة فارغة من قراءة محجوبة لا تستبدل قائمة فيها أرقام:
      // إشعار لمندوب واحد خير من صمت كل المندوبين.
      if (list.length) {
        this.drivers = new Set(list);
        this.drivers.delete('');
        this._driversSource = 'users';
      }
      this.stats.drivers = this.drivers.size;
    } catch {
      // نُبقي القائمة القديمة: إشعار ناقص أفضل من إسكات كل المندوبين.
    }
    if (this.drivers.size) return;
    // ★★ احتياط بلا SQL: من يستلم صفوف `new_order` فهو مندوب عند
    //   القاعدة نفسها (مشغّل الطلب الجديد لا يكتبها لغير المندوبين).
    //   فالجدول يُقرأ بمفتاح anon، بعكس `users` المحجوب — فيرجع
    //   المندوبون حتى لو لم تُنفَّذ دوال الأرقام بعد.
    try {
      const since = new Date(Date.now() - 30 * 24 * 3600 * 1000)
        .toISOString()
        .replace('T', ' ')
        .slice(0, 19);
      // ★ صيغة PostgREST للـ in هي `in.(a,b)` — بلا أقواس يرفضها
      //   بـ PGRST100، والفاصلة تُشفر %2C حتى لا تُقرأ فاصلة حقول.
      const rows = await this._getQs(
        'notifications',
        `select=user_phone&type=in.%28new_order%2Cdriver_request%29&created_at=gt.${since}`,
        2000,
      );
      for (const r of rows) {
        const p = String(r.user_phone || '').trim();
        if (p) this.drivers.add(p);
      }
      this.stats.drivers = this.drivers.size;
      if (rows.length) this._driversSource = 'notifications';
    } catch {
      // كما قبل: قائمة قديمة خير من صمت.
    }
  }

  /** قراءة بمُعاملات تصفية (invoke API) — للجداول التي لا تُرتَّب وحدها. */
  async _getQs(table, query, limit) {
    const res = await fetch(
      `${this.url}/rest/v1/${table}?${query}${limit ? `&limit=${limit}` : ''}`,
      { headers: { apikey: this.key, Authorization: `Bearer ${this.key}` } },
    );
    if (!res.ok) throw new Error(`${table} ${res.status}`);
    return res.json();
  }

  /**
   * ★ أرقام الأدمن. مشغّل القاعدة يستثني الأدمن من صفوف `new_order`
   *   (`is_admin = false`)، فكان هاتف الأدمن — وهو أكثر هاتف يُختبر
   *   عليه — لا يستمع لطلب جديد إطلاقاً والتطبيق مغلق.
   */
  async _loadAdmins() {
    // ★ الدمج لا الاستبدال: أرقام الإعدادات تبقى دائماً، فتصير القائمة
    //   = أدمن الإعدادات + أدمن القاعدة.
    const viaRpc = await this._rpcArray('notify_admin_phones');
    if (viaRpc) {
      for (const p of viaRpc) this.admins.add(p);
      this.stats.admins = this.admins.size;
      return;
    }
    try {
      const rows = await this.get('users', 'phone,is_admin', 500, 'id');
      for (const r of rows) {
        if (r.is_admin === true && r.phone) this.admins.add(String(r.phone).trim());
      }
      this.stats.admins = this.admins.size;
    } catch {
      // كما في المندوبين: القائمة القديمة تبقى.
    }
  }

  /**
   * phone => [tokens]. يُحدَّث كل ٦٠ ثانية لا كل دورة.
   *
   * ★★ العطل الذي كان يُسكّت الهواتف: `is_active=false` لا يعني
   *   «الجهاز مات»، بل «هذا الجهاز انتقل لحساب آخر» (قاعدة جهاز
   *   واحد = حساب واحد داخل التطبيق). فمن بدل حساباته — أو من استعمل
   *   نفس الهاتف لحسابين — أصبح أصمّ عن إشعارات حسابه الآخر نهائياً،
   *   والتطبيق عنده مفتوح يعمل.
   *
   * ★★ تصحيح ٢٠٢٦-١٠-١٢ (طلب: «عند تسجيل الخروج لا تُرسَل إشعارات»):
   *   الدواء نفسه كان الداء: المعيار تحوّل إلى «حيوية الجهاز»
   *   (`last_seen_at` خلال ٢١ يوماً) وحده، فبقيت إشعارات من **خرج** من
   *   حسابه تنزل إلى جواله — لأن الخروج يُعطّل الصف
   *   (`deactivate_own_push_tokens`) ولا يمسّ «آخر ظهور».
   *   الآن الصف المعطَّل لا يُرسَل له إلا ببينة واحدة: **نفس التوكن
   *   حيّ (`is_active=true`) على حساب آخر في هذه الدورة** — أي أن
   *   الجهاز نفسه داخل تطبيقٍ الآن لصاحبه، وهو من استعمال حسابين على
   *   هاتف واحد. فهذه هي الحالة التي أصمّها المعيار الصارم سابقاً
   *   (ومنها هاتف الأدمن: صفّه معطَّل منذ ٢٠٢٦-١٠-٠٩)، ومن خرج ولم
   *   يرجع بحساب آخر على جهازه يسكت نهائياً.
   *   المعطَّل الذي أُسكت يُعدّ في `tokenInactive` ويظهر في
   *   `/api/health`، فلو صمت هاتف يكون السبب رقماً لا تخميناً.
   */
  async _loadTokens() {
    try {
      // ★ `platform` يبقى للوسم والتشخيص، والإرسال كله من مشروع
      //   diqarapp (٢٠٢٦-١١-٢٤): أندرويد وiOS وويب.
      const rows = await this.get(
        'push_tokens',
        'user_phone,token,is_active,last_seen_at,platform',
        2000,
        'id',
      );
      // التوكنات التي عليها حساب داخل التطبيق الآن.
      const liveTokens = new Set();
      for (const r of rows) {
        if (r.is_active === true) {
          const t = String(r.token || '').trim();
          if (t) liveTokens.add(t);
        }
      }
      const cutoff = Date.now() - this.tokenStaleMs;
      const next = new Map();
      const platforms = new Map();
      let phones = 0;
      let silent = 0;
      let web = 0;
      let ios = 0;
      for (const r of rows) {
        const phone = String(r.user_phone || '').trim();
        const token = String(r.token || '').trim();
        if (!phone || !token) continue;
        const seen = Date.parse(String(r.last_seen_at || ''));
        const fresh = Number.isFinite(seen) && seen >= cutoff;
        if (r.is_active !== true) {
          // مهجور أصلاً ⇒ لا. معطَّل وجهازه ليس داخل أي حساب الآن ⇒ من
          // خرج، فلا إشعار له. معطَّل وجهازه حيّ على حساب صاحبه ⇒ يُرسَل.
          if (!fresh || !liveTokens.has(token)) {
            silent += 1;
            continue;
          }
        }
        const list = next.get(phone) || [];
        if (!list.includes(token)) list.push(token);
        next.set(phone, list);
        const platform = String(r.platform || 'android').trim() || 'android';
        platforms.set(token, platform);
        if (platform === 'web' && r.is_active === true) web += 1;
        if (platform === 'ios' && r.is_active === true) ios += 1;
        phones += 1;
      }
      this.tokens = next;
      this.tokenPlatform = platforms;
      this.stats.tokenRows = rows.length;
      this.stats.tokenPhones = phones;
      this.stats.tokenInactive = silent;
      this.stats.tokenWeb = web;
      this.stats.tokenIos = ios;
    } catch {
      // لا بأس: نُبقي الخريطة القديمة. توكن واحد أعرج أسوأ من
      // لا توكن على الإطلاق.
    }
  }

  /**
   * ★ يُرسل إشعار FCM لجهاز صاحب الطلب — الطريق الوحيد الذي يعمل
   *   والتطبيق مغلق.
   *
   * ★ يعيد قائمة الأرقام التي **نجح** الإرسال إليها فعلاً؛ من لا
   *   توكن له أو فشل إرساله لا يدخل القائمة ⇒ يبقى صفّه بلا
   *   `pushed_at` فيعرضه التطبيق لاحقاً (لا يُسكَت أحد بلا بديل).
   *
   * ★ كل التوكنات تُرسل معاً (Promise.allSettled) وبلا تكرار:
   *   جهاز بتوكن مسجَّل مرتين كان يبعث الإشعار مرتين.
   */
  /** منصة التوكن من آخر قراءة لـ`push_tokens` (افتراضياً أندرويد). */
  _platformOf(token) {
    return this.tokenPlatform?.get(token) || 'android';
  }

  async _push(phone, title, body, data, image = '', checkRow = false) {
    if (!this.fcm?.canSend) return [];
    const key = String(phone || '').trim();
    if (!key) return [];
    // ★★ صفّه لم يعد موجوداً؟ يعني استطلاع جهازه عرضه وحذفه قبل
    //   أن تصلنا الدورة (خصوصاً بعد سكون طويل) — إرسال FCM الآن
    //   يُظهر إشعاراً ثانياً لمن رآه بالفعل: صوت مكرّر.
    if (checkRow) {
      const live = await this._rowsLive(data?.orderId, data?.type, [key]);
      if (live && !live.includes(key)) return [];
    }
    if (!this.tokens || Date.now() - (this._tokensAt || 0) > 60000) {
      this._tokensAt = Date.now();
      await this._loadTokens();
    }
    const list = [...new Set(this.tokens?.get(key) || [])];
    if (!list.length) {
      // ★ سجل صريح: كان الصمت هنا يُخفي عطلاً كاملاً (توكن معطّل أو
      //   لم يُسجَّل بعد) فلا يُعرف لماذا «لا تأتي الإشعارات».
      this.onLog(`FCM — لا جهاز مسجّل لـ ${key} (${data?.type ?? ''})`);
      return [];
    }
    const results = await Promise.allSettled(
      list.map((token) =>
        this.fcm.send(token, { title, body, data, image }, {
          platform: this._platformOf(token),
        }),
      ),
    );
    const ok = results.some((r) => r.status === 'fulfilled' && r.value === true);
    this.onLog(`FCM ${ok ? '✓' : '✗'} ${key} — ${data?.type ?? ''} (${list.length} جهاز)`);
    return ok ? [key] : [];
  }

  /**
   * ★ إرسال إلى **كل** المندوبين + الأدمن دفعة واحدة — طلب جديد.
   *
   * ★ نفس سرعة إشعار الزبون: كان طلب المندوب الحرّ فقط يصل FCM،
   *   أما الطلبات العادية فيراها المندوب بالاستطلاع وحده — أي
   *   تتأخّر دقيقة كاملة والتطبيق مغلق. الآن الاثنان يمرّان هنا.
   *
   * ★ يعيد أرقام من نجح الإرسال إليهم (توكن مشترك بين حسابين
   *   يُرسل مرّة واحدة فلا يصل الإشعار مرتين).
   */
  async _pushDrivers(title, body, data, image = '', exceptPhone = '') {
    if (!this.fcm?.canSend) return [];
    if (!this.drivers || Date.now() - (this._driversAt || 0) > 60000) {
      this._driversAt = Date.now();
      await this._loadDrivers();
    }
    if (!this.admins || Date.now() - (this._adminsAt || 0) > 60000) {
      this._adminsAt = Date.now();
      await this._loadAdmins();
    }
    if (!this.tokens || Date.now() - (this._tokensAt || 0) > 60000) {
      this._tokensAt = Date.now();
      await this._loadTokens();
    }
    const ex = String(exceptPhone).trim();
    // ★★ تصفية بصفوف القاعدة قبل الإرسال: من حُذف صفّه (عرضه جهازه
    //   بصمت أو محلياً) لا يُرسل له FCM ثانياً — وإلا وصله إشعار
    //   مكرّر بصوت ثانٍ بعد أن رآه.
    //   لل مندوبين وحدهم: مشغّل القاعدة لا يكتب صفاً للأدمن، فلو
    //   استعملنا القائمة نفسها معهم لما وصل الأدمن إشعار قط.
    const live = await this._rowsLive(data?.orderId, data?.type, null);
    const liveSet = live ? new Set(live) : null;
    const seenToken = new Set();
    const jobs = [];
    const targets = [
      ...[...(this.drivers || [])].map((p) => ({ phone: p, gated: true })),
      ...[...(this.admins || [])].map((p) => ({ phone: p, gated: false })),
    ];
    for (const { phone, gated } of targets) {
      if (!phone || phone === ex) continue;
      if (gated && liveSet && !liveSet.has(phone)) continue;
      for (const token of this.tokens?.get(phone) || []) {
        if (!token || seenToken.has(token)) continue;
        seenToken.add(token);
        jobs.push({ phone, token });
      }
    }
    if (!jobs.length) {
      this.onLog(
        `FCM مندوبين — صفر أجهزة: مندوبون ${this.drivers?.size ?? 0}، ` +
          `أدمن ${this.admins?.size ?? 0}، أرقام لها أجهزة ${this.tokens?.size ?? 0} ` +
          `(${data?.type ?? ''})`,
      );
      return [];
    }
    const results = await Promise.allSettled(
      jobs.map((j) =>
        this.fcm.send(j.token, { title, body, data, image }, {
          platform: this._platformOf(j.token),
        }),
      ),
    );
    const ok = new Set();
    results.forEach((r, i) => {
      if (r.status === 'fulfilled' && r.value === true) ok.add(jobs[i].phone);
    });
    return [...ok];
  }

  /**
   * ★ يضع علامة `pushed_at` على صفوف الإشعار التي أرسلها FCM فعلاً.
   *
   *   الكتابة المباشرة ممنوعة (RLS): أُعلن الصف لكن PATCH من الخارج
   *   يعيد `[]` بلا تعديل. الدالة محميّة (security definer) وتقصّ
   *   العلامة على هذا الطلب وهذا النوع **والهواتف التي وصلها
   *   الإرسال فقط** ⇒ لا يُسكَت حساب لم يستلم شيئاً.
   *
   *   لماذا العلامة أصلاً؟ بلا علامة يرى التطبيق الصف في استطلاعه
   *   ويعرض الإشعار ثانية (صوت مكرّر) بعد أن عرضه النظام من FCM —
   *   وهذا بالضبط عيب «الإشعار مرتين».
   */
  async _markPushed(orderId, type, phones = null) {
    const oid = String(orderId || '').trim();
    const t = String(type || '').trim();
    if (!oid || !t) return 0;
    try {
      const res = await fetch(`${this.url}/rest/v1/rpc/mark_notification_pushed`, {
        method: 'POST',
        headers: {
          apikey: this.key,
          Authorization: `Bearer ${this.key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          p_order_id: oid,
          p_type: t,
          p_phones: Array.isArray(phones) && phones.length ? phones : null,
        }),
      });
      if (!res.ok) return 0;
      return Number(await res.json()) || 0;
    } catch {
      return 0;
    }
  }

  /**
   * ★★ أي الهواتف لا يزال صفّها **موجوداً** في `notifications`؟
   *
   *   تُستدعى قبل إرسال FCM: إن كان الصف قد حُذف (عرضه التطبيق
   *   وستهلكه — مثلاً بعد سكون طويل تأخّرت فيه دورتنا) فلا معنى
   *   لإرسال FCM الآن؛ إرساله يعني إشعاراً ثانياً بصوت ثانٍ لمن
   *   رآه بالفعل.
   *
   *   تُرجع مصفوفة أرقام الصفوف الحيّة، أو null إن تعذّر الفحص
   *   (شبكة/صلاحية/دالة غير منشورة) ⇒ عندها لا نُصفّي شيئاً:
   *   إشعار زائد أهون من إشعار ضائع.
   */
  async _rowsLive(orderId, type, phones = null) {
    const oid = String(orderId || '').trim();
    const t = String(type || '').trim();
    if (!oid || !t) return null;
    try {
      const res = await fetch(`${this.url}/rest/v1/rpc/notification_rows_live`, {
        method: 'POST',
        headers: {
          apikey: this.key,
          Authorization: `Bearer ${this.key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          p_order_id: oid,
          p_type: t,
          p_phones: Array.isArray(phones) && phones.length ? phones : null,
        }),
      });
      if (!res.ok) return null;
      const rows = await res.json();
      return Array.isArray(rows) ? rows.map((p) => String(p)) : null;
    } catch {
      return null;
    }
  }

  /**
   * ★★ تنظيف صفحة «التنبيهات والإشعارات» — كل ٥ دقائق (طلب ٢٠٢٦-١١-٠٦،
   *    وعُدّل ٢٠٢٦-١١-٢٠).
   *
   *   قاعدتان الآن، كلتاهما عبر دوال محميّة في القاعدة (لا حذف مباشر):
   *
   *   ١) `purge_completed_rejected_notifications(24)` — إشعارات الطلبات
   *      **المكتملة (delivered) والمرفوضة (rejected) فقط** تبقى ٢٤ ساعة
   *      ثم تُحذف. بقية الأنواع لا تُمسّ.
   *   ٢) `purge_queue_notifications(5)` — نظافة الطابور القديمة كما كانت:
   *      صفوف أقدم من مهلة التسليم، **فيما عدا** صفوف المكتمل/المرفوض
   *      (تلك لها مهلة ٢٤ ساعة أعلاه).
   *
   *   · الجدول `notifications` وحده يُحذف منه؛ `orders` تُقرأ للفحص فقط
   *     داخل الدالة (وجود الطلب + حالته)، ولا صفّ طلب يُلمس.
   *   · إن لم تُشغَّل SQL_NOTIFICATIONS_24H_CLEANUP.sql بعد، تردّ الدالة
   *     404 فلا يُحذف شيء — أفضل من حذف أوسع من المطلوب.
   */
  async _purgeNotifications() {
    const rpc = async (fn, body) => {
      const res = await fetch(`${this.url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          apikey: this.key,
          Authorization: `Bearer ${this.key}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      });
      const text = await res.text().catch(() => '');
      if (!res.ok) throw new Error(`${fn} → ${res.status}`);
      return Number(text) || 0;
    };
    try {
      const done = await rpc('purge_completed_rejected_notifications', {
        p_hours: 24,
      });
      const minutes = Math.max(1, Math.round(this.purgeMs / 60000));
      const queue = await rpc('purge_queue_notifications', {
        p_minutes: minutes,
      });
      this.lastStatus = 200;
      this.stats.purgeRuns += 1;
      this.stats.purgedRows += done + queue;
      if (done + queue > 0) {
        this.onLog(
          `تنظيف الإشعارات: حُذف ${done} إشعار مكتمل/مرفوض أقدم من ٢٤ ساعة، ` +
            `و${queue} صفّاً من بقية الطابور`,
        );
      }
      return done + queue;
    } catch (err) {
      this.onError(`تنظيف الإشعارات: ${err.message}`);
      return 0;
    }
  }

  // =====================================================================
  //  ★★ جسر «كل شيء يخص التطبيق» — طلب ٢٠٢٦-١١-٠٢
  // =====================================================================

  /**
   * الأنواع التي تتكفّل بها مسارات الطلبات أعلاه (تقرأ `orders` و
   * `product_items` مباشرة وتحسب بنفسها من يستحق الإشعار: صاحب
   * المتجر، المندوب المسؤول، الزبون، الأدمن). لا نرسلها من هنا
   * وإلا دقّ الهاتف مرتين لحدث واحد.
   *
   * ★ الاستثناء مشروط بـ`order_id` لا بالنوع وحده: الاسم وحده قد
   *   يكون مُعاداً لحدث ليس طلباً (حجز الدكتور يُسمّى
   *   `driver_request` بجدوله الخاص)، فصفٌّ بلا معرّف طلب لا يراه
   *   مسار الطلبات إطلاقاً ومنه يمرّ إلى هذا الجسر.
   */
  static ORDER_TYPES = new Set([
    'order_created', 'new_order', 'driver_request', 'pending',
    'accepted', 'delivering', 'delivered', 'rejected', 'cancelled',
    'reopened', 'item_changed', 'item_replaced', 'item_deleted',
  ]);

  /**
   * ★ كل صفّ إشعار تكتبه القاعدة **لغير الطلبات** — أكواد الخصم،
   *   عجلة الحظ، المحفظة، إعلانات الأدمن، حجوزات الدكتور، حالة
   *   المتجر… — كان يُعرض داخل التطبيق المفتوح وحده (استطلاعه كل
   *   ثانيتين)، فلا يهتزّ هاتفٌ وهو مقفول. هذه الحلقة تحوّله إلى
   *   رسالة FCM كاملة (`notification` + قناة بنغمتها) فيعرضه نظام
   *   التشغيل بلا أي تشغيل منّا في الخلفية.
   *
   *   القراءة من دالة محميّة (`get_unpushed_notifications`) لأن
   *   مفتاح الخادم لا يرى صفوف غيره بعد التقوية، والوسم بدالة
   *   محميّة ثانية (`mark_notifications_pushed_by_id`) على **معرّف
   *   الصف** لا على (الطلب + النوع): أدقّ، ولا يَسِم صفّاً لم يصل.
   *
   *   ★ بلا الدالتين لا نفعل شيئاً: `_unpushedRows` تُعيد null عند 404
   *     فنخرج صامتين. إرسال بلا وسم يعني بطاقة داخل التطبيق فوق
   *     إشعار النظام — وهو عطل «التكرار» المعروف، فالاثنان معاً أو
   *     لا شيء.
   *
   *   لا نكتب في الجدول غير الوسم، ولا نحذف صفّاً: التطبيق يستهلك
   *   صفّه وحده كعادته.
   */
  async _pushNotificationRows() {
    if (!this.fcm?.canSend || this._notifyDisabled) return;
    // أول دورة بعد الإقلاع: نضع علامة البداية عند «الآن» ناقص النافذة
    // ولا ننبّه على ما كُتب قبل أن نكون هنا (التطبيق يعرضه باستطلاعه).
    // بلا هذا السطر يكون `p_after` نصّاً فارغاً ⇒ خطأ توقيت 400 ⇒
    // يُحسب «دالة غير موجودة» ويُطفأ الجسر بعد ثلاث دورات.
    if (!this._notifyAfter) {
      const boot = new Date(Date.now() - this.notifyLookbackMs);
      this._notifyAfter = boot.toISOString();
      this.onLog(
        `جسر الإشعارات العامة يعمل — نافذة ${this.notifyLookbackMs / 1000}ث من ${this._notifyAfter}`,
      );
      return;
    }
    const rows = await this._unpushedRows(this._notifyAfter);
    if (rows === null) {
      // الدالة غير منشورة بعد ⇒ نتوقف بعد ثلاث محاولات متتالية، لا
      // كل دورة: نداء 404 كل ثانيتين حملٌ بلا فائدة.
      this.stats.notifyUnavailable += 1;
      this._notifyFails += 1;
      if (this._notifyFails >= 3) {
        this._notifyDisabled = true;
        this.onLog(
          '★ جسر الإشعارات العامة أُطفئ: الدالتان غير منفّذتين — شغّل SQL_PUSH_ALL_EVENTS.sql ثم أعد تشغيل notify.service',
        );
      }
      return;
    }
    this._notifyFails = 0;
    if (!rows.length) return;
    const sentIds = [];
    for (const r of rows) {
      const created = String(r.created_at || '');
      if (created > this._notifyAfter) this._notifyAfter = created;
      const type = String(r.type || '').trim();
      const phone = String(r.user_phone || '').trim();
      const title = String(r.title || '').trim();
      if (!phone || !title) continue;
      const orderId = String(r.order_id || '').trim();
      // نوع طلب **ولهُ** معرّف طلب ⇒ مساره الأصلي في الخادم يَدقّه،
      // فلا نزيده عليه (وإلا دقّ الهاتف مرتين لحدث واحد).
      // ★ بلا معرّف ليس حدث طلب: حجز الدكتور يُسمّى `driver_request`
      //   و`order_id` عنده مجرّد — لا حلقة أخرى تراه، فاستثناءُه كان
      //   يترك الحجز بلا رنين والهاتف مقفول.
      if (orderId && SupabaseWatcher.ORDER_TYPES.has(type)) continue;
      // ★ لا إعلان عام هنا: صفّ بـ`user_phone = '*'` موجّه لصندوق
      //   الوارد عند كل حساب، لا رسالة هاتف معيّن. كان بثّ عام كهذا
      //   من `product.deleted` يُسمع كل زبون نغمة لموضوع لا يخصّه،
      //   وحُذف ذلك البثّ من قبل بقصد — فلا نعيده من باب آخر.
      //   الدالة نفسها تستثني هذه الصفوف؛ هذا الحرس الثاني لا ثالث
      //   له لو تبدّل نصّ الدالة على السيرفر.
      if (r.is_global === true || phone === '*') continue;
      const data = {
        rowId: String(r.id || ''),
        orderId,
        type: type || 'alert',
        sound: String(r.sound || '') || type || 'alert',
        serial: '',
        link: String(r.link_url || ''),
      };
      const ok = await this._push(
        phone,
        title,
        String(r.body || ''),
        data,
        String(r.image_url || ''),
      );
      if (!ok.length) continue;
      this.stats.notifyPushed += 1;
      sentIds.push(String(r.id));
    }
    if (sentIds.length) {
      const marked = await this._markRowsPushed(sentIds);
      this.stats.notifyMarked += marked;
    }
  }

  /**
   * صفوف إشعار جديدة لم تُدفَق خارج التطبيق.
   * تُعيد null إذا كانت الدالة غير موجودة/مرفوضة (وليس فارغة).
   */
  async _unpushedRows(afterIso) {
    try {
      const res = await fetch(
        `${this.url}/rest/v1/rpc/get_unpushed_notifications`,
        {
          method: 'POST',
          headers: {
            apikey: this.key,
            Authorization: `Bearer ${this.key}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_after: afterIso, p_limit: 40 }),
        },
      );
      if (!res.ok) return null;
      const rows = await res.json();
      return Array.isArray(rows) ? rows : null;
    } catch {
      return null;
    }
  }

  /** وسم الصفوف التي نجح الإرسال إليها فعلاً. يعيد عدد الموسوم. */
  async _markRowsPushed(ids) {
    try {
      const res = await fetch(
        `${this.url}/rest/v1/rpc/mark_notifications_pushed_by_id`,
        {
          method: 'POST',
          headers: {
            apikey: this.key,
            Authorization: `Bearer ${this.key}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ p_ids: ids }),
        },
      );
      if (!res.ok) return 0;
      return Number(await res.json()) || 0;
    } catch {
      return 0;
    }
  }

  /** يخزّن شعار كل متجر ظهر معنا — لازم عند حذف صنف من طلب. */
  _shopsFrom(products) {
    // ★ لم يعد له دور: الشعارات تأتي من shops لا products.
    //   نبقيه فارغاً عمداً حتى لا نخلط صورة المنتج بالشعار.
    void products;
  }

  /**
   * كشف حذف/إنقاص صنف من طلب موجود.
   *
   * ★ نقارن البصمة لكل صنف. صنف كان موجوداً ثم اختفى = حُذف.
   *   صنف بقي لكن كميته ناقصة = إنقاص.
   *
   * ★ الحارس نفسه: لا نصدّق الغياب إلا حين تكون النافذة غير ممتلئة،
   *   وإلا صنف قديم خارج آخر 300 سيبدو محذوفاً.
   *
   * ★ الإشعار يذهب لصاحب الطلب (SSE + FCM) وللمندوب المسؤول
   *   (FCM) — ومعه شعار المتجر في حدث SSE، لا في FCM.
   */
  async _watchOrderItems(items, orders) {
    // ★ الرقم والمندوب المسؤول والرقم التسلسلي لكل طلب — مصدر
    //   إشعار FCM عند تغيّر بنود الطلب.
    const infoOf = new Map(
      orders.map((o) => [
        o.id,
        {
          phone: o.user_phone,
          driver: String(o.assigned_driver_phone ?? '').trim(),
          serial: o.serial_number != null ? `#${o.serial_number}` : '',
        },
      ]),
    );
    // ★ البصمة تحمل السعر والكمية والإجمالي: نقارنها حقلاً
    //   بحقل، فنعرف هل تغيّر السعر أم الكمية فقط.
    const fp = (it) =>
      `${it.quantity}|${it.price}|${it.total}|${it.product_name}`;

    const next = new Map();
    for (const it of items) {
      next.set(it.id, { f: fp(it), row: it });
    }

    const removed = [];
    for (const [id, prev] of this.seen.items) {
      const now = next.get(id);
      if (now) {
        const [oq, op, , on] = String(prev.f).split('|');
        const [nq, np] = String(now.f).split('|');
        const oldQty = Number(oq ?? 0) || 0;
        const newQty = Number(nq ?? 0) || 0;
        const oldPrice = Number(op ?? 0) || 0;
        const newPrice = Number(np ?? 0) || 0;

        // ★ الأولوية للسعر: المندوب يغيّر السعر بنفسه.
        //   نعتبره «تغيير سعر» إن تغيّر السعر، أو إن نقصت الكمية
        //   وسعر الوحدة اختلّ (وإلا فالنقص كان كمية مجرّدة).
        if (newPrice !== oldPrice) {
          removed.push({
            kind: 'price_changed',
            it: now.row,
            from: oldPrice,
            to: newPrice,
            name: on,
          });
        } else if (newQty < oldQty) {
          removed.push({
            kind: 'reduced',
            it: now.row,
            from: oldQty,
            to: newQty,
            name: on,
          });
        }
        continue;
      }
      removed.push({ kind: 'removed', it: prev.row });
    }
    this.seen.items = next;

    // ★ الحارس بعد الحساب لا قبله: نجمع أولاً ثم نتأكد أن النافذة
    //   غير ممتلئة قبل البث. (وضعه قبل الجمع كان يبتلع كل شيء.)
    if (items.length >= 300) return;
    // ★ تشخيص: صنف اختفى لكن طلبه خارج نافذة الطلبات ⇒ infoOf
    //   لا يعرف الرقم، فنجهل صاحب الطلب. سجّلها بدل ابتلاعها.
    for (const r of removed) {
      if (infoOf.has(r.it.order_id)) continue;
      this.stats.droppedNoPhone = (this.stats.droppedNoPhone ?? 0) + 1;
    }

    for (const r of removed) {
      const info = infoOf.get(r.it.order_id);
      const phone = info?.phone;
      if (!phone) continue;
      const shop = this.shops.get(r.it.shop_id) ?? { name: '', image: '' };
      this.stats.itemEvents += 1;
      publish(
        EV.ORDER_ITEM_REMOVED,
        {
          orderId: r.it.order_id,
          itemId: r.it.id,
          productName: r.it.product_name ?? r.name ?? '',
          kind: r.kind,
          from: r.from ?? null,
          to: r.to ?? null,
          shopName: r.it.shop_name ?? shop.name ?? '',
          shopImage: shop.image ?? '',
          at: Date.now(),
        },
        { phones: [phone], roles: ['admin'] },
      );

      // ★★ الإشعار الحقيقي (FCM): كان تغيير البنود يصل الزبون
      //   «المفتوح» وحده عبر SSE؛ مغلقاً لا يصل شيء إطلاقاً.
      // ★ نوع الصف واحد `item_changed` لكل أنواع البنود (لا عمود
      //   item_id في الجدول) والنغمة تفرّق: سعر مستقل عن استبدال.
      const name = r.it.product_name ?? r.name ?? 'منتج';
      const shopName = String(r.it.shop_name ?? shop.name ?? '').trim();
      let title;
      let body;
      let snd;
      if (r.kind === 'price_changed') {
        snd = 'price_changed';
        title = shopName ? `تغيّر سعر — ${shopName}` : 'تغيّر سعر في طلبك';
        body = `عُدّل سعر «${name}» من ${r.from} إلى ${r.to}.`;
      } else if (r.kind === 'reduced') {
        snd = 'replaced';
        title = 'تحديث طلبك';
        body = `عُدّلت كمية «${name}» إلى ${r.to}.`;
      } else {
        snd = 'replaced';
        title = 'تحديث طلبك';
        body = `أُزيل «${name}» من طلبك.`;
      }
      const data = {
        orderId: String(r.it.order_id || ''),
        status: 'item_changed',
        type: 'item_changed',
        sound: snd,
        serial: info.serial,
        itemId: String(r.it.id || ''),
      };
      // ★★ صفّ `item_changed` للزبون — نفحص وجوده قبل FCM: إن
      //   كان استطلاعه عرضه وحذفه فلا نرسل نسخة ثانية بصوت ثانٍ.
      const okPhones = await this._push(phone, title, body, data, '', true);
      if (okPhones.length) {
        await this._markPushed(r.it.order_id, 'item_changed', okPhones);
      }
      // ★ المندوب المسؤول: البنود تغيّرت في يده — يعلم فوراً وإن
      //   كان التطبيق مغلقاً. بلا علامة: لا صفّ `item_changed`
      //   مكتوب له (صفوف البنود للزبون وحده).
      if (info.driver && info.driver !== phone) {
        await this._push(info.driver, title, body, data, '');
      }
    }
  }

  /**
   * يخزّن شعار **المتجر** لا صورة المنتج.
   *
   * ★ `products.image_path` صورة المنتج، لا شعار المتجر. أخطأ أولاً
   *  توحيد صورة الشعار: صورة المنتج كانت تختلط به، فأعطت صورة
   *   الشعار من `shops.image_path` — لذلك نطلب المتاجر صراحةً.
   */
  async _loadShops() {
    try {
      const rows = await this.get(
        'shops',
        'id,name,image_path,owner_phone',
        200,
        'id',
      );
      const next = new Map();
      for (const s of rows) {
        next.set(s.id, {
          name: s.name ?? '',
          image: (s.image_path ?? '').trim(),
          // ★ هاتف صاحب المتجر: قناة الإشعار الحقيقية عند طلب جديد.
          owner: String(s.owner_phone ?? '').trim(),
        });
      }
      this.shops = next;
    } catch {
      // لا بأس: نُبقي الخريطة القديمة بدل فقدان كل الشعارات والأرقام.
    }
  }

  /**
   * ★★ أصحاب **متاجر هذا الطلب وحده** — لا صاحب أي متجر آخر.
   *
   *   الطلب الواحد قد يجمع أصنافاً من أكثر من متجر (السلة تجمع من
   *   عدّة متاجر)، فنجمع لكل متجر صاحبه، ونجمع أسماء المتاجر لمن كان
   *   صاحب متجرين في نفس الطلب (إشعار واحد لا اثنان).
   *
   *   تُرجع Map: phone => اسم المتجر (أو أسماءه مفصولة بفاصلة).
   */
  _ownersOfOrder(orderId, shopIdsByOrder, customerPhone) {
    const out = new Map();
    const ids = shopIdsByOrder?.get(orderId);
    if (!ids || !ids.size) return out;
    const buyer = String(customerPhone || '').trim();
    for (const sid of ids) {
      const shop = this.shops.get(sid);
      const phone = String(shop?.owner || '').trim();
      if (!phone || phone === buyer) continue;
      const name = String(shop?.name || '').trim();
      const prev = out.get(phone);
      if (prev === undefined) out.set(phone, name);
      else if (name && prev !== name && !prev.split('، ').includes(name)) {
        out.set(phone, prev ? `${prev}، ${name}` : name);
      }
    }
    return out;
  }

  /**
   * ★★ إشعار أصحاب المتاجر بعد أن تُعرف بنود الطلب.
   *
   *   الطلب يُكتب أولاً ثم تُكتب بنوده، فقد يمرّ بينهما دورتان: هنا
   *   نُبقيه معلّقاً حتى تظهر بنوده، ثم نرسل مرّة واحدة فقط.
   *   الجهة: **صاحب متجر الطلب وحده** (من `shops.owner_phone`) —
   *   لا صاحب أي متجر آخر؛ يُرسل SSE لهاتفه المفتوح (تحديث بلا
   *   صفحة) وFCM خارجياً (والتطبيق مغلق).
   */
  async _notifyShopOwners(shopIdsByOrder) {
    if (!this.pendingOwners.size) return;
    const now = Date.now();
    for (const [orderId, info] of [...this.pendingOwners]) {
      const owners = this._ownersOfOrder(orderId, shopIdsByOrder, info.phone);
      if (!owners.size) {
        // ★ ٩٠ ثانية سقف الانتظار: بنودٌ لم تُكتب أصلاً = طلب
        //   فاشل حُذف، فلا معنى لإبقاء صفّه في الذاكرة.
        if (now - info.at > 90000) {
          this.pendingOwners.delete(orderId);
          // ★ سطر صريح بدل الصمت: متجر بلا `owner_phone` لا يمكن
          //   إشعار صاحبه — يُعرف السبب من السجل لا بالتخمين.
          const ids = shopIdsByOrder.get(orderId);
          if (ids && ids.size) {
            this.onLog(
              `صاحب متجر الطلب ${info.serial || orderId} غير معروف (لا owner_phone) — بلا إشعار`,
            );
          }
        }
        continue;
      }
      this.pendingOwners.delete(orderId);

      // ★ هاتف التاجر المفتوح: حدث بلا أدوار ⇒ أصحاب هذا الطلب
      //   وحدهم. صفحة «طلباتي» عنده تعرض التنبيه وتُحدّث نفسها.
      publish(
        EV.ORDER_NEW,
        {
          id: orderId,
          serial: info.serial,
          status: 'new_order',
          shopOwner: true,
          at: now,
        },
        { phones: [...owners.keys()] },
      );

      for (const [phone, shopName] of owners) {
        if (!phone || phone === info.phone) continue;
        if (info.driverPushed && info.driverPushed.has(phone)) continue;
        const label = shopName || 'متجرك';
        // ★ طلب وصفة: لا تُجهَّز قبل اعتماد الوصفة — النص يقولها.
        const title = info.review
          ? (info.serial ? `طلب وصفة جديد ${info.serial}` : 'طلب وصفة جديد')
          : (info.serial ? `طلب جديد ${info.serial}` : 'طلب جديد');
        const body = info.review
          ? `${label}: وصلتك طلبية بوصفة — راجع الوصفة واعتمد الطلب`
          : `${label}: وصلتك طلبية جديدة — جهّزها الآن`;
        const okOwner = await this._push(
          phone,
          title,
          body,
          {
            orderId,
            status: info.review ? 'pharmacy_review' : 'new_order',
            type: 'new_order',
            sound: 'new_order',
            serial: info.serial,
            forShop: 'true',
          },
        );
        if (okOwner.length) this.stats.ownerPushes = (this.stats.ownerPushes ?? 0) + 1;
      }
    }
  }

  /**
   * دورة واحدة. **يُرجع true** إن تغيّر شيء فعلاً (وهذا يقرّر سرعة
   * الدورة التالية — راجع [_loop]).
   */
  async tick() {
    if (this.busy || !this.enabled) return false;
    this.busy = true;
    // عدّاد قبل الدورة ⇒ نقارن بعدها لنعرف إن حدث تغيير.
    const before =
      this.stats.orderEvents +
      this.stats.productEvents +
      this.stats.itemEvents +
      this.stats.deletedEvents;
    try {
      // ★★ التنظيف الدوري لصفحة «التنبيهات والإشعارات» (كل purgeMs):
      //   قبل البوابة عمداً — الجولة المكتفية بالقياس تعود مبكراً،
      //   ولو جاء التنظيف بعدها لتوقّف طوال فترات السكون الطويلة
      //   والخادم يعمل. أول دورة تنظّف فوراً صفوف ما قبل الإقلاع.
      if (Date.now() - this._purgeAt >= this.purgeMs) {
        this._purgeAt = Date.now();
        await this._purgeNotifications();
      }
      // ★ البوابة أولاً (٢٠٢٦-١١-٠٦): إن لم يتحرّك شيء في القاعدة
      //   ولا يوجد طلب نشط ولا حان المسح، تُدفَع ٤٫٢٩ كيلوبايت
      //   قياساً بدل ١٣٫١٣ كيلوبايت نوافذ. لا يُستثنى من هذا إلا ما
      //   يجب أن يبقى فورياً — راجع `sweepMs` في الباني.
      const sweepDue = Date.now() - this._sweepAt >= this.sweepMs;
      const hot = (this.activeOrders ?? 0) > 0;
      if (!sweepDue && !hot) {
        if (!(await this._changed())) {
          this.stats.gated += 1;
          return false;
        }
      } else {
        // النافذة الكاملة لا تُبنى عليها العلامات من القياس (لم يُقَس)،
        // بل تُبنى من صفوفها نفسها بعد قراءتها — راجع [_seedMarks].
        // أما الإشعارات العامة فتبقى علامتها من آخر قياس؛ و إن لم
        // يُقَس منها شيء بعدُ فالتأسيس يرجع true و تُفتح جولة أخرى
        // مرة واحدة فقط عند الإقلاع.
        this.stats.fullRounds += 1;
      }
      this._sweepAt = Date.now();

      const [orders, products, items] = await Promise.all([
        this.get(
          'orders',
          'id,serial_number,status,user_phone,is_free_driver_request,address,assigned_driver_phone,prescription_path,created_at,updated_at',
        ),
        this.get('products', 'id,name,price,old_price,is_active,shop_id,image_path,created_at,updated_at'),
        this.get('order_items', 'id,order_id,product_name,shop_name,shop_id,quantity,price,total', 300, 'created_at'),
      ]);
      // ★ تُبنى علامات البوابة من صفوف الطلبات و المنتجات نفسها، فلا
      //   يلي الجولة كاملة قياسُ تأسيسٍ يهدر جولة أخرى ورائها.
      this._seedMarks(orders, products);

      // ★ خريطة الطلب ⇒ متجره كانت تُبنى هنا لبثّ الشعار — أُزيلت:
      //   FCM لا يحمل أي صورة (شعار كل حساب يعرضه التطبيق من نفسه).
      //
      // ★ لكن بقي منها ما نحتاجه: **أي متاجر في هذا الطلب؟** — بها
      //   نعرف أصحابها فنرسل لهم وحدهم إشعار الطلب الجديد.
      const shopIdsByOrder = new Map();
      for (const it of items) {
        const oid = it.order_id;
        const sid = it.shop_id;
        if (!oid || !sid) continue;
        let set = shopIdsByOrder.get(oid);
        if (!set) {
          set = new Set();
          shopIdsByOrder.set(oid, set);
        }
        set.add(sid);
      }

      for (const o of this.diff('orders', orders, (x) => ({
        key: x.id,
        // ★ `assigned_driver_phone` داخل البصمة: إسناد مندوب بلا
        //   تغيّر حالة كان لا يُكتشف إطلاقاً ⇒ مندوب لا يعلم أن
        //   الطلب أُسند إليه حتى يفتح التطبيق بنفسه.
        fingerprint: `${x.updated_at}|${x.status}|${x.assigned_driver_phone ?? ''}`,
        data: {
          id: x.id,
          // ★ الرقم الظاهر للبشر (`serial_number`) لا المعرّف
          //   الداخلي: هو ما يُقرأ في شريط الإشعارات.
          serial: x.serial_number != null ? `#${x.serial_number}` : '',
          status: x.status,
          isDriverRequest: x.is_free_driver_request === true,
          address: x.address ?? '',
          driverPhone: String(x.assigned_driver_phone ?? '').trim(),
          hasPrescription: String(x.prescription_path ?? '').trim() !== '',
          at: x.updated_at,
        },
        phone: x.user_phone,
      }))) {
        this.stats.orderEvents += 1;
        publish(o.isNew ? EV.ORDER_NEW : EV.ORDER_STATUS, o.data, {
          phones: [o.phone],
          roles: ['driver', 'admin'],
        });

        // ★★ صاحب المتجر: الطلب يُقيد **قبل** بنوده (نداءان
        //   منفصلان من التطبيق)، فقد نرى الطلب في دورةٍ وبنوده في
        //   التالية ⇒ لا نجزم بالمتاجر هنا. نُعلّقه ونحسمه في نهاية
        //   نفس الدورة إن كانت البنود وصلت، وإلا في الدورة التالية
        //   (مرّة واحدة فقط: يُزال من القائمة بعد الإرسال).
        if (o.isNew && !o.data.isDriverRequest) {
          this.pendingOwners.set(o.data.id, {
            serial: o.data.serial || '',
            phone: o.phone,
            at: Date.now(),
            driverPushed: new Set(),
            // ★ طلب وصفة بانتظار اعتماد الصيدلية: لإشعار صاحبها
            //   بصيغة «راجع الوصفة» لا «جهّزها الآن».
            review: String(o.data.status || '') === 'pharmacy_review',
          });
        }

        // ★★ الإشعار الحقيقي للتطبيق المغلق: بثّ SSE أعلاه يذهب
        //   للسائق والأدمن فقط، فلا يصل الزبون إطلاقاً. كل ما
        //   كان يظهر للزبون كان استطلاعاً من داخل التطبيق — أي
        //   يختفي بإغلاقه. هنا نرسل FCM إلى جهازه.
        //
        // ★★ ما تغيّر فعلاً: البصمة السابقة تفصل «تغيّر الحالة»
        //   عن «أُسند مندوب». للزبون نُشعر عند تغيّر الحالة فقط؛
        //   إسناد مندوب ليس خبراً للزبون بل للمندوب نفسه.
        const st = String(o.data.status || '');
        const prev = String(o.before || '').split('|');
        const prevStatus = o.isNew ? '' : prev[1] || '';
        const prevDriver = o.isNew ? '' : prev[2] || '';
        const nowDriver = o.data.driverPhone || '';
        const statusChanged = o.isNew || prevStatus !== st;
        // ★★ موافقة الصيدلية على طلب وصفة: الحالة انتقلت
        //   pharmacy_review ← pending. هذه هي اللحظة التي يصبح فيها
        //   الطلب مرئياً للمندوبين — لا لحظة قَيده.
        const pharmacyApproved =
          !o.isNew && prevStatus === 'pharmacy_review' && st === 'pending';
        const assignedNow = !!nowDriver && nowDriver !== prevDriver;
        const rType = rowTypeFor(st, o.isNew);
        const sKey = soundKeyFor(st, o.isNew);
        const no = o.data.serial || '';
        const ar = arOf(st);

        if (o.phone && statusChanged && !pharmacyApproved) {
          // ★★ لا نرسل أي صورة: لا شعار متجر ولا صورة منتج.
          //   كان يُرسل `shops.image_path` — صورة **مشتركة** بين كل
          //   زبائن ذلك المتجر، فكانت تُقرأ كأنها شعار كل حساب. الآن
          //   الإشعار بلا صورة كبيرة، والتطبيق يعرض شعار صاحبه وحده
          //   إن كان داخلاً (`brandImage`)، وإلا فلا صورة.
          // ★ الرقم في العنوان: أول سطر يقرؤه المتلقّي في شريط
          //   الإشعارات، وبدونه لا يعرف أي طلب.
          const okPhones = await this._push(
            o.phone,
            o.isNew
              ? (no ? `طلب جديد ${no}` : 'طلب جديد')
              : (no ? `طلبك ${no}: ${ar}` : `طلبك: ${ar}`),
            o.isNew
              ? 'وصل طلبك إلى المتجر.'
              : (no ? `حالة الطلب ${no}: ${ar}` : `حالة الطلب ${ar}.`),
            {
              orderId: String(o.data.id || ''),
              status: st,
              // ★ النوع لا الحالة: التطبيق يبني به مفتاح منع
              //   التكرار، وصفوف الجديد/الإرجاع كُتبت new_order
              //   وreopened — إرسال اسم الحالة ينشئ مفتاحاً ثانياً.
              type: rType,
              sound: sKey,
              serial: no,
            },
            '',
            // ★ فحص الصف للزبون عند تغيّر الحالة فقط: صف الطلب
            //   الجديد يخصّ المندوبين، فلا صفّ زبون يُفحص (وبه لا
            //   يُكتم إشعار «وصل طلبك»).
            !o.isNew,
          );
          // ★ العلامة للزبون عند تغيّر الحالة فقط. الطلب الجديد
          //   لا صفّ للزبون فيه (`new_order` صفوف مندوبين!) فلو
          //   وسمناها هنا لكتمنا إشعارهم بلا إرسال.
          if (!o.isNew && okPhones.length) {
            await this._markPushed(o.data.id, rType, okPhones);
          }
        }

        // ★★ طلب جديد: كل المندوبين — بنفس السرعة للطلب العادي
        //   وطلب المندوب الحرّ. كان الحرّ وحده يصل FCM، والعادي
        //   يراه المندوب بالاستطلاع وحده (تأخير دقيقة كاملة).
        //   الصفوف للمندوبين تكتبها القاعدة بنفسها: driver_request
        //   للحرّ وnew_order للعادي.
        //
        // ★★ استثناء طلب الوصفة: يُقيد بحالة `pharmacy_review` ولا
        //   يظهر للمندوبين حتى تعتمده الصيدلية — فلا يصحّ أن يرنّ
        //   هاتفهم لطلب لم تُقرأ وصفته بعد. إشعارهم يأتي في لحظة
        //   الموافقة (الفرع التالي).
        if (o.isNew && String(o.data.status || '') !== 'pharmacy_review') {
          const dType = o.data.isDriverRequest ? 'driver_request' : 'new_order';
          const okD = await this._pushDrivers(
            o.data.isDriverRequest
              ? (no ? `لديك طلب مندوب ${no}` : 'طلب مندوب جديد')
              : (no ? `طلب توصيل جديد ${no}` : 'طلب توصيل جديد'),
            o.data.isDriverRequest
              ? `مطلوب مندوب — ${o.data.address || 'في منطقتك'}`
              : `مطلوب توصيل — ${o.data.address || 'في منطقتك'}`,
            {
              orderId: String(o.data.id || ''),
              status: dType,
              type: dType,
              sound: 'new_order',
              serial: no,
            },
            '',
            o.phone,
          );
          if (okD.length) await this._markPushed(o.data.id, dType, okD);

          // ★★ من وصله إشعار المندوبين/الأدمن في هذه اللحظة يُسجَّل
          //   هنا، فلا يصل نفس الهاتف إشعار ثانٍ كصاحب متجر لنفس
          //   الطلب (صوت واحد لكل طلب لكل هاتف).
          const pending = this.pendingOwners.get(o.data.id);
          if (pending) for (const p of okD) pending.driverPushed.add(p);
        }

        // ★★ الصيدلية وافقت على طلب الوصفة: الآن فقط يُرى الطلب
        //   ويُرنّ هاتف كل مندوب — بنفس رسالة الطلب العادي. صفوف
        //   المندوبين كتبتها دالة الموافقة في القاعدة، والوسم هنا
        //   يمنع أن تُرسَل مرة ثانية من مسار صفوف الإشعارات.
        if (pharmacyApproved) {
          const dType = o.data.isDriverRequest ? 'driver_request' : 'new_order';
          const okD = await this._pushDrivers(
            o.data.isDriverRequest
              ? (no ? `لديك طلب مندوب ${no}` : 'طلب مندوب جديد')
              : (no ? `طلب توصيل جديد ${no}` : 'طلب توصيل جديد'),
            o.data.isDriverRequest
              ? `مطلوب مندوب — ${o.data.address || 'في منطقتك'}`
              : `مطلوب توصيل — ${o.data.address || 'في منطقتك'}`,
            {
              orderId: String(o.data.id || ''),
              status: dType,
              type: dType,
              sound: 'new_order',
              serial: no,
            },
            '',
            o.phone,
          );
          if (okD.length) await this._markPushed(o.data.id, dType, okD);
        }

        // ★★ المندوب المسؤول عن الطلب: كان الإشعار يذهب للزبون
        //   وحده، فالمندوب لا يعلم بقبول/رفض/إنجاز طلبه إلا إن كان
        //   التطبيق مفتوحاً. الآن كل تغيّر حالة أو إسناد جديد يصل
        //   جهازه فوراً — والتطبيق مغلق.
        if (!o.isNew && (statusChanged || assignedNow) && nowDriver && nowDriver !== o.phone) {
          await this._push(
            nowDriver,
            assignedNow
              ? (no ? `أُسند إليك الطلب ${no}` : 'أُسند إليك طلب جديد')
              : (no ? `طلبك ${no}: ${ar}` : `طلبك: ${ar}`),
            assignedNow
              ? 'افتح التطبيق لعرض تفاصيل الطلب.'
              : (no ? `حالة الطلب ${no}: ${ar}` : `حالة الطلب ${ar}.`),
            {
              orderId: String(o.data.id || ''),
              status: st,
              type: rType,
              sound: sKey,
              serial: no,
            },
            '',
          );
          // لا علامة هنا: صفوف تغيّر الحالة مكتوبة للزبون وحده —
          // وسمها الآن يكتم صفّ الزبون قبل أن يعرضه التطبيق.
        }
      }

      for (const c of this.diff('products', products, (p) => ({
        key: p.id,
        fingerprint: `${p.updated_at}|${p.price}|${p.old_price}|${p.name}|${p.is_active}`,
        data: {
          id: p.id,
          name: p.name,
          price: p.price,
          oldPrice: p.old_price,
          shopId: p.shop_id,
          at: p.updated_at,
        },
      }))) {
        this.stats.productEvents += 1;
        const isPrice = c.data.oldPrice !== null && c.data.price !== c.data.oldPrice;
        // ★ الأدمن وأصحاب المتاجر **والزبائن**: إطفاء منتج أو تغيير
        //   سعره يجب أن يختفي/يتغيّر عند الزبون المفتوح خلال ثوانٍ.
        //   كان البث للأدمن فقط، فيبقى المنتج في كاش الزبون حتى
        //   يُغلق التطبيق ويفتحه — وهو عكس ما طلبه التاجر تماماً.
        publish(isPrice ? EV.PRICE_CHANGED : EV.PRODUCT_CHANGED, c.data, {
          roles: ['admin', 'shop_owner', 'customer'],
        });
      }

      // ★ الحذف لا يظهر في الاستطلاع: الصف يختفي ولا يُرجَع.
      //   نقارن ما رأيناه سابقاً بما نراه الآن.
      //
      //   ★ تحذير: النافذة محدودة بـlimit، فإذا خرج منتج من النافذة
      //     بسبب ظهور 60 صفاً أحدث، سيبدو محذوفاً زوراً.
      //     لذلك لا نعتمد الغياب إلا حين تكون النافذة **غير ممتلئة**
      //     (أي نرى كل شيء، فالغياب يعني حذفاً حقيقياً).
      if (this.seen.productNames.size > 0 && products.length > 0 && products.length < this.limit) {
        const nowIds = new Set(products.map((p) => p.id));
        for (const [id, name] of this.seen.productNames) {
          if (nowIds.has(id)) continue;
          this.stats.productEvents += 1;
          this.stats.deletedEvents += 1;
          // ★ `customer` هنا أيضاً: التاجر يحذف منتجاً فيختفي من
          //   كاش الزبون، فيبقى معروضاً له حتى إعادة تشغيل التطبيق
          //   — وهو نفس عيب الإطفاء. الحذف ليس "خبراً" يُعلَن
          //   إشعاراً، لكنه يجب أن يحدّث القائمة.
          publish(EV.PRODUCT_DELETED, { id, name, at: Date.now() }, {
            roles: ['admin', 'shop_owner', 'customer'],
          });
        }
      }

      this.stats.ticks += 1;
      this.stats.lastAt = Date.now();
      // ★ آخر حلقة في الدورة: كل ما كتبته القاعدة من إشعارات **لا
      //   تخصّ الطلبات** (أكواد الخصم، العجلة، المحفظة، الإعلانات،
      //   حجوزات الدكتور…) لا يمرّ بمسارات الطلبات أعلاه، فكان
      //   يطنّ داخل التطبيق المفتوح وحده. هذه الحلقة تحوّله إلى
      //   رسالة FCM فتصل والهاتف مقفول — طلب ٢٠٢٦-١١-٠٢.
      await this._pushNotificationRows();
      // ★ هل المشروع فيه طلبات لم تُنجَز؟ هذا يقرر سرعة الدورة القادمة.
      //   «هل تغيّر شيء؟» وحده لا يكفي: المشروع قد يكون فيه طلب
      //   منتظر منذ دقائق، والإشعار يجب أن يبقى سريعاً طالما هو
      //   معلّق — وإلا تأخّر إعلان قبوله حتى».

      //   فنجمع السبب معاً: تغيّر فعلي **أو** وجود طلب نشط.
      const active = orders.filter((o) =>
        ['pending', 'accepted', 'delivering', 'pharmacy_review'].includes(o.status),
      ).length;
      this.activeOrders = active;
      this.seen.productNames = new Map(products.map((p) => [p.id, p.name ?? '']));
      this._shopsFrom(products);
      await this._watchOrderItems(items, orders);

      // ★ الشعارات تتغيّر نادراً (رفع صورة متجر). نحدّثها كل ٦٠ ثانية
      //   لا كل دورتين — طلب إضافي بلا فائدة.
      if (!this._shopsAt || Date.now() - this._shopsAt > 60000) {
        this._shopsAt = Date.now();
        await this._loadShops();
        // ★ بعد تحميل الشعارات نعيد الحساب، فقد يكون الملف الأول مرة
        //   قد شوهد قبل توفّر شعار متجره.
        await this._watchOrderItems(items, orders);
      }

      // ★ صاحب متجر الطلب: بعد معرفة بنوده ومتاجره في هذه الدورة.
      await this._notifyShopOwners(shopIdsByOrder);
    } catch (err) {
      this.stats.errors += 1;
      this.onError(err.message);
    } finally {
      this.busy = false;
    }
    const after =
      this.stats.orderEvents +
      this.stats.productEvents +
      this.stats.itemEvents +
      this.stats.deletedEvents;
    return after > before;
  }
}
