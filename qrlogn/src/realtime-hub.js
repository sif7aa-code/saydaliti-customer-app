import { bus } from './events.js';

const HEARTBEAT_MS = 20000;

/**
 * مركز البث عبر Server-Sent Events.
 *
 * ★ لماذا SSE لا WebSocket: البث单向 من السيرفر ← العميل فقط، وSSE
 *   يمرّ عبر نفس المنفذ 80/443lyn دون ترقية، ويعيد الاتصال تلقائياً
 *   في المتصفح.(WebSocket upgrade يفشل غالباً خلف nginx بدون إعداد)
 *
 * ★ لا نضع بيانات شخصية في الحمولة: الحدث يحمل معرّفاً ونوعاً فقط،
 *   والعميل يسحب التفاصيل بصلاحياته. لو سرّب بثٌّ كاملاً للمشتركين
 *   فهو يسرّب أنواع الأحداث، لا أسماء الزبائن.
 */
class RealtimeHub {
  constructor() {
    this.clients = new Set();
    this.seq = 0;
    bus.on('fanout', (evt) => this.fanout(evt));
  }

  add(res, meta) {
    const client = { res, meta, id: ++this.seq, alive: true };
    this.clients.add(client);

    // تعليق نبضة: بعض الوسطاء (nginx) يقطعون اتصالاً بلا بيانات.
    client.hb = setInterval(() => {
      try {
        res.write(`: ping ${Date.now()}\n\n`);
      } catch {
        this.remove(client);
      }
    }, HEARTBEAT_MS);
    client.hb.unref?.();

    res.on('close', () => this.remove(client));
    res.on('error', () => this.remove(client));
    return client;
  }

  remove(client) {
    if (!this.clients.delete(client)) return;
    clearInterval(client.hb);
  }

  send(client, topic, payload) {
    try {
      const frame = `id: ${client.id}-${Date.now()}\nevent: ${topic}\ndata: ${JSON.stringify(payload)}\n\n`;
      client.res.write(frame);
    } catch {
      this.remove(client);
    }
  }

  fanout({ topic, payload, audience }) {
    if (this.clients.size === 0) return;
    const body = JSON.stringify(payload);
    for (const client of this.clients) {
      const { phone, roles } = client.meta;
      // ★ الدلالة هي "أو" لا "و": إن حُدّد phones فالرقم هو الفيصل
      //   (وإلا ما وصل طلب الزبون له: هو زبون لا سائق ولا أدمن)،
      //   وإن لم يُحدَّد فالدور هو الفيصل.
      if (Array.isArray(audience.phones)) {
        if (!audience.phones.includes(phone)) continue;
      } else if (Array.isArray(audience.roles)) {
        if (!audience.roles.some((r) => roles.includes(r))) continue;
      }
      try {
        client.res.write(`id: ${client.id}-${Date.now()}\nevent: ${topic}\ndata: ${body}\n\n`);
      } catch {
        this.remove(client);
      }
    }
  }

  get size() {
    return this.clients.size;
  }
}

export const hub = new RealtimeHub();
