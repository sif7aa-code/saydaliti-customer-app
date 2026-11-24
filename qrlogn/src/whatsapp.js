import fs from 'node:fs';

import makeWASocket, { DisconnectReason } from '@whiskeysockets/baileys';
import QRCode from 'qrcode';

import { EV, publish } from './events.js';
import { useEncryptedAuthState } from './encrypted-auth-state.js';
import { loadSessionKey } from './session-crypto.js';

const silentLogger = {
  level: 'silent',
  child() {
    return silentLogger;
  },
  trace() {},
  fatal() {},
  error() {},
  warn() {},
  info() {},
  debug() {},
  silent() {},
};

const QR_TTL_MS = 45000;
// ★ Only a real logout must wipe the session.
//   403 / 405 / 428 are transient (server push fails, version out of
//   date, clock skew). Treating them as a logout deleted 39 auth files
//   every few minutes and forced a fresh QR scan each time.
//   401 logged_out is the genuine "unpaired" signal.
const UNPAIR_CODES = new Set([401]);

// Codes worth a slow retry rather than a fast loop.
const SOFT_RETRY = new Set([408, 421, 428, 429, 500, 502, 503, 504, 515]);

// How many consecutive soft failures before we give up and rescan.
const MAX_QUICK_RETRIES = 8;

export class WhatsAppClient {
  constructor({ sessionDir, log = () => {} }) {
    this.sessionDir = sessionDir;
    this.log = log;
    this.sock = null;
    this.state = 'stopped';
    this.phone = null;
    this.qrDataUrl = null;
    this.qrExpiresAt = 0;
    this.lastError = null;
    this.reconnectAttempts = 0;
    this.openedAt = 0;
    this.syncedAt = 0;
    this.watchdog = null;
    this.reconnectTimer = null;
    this.presence = null;
    this.softFailures = 0;
    this._lastAnnounced = null;
  }

  announceState() {
    // ★ بثّ عند كل تغيّر حالة. الكتم يمنع ضجيج البثّ أثناء الانتقال
    //  connecting → connecting (مراقب إعادة الاتصال ينادي كل 45 ثانية).
    const s = this.state;
    if (s === this._lastAnnounced) return;
    this._lastAnnounced = s;
    publish(EV.WA_STATE, { state: s, phone: this.phone, error: this.lastError }, { roles: ['admin'] });
  }

  status() {
    return {
      state: this.state,
      connected: this.state === 'connected',
      ready: this.isReady(),
      phone: this.phone,
      qr: this.qrDataUrl,
      qrExpiresAt: this.qrExpiresAt,
      lastError: this.lastError,
    };
  }

  isReady() {
    if (this.state !== 'connected') return false;
    if (this.syncedAt) return true;
    return this.openedAt > 0 && Date.now() - this.openedAt > 20000;
  }

  async start() {
    if (this.sock) return;
    fs.mkdirSync(this.sessionDir, { recursive: true });

    // ★ لا نستخدم useMultiFileAuthState: في Baileys 6.7.24 هي بلا خيار
    //   تشفير وتكتب JSON صريحاً. البديل مشفَّر AES-256-GCM، ويرقّي
    //   الملفات القديمة تلقائياً فلا يضيع الربط.
    const sessionKey = loadSessionKey();
    const { state, saveCreds, migrateAll } = await useEncryptedAuthState(
      this.sessionDir,
      { key: sessionKey, log: this.log },
    );
    // ★ تشفير كل ما على القرص فوراً: القراءة كسولة، فبدون هذه
    //   الجولة تبقى مفاتيح pre-key وsender-key نصّية حتى تُلمس.
    const migrated = await migrateAll();
    if (migrated > 0) {
      this.log(`تم تشفير ${migrated} ملف جلسة على القرص.`);
    }

    const sock = makeWASocket({
      auth: state,
      printQRInTerminal: false,
      browser: ['WhatsApp', 'Chrome', '120.0'],
      logger: silentLogger,
      markOnlineOnConnect: true,
      keepAliveIntervalMs: 25000,
      connectTimeoutMs: 30000,
      defaultQueryTimeoutMs: 45000,
      generateHighQualityLinkPreview: false,
    });

    this.sock = sock;
    this.state = 'connecting';
    this.log('جاري فتح جلسة واتساب...');

    sock.ev.on('creds.update', saveCreds);

    // ★ WhatsApp drops a socket that sends nothing. A presence
    //   update every 40s is what keeps a linked session alive for
    //   days instead of minutes.
    this.presence = setInterval(() => {
      if (this.sock !== sock) return;
      if (this.state !== 'connected') return;
      try {
        sock.sendPresenceUpdate('available');
      } catch {}
    }, 40000);
    this.presence.unref?.();

    const markSynced = () => {
      if (this.syncedAt) return;
      this.syncedAt = Date.now();
      this.log('اكتملت مزامنة الحالة — جاهز لإرسال الأكواد.');
    };
    sock.ev.on('messaging-history.set', markSynced);
    sock.ev.on('contacts.set', markSynced);

    sock.ev.on('connection.update', async (update) => {
      if (update.qr) {
        this.reconnectAttempts = 0;
        this.softFailures = 0;
        this.qrDataUrl = await QRCode.toDataURL(update.qr, {
          margin: 1,
          scale: 5,
          errorCorrectionLevel: 'M',
        });
        this.qrExpiresAt = Date.now() + QR_TTL_MS;
        this.state = 'waiting_scan';
        this.log('رمز QR جاهز، امسحه من الهاتف.');
        // ★ بثّ فوري للوحة: كانت تطلب /api/status كل 3 ثوانٍ، فكان
        //   الرمز يظهر متأخراً حتى 3 ثوانٍ بعد جيله.
        publish(EV.QR, { qr: this.qrDataUrl, expiresAt: this.qrExpiresAt }, { roles: ['admin'] });
      }

      if (update.connection === 'open') {
        this.state = 'connected';
        this.softFailures = 0;
        this.reconnectAttempts = 0;
        this.qrDataUrl = null;
        this.qrExpiresAt = 0;
        this.lastError = null;
        this.openedAt = Date.now();
        this.syncedAt = 0;
        this.phone = sock.user?.id?.split('@')[0]?.split(':')[0] ?? null;
        this.log(`تم الربط بنجاح: ${this.phone} — جارٍ المزامنة...`);
        publish(EV.QR, { qr: null }, { roles: ['admin'] });
      }

      if (update.connection === 'close') {
        this.qrDataUrl = null;
        this.qrExpiresAt = 0;
        const status = update.lastDisconnect?.error?.output?.statusCode;
        this.lastError = update.lastDisconnect?.error?.message ?? 'closed';
        this.release(sock);

        if (status === DisconnectReason.loggedOut || UNPAIR_CODES.has(status)) {
          this.phone = null;
          this.log('انتهت صلاحية الجلسة — جارٍ توليد رمز QR جديد تلقائياً.');
          this.wipeSession();
          this.state = 'connecting';
          this.scheduleReconnect(500);
          return;
        }

        this.state = 'disconnected';

        // Repeated soft failures mean the network path is bad, not the
        // session. Back off hard so the socket is not hammered.
        if (SOFT_RETRY.has(Number(status))) this.softFailures += 1;
        else this.softFailures = 0;

        if (this.softFailures >= MAX_QUICK_RETRIES) {
          const wait = 60000;
          this.log(
            `${this.softFailures} انقطاعات متتالية - استراحة ${wait / 1000}ث قبل المحاولة التالية.`,
          );
          this.scheduleReconnect(wait);
          return;
        }

        const wait = Math.min(5000 * 2 ** (this.reconnectAttempts ?? 0), 60000);
        this.reconnectAttempts = (this.reconnectAttempts ?? 0) + 1;
        this.log(
          `انقطع الاتصال (${this.lastError}). إعادة المحاولة بعد ${wait / 1000}ث...`,
        );
        this.scheduleReconnect(wait);
      }
    });

    this.startWatchdog();
    this.announceState();
  }

  wipeSession() {
    try {
      fs.rmSync(this.sessionDir, { recursive: true, force: true });
    } catch {}
  }

  startWatchdog() {
    if (this.watchdog) return;
    this.watchdog = setInterval(() => {
      if (this.state === 'connected' || this.state === 'waiting_scan') return;
      if (this.reconnectTimer) return;
      this.log('مراقب الحالة: إعادة الاتصال...');
      this.scheduleReconnect(1000);
    }, 45000);
    this.watchdog.unref?.();
  }

  release(sock) {
    if (this.presence) {
      clearInterval(this.presence);
      this.presence = null;
    }
    if (this.sock === sock) this.sock = null;
    this.syncedAt = 0;
    this.openedAt = 0;
    try {
      sock.ev.removeAllListeners('connection.update');
      sock.ev.removeAllListeners('creds.update');
      sock.end(undefined);
    } catch {}
  }

  scheduleReconnect(delay) {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      if (this.sock) return;
      try {
        await this.start();
      } catch (err) {
        this.lastError = err.message;
        this.scheduleReconnect(15000);
      }
    }, delay);
    this.reconnectTimer.unref?.();
  }

  async stop() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.watchdog) {
      clearInterval(this.watchdog);
      this.watchdog = null;
    }
    const sock = this.sock;
    this.sock = null;
    this.state = 'stopped';
    this.phone = null;
    this.qrDataUrl = null;
    this.qrExpiresAt = 0;
    if (sock) this.release(sock);
  }

  async logout() {
    const sock = this.sock;
    if (sock) {
      try {
        await sock.logout();
      } catch {}
    }
    await this.stop();
    this.wipeSession();
    this.lastError = null;
    this.state = 'logged_out';
    this.log('تم مسح الجلسة. حدّث الصفحة لمسح رمز QR جديد.');
  }

  async restartFresh() {
    const sock = this.sock;
    if (sock) {
      try {
        await sock.logout();
      } catch {}
    }
    await this.stop();
    this.wipeSession();
    this.state = 'connecting';
    this.lastError = null;
    await this.start();
  }

  withTimeout(promise, ms, label) {
    let timer;
    return Promise.race([
      promise.finally(() => clearTimeout(timer)),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(label)), ms);
        timer.unref?.();
      }),
    ]);
  }

  waitReady(ms = 30000) {
    if (this.isReady()) return Promise.resolve(true);
    return new Promise((resolve) => {
      const started = Date.now();
      const timer = setInterval(() => {
        if (this.state !== 'connected') {
          clearInterval(timer);
          resolve(false);
        } else if (this.isReady()) {
          clearInterval(timer);
          resolve(true);
        } else if (Date.now() - started > ms) {
          clearInterval(timer);
          resolve(true);
        }
      }, 500);
      timer.unref?.();
    });
  }

  waitStatus(id, ms = 10000) {
    return new Promise((resolve) => {
      const sock = this.sock;
      if (!sock) return resolve('unknown');
      const done = (value) => {
        clearTimeout(timer);
        sock.ev.off('messages.update', onUpdate);
        resolve(value);
      };
      const onUpdate = (updates) => {
        try {
          for (const item of updates) {
            if (item?.key?.id !== id) continue;
            const status = item.update?.status;
            if (status === -1) return done('error');
            if (status >= 1) return done('sent');
          }
        } catch (err) {
          done('unknown');
        }
      };
      const timer = setTimeout(() => done('pending'), ms);
      timer.unref?.();
      sock.ev.on('messages.update', onUpdate);
    });
  }

  async sendText(phone, text) {
    if (this.state !== 'connected' || !this.sock) {
      throw new Error('whatsapp_not_connected');
    }
    const pnJid = `${phone}@s.whatsapp.net`;

    const ready = await this.waitReady(30000);
    if (!ready) throw new Error('whatsapp_not_connected');

    const found = await this.withTimeout(
      this.sock.onWhatsApp(pnJid).catch(() => undefined),
      15000,
      'check_timeout',
    );

    const hit = found?.find((r) => r.exists) ?? null;
    if (found && !hit) {
      throw new Error('number_not_on_whatsapp');
    }

    // WhatsApp now addresses accounts by LID (@lid). Sending to the legacy
    // phone-number JID makes the recipient unable to resolve the identity,
    // which shows up as "this message is encrypted". Prefer the LID.
    const jid = this.pickTargetJid(hit, pnJid);
    this.log(`إرسال إلى ${phone} عبر ${jid.split('@')[1]}: ${jid}`);

    const res = await this.withTimeout(
      this.sock.sendMessage(jid, { text }),
      20000,
      'send_timeout',
    );

    const id = res?.key?.id ?? null;
    const status = id ? await this.waitStatus(id) : 'unknown';
    if (status === 'error') throw new Error('send_failed');

    return { id, to: jid, status };
  }

  pickTargetJid(hit, fallback) {
    if (!hit) return fallback;
    if (typeof hit.lid === 'string' && hit.lid.includes('@')) return hit.lid;
    if (typeof hit.jid === 'string' && hit.jid.includes('@')) return hit.jid;
    return fallback;
  }
}
