// =====================================================================
//  مُرسِل APNs المباشر (آيفون) — بلا Firebase، صفر اعتماديات.
// =====================================================================
//
//  ★ لماذا مباشر؟
//    آيفون صار له تطبيق في مشروع `diqarapp` (٢٠٢٦-١١-٢٤) ومسار
//    FCM→APNs يعمل، لكن مفتاح APNs المباشر (`.p8`) يبقى بديلاً
//    للجسر الأصلي الذي يرفع توكن APNs خاماً (64 خانة hex) بلا Firebase.
//
//  المتطلبات (بيئة الخدمة):
//    APNS_KEY_ID    = معرّف المفتاح (مثلاً 5K3C27GMCU)
//    APNS_TEAM_ID   = معرّف الفريق (مثلاً 83YH99T3ND)
//    APNS_BUNDLE_ID = com.saydaliti.app
//    APNS_KEY_PATH  = مسار ملف .p8   (أو APNS_KEY_P8 = محتواه)
//    APNS_ENV       = auto | production | sandbox   (افتراضياً auto)
//
//  ★ auto: يجرب production أولاً، وإن ردّ BadDeviceToken يعيد على
//    sandbox — لأن توقيع Sideloadly المجاني ينتج توكن sandbox بينما
//    نسخة App Store/TestFlight تنتج توكن production.
// =====================================================================

import crypto from 'node:crypto';
import fs from 'node:fs';
import http2 from 'node:http2';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ORIGIN = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

export class ApnsSender {
  constructor({ onLog = () => {} } = {}) {
    this.onLog = onLog;
    this.keyPath =
      String(process.env.APNS_KEY_PATH || '').trim() ||
      path.join(__dirname, '..', 'AuthKey_APNs.p8');
    this.keyId = String(process.env.APNS_KEY_ID || '').trim();
    this.teamId = String(process.env.APNS_TEAM_ID || '').trim();
    this.bundleId = String(process.env.APNS_BUNDLE_ID || '').trim() || 'com.saydaliti.app';
    this.env = String(process.env.APNS_ENV || 'auto').trim().toLowerCase();

    this.key = '';
    try {
      const inline = String(process.env.APNS_KEY_P8 || '').trim();
      if (inline) this.key = inline.replace(/\\n/g, '\n');
      else if (fs.existsSync(this.keyPath)) this.key = fs.readFileSync(this.keyPath, 'utf8');
    } catch (e) {
      this.onLog(`تعذّرت قراءة مفتاح APNs (${this.keyPath}): ${e.message}`);
    }

    this.missing = [];
    if (!this.key) this.missing.push('مفتاح APNs (.p8)');
    if (!this.keyId) this.missing.push('APNS_KEY_ID');
    if (!this.teamId) this.missing.push('APNS_TEAM_ID');
    if (!this.bundleId) this.missing.push('APNS_BUNDLE_ID');

    this._jwt = '';
    this._jwtAt = 0;
    this._sessions = new Map();
    this._dedupe = new Map();
    this.sent = 0;
    this.failed = 0;
    this.skipped = 0;
    this.deduped = 0;
  }

  get enabled() {
    return Boolean(this.key && this.keyId && this.teamId && this.bundleId);
  }

  get stats() {
    return {
      apnsEnabled: this.enabled,
      apnsBundle: this.bundleId || null,
      apnsEnv: this.env || 'auto',
      apnsMissing: this.missing.length ? this.missing : null,
      apnsSent: this.sent,
      apnsFailed: this.failed,
      apnsSkipped: this.skipped,
      apnsDeduped: this.deduped,
    };
  }

  /** JWT (ES256) صالح ~ساعة؛ يُعاد كل ٥٠ دقيقة. */
  _jwtToken() {
    const now = Date.now();
    if (this._jwt && now - this._jwtAt < 50 * 60 * 1000) return this._jwt;
    const header = Buffer.from(
      JSON.stringify({ alg: 'ES256', kid: this.keyId }),
    ).toString('base64url');
    const claim = Buffer.from(
      JSON.stringify({ iss: this.teamId, iat: Math.floor(now / 1000) }),
    ).toString('base64url');
    const signature = crypto
      .sign('sha256', Buffer.from(`${header}.${claim}`), {
        key: this.key,
        dsaEncoding: 'ieee-p1363',
      })
      .toString('base64url');
    this._jwt = `${header}.${claim}.${signature}`;
    this._jwtAt = now;
    return this._jwt;
  }

  _session(env) {
    const cached = this._sessions.get(env);
    if (cached && !cached.closed && !cached.destroyed) return cached;
    const session = http2.connect(ORIGIN[env]);
    session.on('error', (e) => {
      this.onLog(`APNs ${env} جلسة: ${e.message}`);
      this._sessions.delete(env);
    });
    session.on('goaway', () => {
      this._sessions.delete(env);
      try {
        session.close();
      } catch (_) {}
    });
    this._sessions.set(env, session);
    return session;
  }

  _drop(env) {
    const s = this._sessions.get(env);
    this._sessions.delete(env);
    try {
      s?.close();
    } catch (_) {}
  }

  /** يرسل إلى بيئة واحدة ويعيد `{ ok, status, reason }`. */
  _sendTo(env, token, payload) {
    return new Promise((resolve) => {
      let session;
      let req;
      try {
        session = this._session(env);
        req = session.request({
          ':method': 'POST',
          ':path': `/3/device/${token}`,
          authorization: `bearer ${this._jwtToken()}`,
          'apns-topic': this.bundleId,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          'apns-expiration': String(Math.floor(Date.now() / 1000) + 600),
          'content-type': 'application/json',
        });
      } catch (e) {
        this._drop(env);
        resolve({ ok: false, status: 0, reason: e.message });
        return;
      }
      let status = 0;
      let body = '';
      req.setEncoding('utf8');
      req.on('response', (headers) => {
        status = Number(headers[':status']) || 0;
      });
      req.on('data', (chunk) => {
        body += chunk;
      });
      req.on('end', () => {
        let reason = '';
        try {
          reason = JSON.parse(body || '{}')?.reason || '';
        } catch {}
        resolve({ ok: status === 200, status, reason });
      });
      req.on('error', (e) => {
        this._drop(env);
        resolve({ ok: false, status: 0, reason: e.message });
      });
      req.setTimeout(8000, () => {
        try {
          req.close();
        } catch (_) {}
        resolve({ ok: false, status: 0, reason: 'timeout' });
      });
      req.end(JSON.stringify(payload));
    });
  }

  /**
   * إرسال إشعار واحد إلى توكن آيفون.
   * حمولة APNs: `aps` للعرض، وبقية المفاتيح في الجذر يقرأها التطبيق
   * عند الضغط (orderId/serial/kind/type/status/rowId/link).
   */
  async send(token, { title, body, data = {} }, opts = {}) {
    if (!this.enabled) {
      this.skipped += 1;
      return false;
    }
    if (!token) return false;

    // منع التكرار داخل العملية — نفس منطق FCM.
    const key = [token, data.rowId || data.orderId || '', data.type || data.sound || data.status || ''].join('|');
    const now = Date.now();
    const seenAt = this._dedupe.get(key);
    if (seenAt && now - seenAt < 120000) {
      this.deduped += 1;
      return false;
    }
    this._dedupe.set(key, now);
    if (this._dedupe.size > 500) {
      for (const [k, t] of this._dedupe) {
        if (now - t > 120000) this._dedupe.delete(k);
      }
      if (this._dedupe.size > 2000) this._dedupe.clear();
    }

    const payload = {
      aps: {
        alert: { title: title || 'إشعار جديد', body: body || '' },
        sound: 'default',
      },
      ...Object.fromEntries(
        Object.entries({ ...data, title: title || '', body: body || '' }).map(
          ([k, v]) => [k, String(v ?? '')],
        ),
      ),
    };

    const preferred = opts.env || this.env;
    const envs =
      preferred === 'sandbox' || preferred === 'production'
        ? [preferred]
        : ['production', 'sandbox'];

    let last = { ok: false, status: 0, reason: '' };
    for (const env of envs) {
      const res = await this._sendTo(env, token, payload);
      last = res;
      if (res.ok) {
        this.sent += 1;
        return true;
      }
      // توكن من البيئة الأخرى: جرّب التالية. غير ذلك توقف.
      const wrongEnv =
        res.status === 400 &&
        (res.reason === 'BadDeviceToken' || res.reason === 'DeviceTokenNotForTopic');
      if (!wrongEnv) break;
    }

    this.failed += 1;
    if (last.reason === 'Unregistered' || last.status === 410) {
      this.onLog(`APNs توكن ميت (${last.status} ${last.reason}) — يُنظَّف من القاعدة`);
    } else if (!last.ok) {
      this.onLog(`APNs فشل ${last.status} ${last.reason}`);
    }
    return false;
  }
}
