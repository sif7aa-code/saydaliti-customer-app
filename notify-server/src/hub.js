import { bus } from './events.js';

// ★ ٢٠٢٦-١٠-٢٨: من ٢٠ ثانية إلى ١٠.
//   حارس الحياة في التطبيق (realtime_service.dart) يفسّر صمتاً أطول
//   من ٣٥ ثانية على أنه قطع صامت، فيعيد الاتصال ويسحب الإشعارات
//   فوراً. كلما قصُرت النبضة قلّت النافذة التي يمكن أن يتأخر فيها
//   حدث بلا أن يشعر الجهاز. النبضة سطر تعليق في SSE فلا تحمل بيانات.
const HEARTBEAT_MS = 10000;

/** آخر ١٠ أرقام — صيغ الرقم تختلف (07.. / 7.. / +964..) والحدث واحد. */
const normPhone = (p) => String(p || '').replace(/\D/g, '').slice(-10);

/**
 * مركز البث عبر Server-Sent Events.
 *
 * ★ لماذا SSE لا WebSocket: البث أحادي الاتجاه (خادم ← عميل)، وSSE
 *   يمرّ عبر نفس المنفذ بلا ترقية ويعيد الاتصال تلقائياً.
 *   WebSocket غالباً يفشل خلف nginx بلا إعداد upgrade.
 *
 * ★ لا يمرّ في الحمولة أي بيانات شخصية: معرّف ونوع فقط. لو سُرّب
 *   البث كاملاً فهو يسرّب أنواع الأحداث، لا أسماء الزبائن.
 */
class RealtimeHub {
  constructor() {
    this.clients = new Set();
    this.seq = 0;
    this.total = 0;
    bus.on('fanout', (evt) => this.fanout(evt));
  }

  add(res, meta) {
    const client = { res, meta, id: ++this.seq };
    this.clients.add(client);

    // نبضة: nginx/المستويات الوسطى تقطع اتصالاً بلا بيانات.
    client.hb = setInterval(() => {
      try {
        res.write(`: ping ${Date.now()}\n\n`);
      } catch {
        this.remove(client);
      }
    }, HEARTBEAT_MS);
    client.hb.unref?.();

    const drop = () => this.remove(client);
    res.on('close', drop);
    res.on('error', drop);
    return client;
  }

  remove(client) {
    if (!this.clients.delete(client)) return;
    clearInterval(client.hb);
  }

  fanout({ topic, payload, audience }) {
    if (this.clients.size === 0) return;
    const body = JSON.stringify(payload);
    // ★★ اجتماع لا حصر: كان الشرط حصرياً — إن وُجدت `phones` تُجوهل
    //   `roles` تماماً (else-if). فحدثٌ جمهوره {phones:[صاحب الطلب],
    //   roles:[driver,admin]} كان يصل **الزبون فقط**، والمندوب والأدمن
    //   لا يعلمان بشيء — وهو سبب «تأخّر/غياب إشعار المندوب» رغم
    //   وصوله للزبون فوراً. الآن يكفي أن ينطبق **أي** شرط من الاثنين.
    const hasPhones = Array.isArray(audience.phones);
    const hasRoles = Array.isArray(audience.roles);
    for (const client of this.clients) {
      const { phone, roles } = client.meta;
      if (hasPhones || hasRoles) {
        const byPhone = hasPhones && audience.phones.includes(phone);
        const byRole = hasRoles && audience.roles.some((r) => roles.includes(r));
        if (!byPhone && !byRole) continue;
      }
      this.total += 1;
      try {
        client.res.write(`id: ${client.id}-${Date.now()}\nevent: ${topic}\ndata: ${body}\n\n`);
      } catch {
        this.remove(client);
      }
    }
  }

  /**
   * ★ يدفع حدثاً **لصاحب الرقم وحده** — مطابقة بآخر ١٠ أرقام كي لا
   *   تفلت صيغ الرقم، ولا يصل حدث رقمٍ إلى جهاز حساب آخر.
   *
   *   يُستعمل لحدث `notify.new`: صفّ إشعار جديد ⇒ التطبيق المفتوح
   *   يسحب إشعاره **الآن** بدل فحصٍ كل ثانية، فيبقى الوصول فورياً
   *   والاستهلاك أضعافاً أقلّ.
   */
  sendToPhones(topic, payload, phones) {
    if (this.clients.size === 0) return 0;
    const keys = new Set(phones.map(normPhone).filter(Boolean));
    if (keys.size === 0) return 0;
    const body = JSON.stringify(payload);
    let sent = 0;
    for (const client of this.clients) {
      if (!keys.has(normPhone(client.meta?.phone))) continue;
      this.total += 1;
      sent += 1;
      try {
        client.res.write(
          `id: ${client.id}-${Date.now()}\nevent: ${topic}\ndata: ${body}\n\n`,
        );
      } catch {
        this.remove(client);
      }
    }
    return sent;
  }

  get size() {
    return this.clients.size;
  }
}

export const hub = new RealtimeHub();
