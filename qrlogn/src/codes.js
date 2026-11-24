import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const hashCode = (code, salt) =>
  crypto.createHash('sha256').update(`${salt}:${code}`).digest('hex');

const randomDigits = (len) => {
  let out = '';
  for (let i = 0; i < len; i += 1) {
    out += crypto.randomInt(0, 10);
  }
  return out;
};

export class CodeStore {
  constructor(file, options = {}) {
    this.file = file;
    this.ttlMs = options.ttlMs ?? 5 * 60 * 1000;
    this.cooldownMs = options.cooldownMs ?? 60 * 1000;
    this.maxPerPhonePerHour = options.maxPerPhonePerHour ?? 2;
    this.maxTotalPerHour = options.maxTotalPerHour ?? 60;
    this.maxAttempts = options.maxAttempts ?? 5;
    this.codeLength = options.codeLength ?? 4;
    this.entries = new Map();
    this.sends = [];
    this.saveTimer = null;
    this.load();
  }

  load() {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      const now = Date.now();
      for (const item of raw.entries ?? []) {
        if (!item?.phone || !item?.expiresAt || item.expiresAt < now) continue;
        this.entries.set(item.phone, item);
      }
      for (const item of raw.sends ?? []) {
        if (item?.at && item.at > now - 3600 * 1000) this.sends.push(item);
      }
    } catch {}
  }

  save() {
    if (this.saveTimer) return;
    this.saveTimer = setTimeout(() => {
      this.saveTimer = null;
      try {
        fs.mkdirSync(path.dirname(this.file), { recursive: true });
        const payload = {
          savedAt: Date.now(),
          entries: [...this.entries.values()],
          sends: this.sends.slice(-500),
        };
        const tmp = `${this.file}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
        fs.renameSync(tmp, this.file);
      } catch (err) {
        console.error('save failed:', err.message);
      }
    }, 200);
    this.saveTimer.unref?.();
  }

  purge() {
    const now = Date.now();
    for (const [phone, item] of this.entries) {
      if (item.expiresAt < now - 60000) this.entries.delete(phone);
    }
    this.sends = this.sends.filter((s) => s.at > now - 3600 * 1000);
  }

  countFor(phone) {
    const now = Date.now();
    return this.sends.filter((s) => s.phone === phone && s.at > now - 3600 * 1000)
      .length;
  }

  countTotal() {
    const now = Date.now();
    return this.sends.filter((s) => s.at > now - 3600 * 1000).length;
  }

  create(phone) {
    this.purge();
    const now = Date.now();
    const existing = this.entries.get(phone);

    if (existing && existing.expiresAt > now && now - existing.sentAt < this.cooldownMs) {
      return {
        ok: false,
        reason: 'cooldown',
        retryAfter: Math.ceil(
          (this.cooldownMs - (now - existing.sentAt)) / 1000,
        ),
      };
    }

    if (this.countFor(phone) >= this.maxPerPhonePerHour) {
      return { ok: false, reason: 'phone_limit' };
    }
    if (this.countTotal() >= this.maxTotalPerHour) {
      return { ok: false, reason: 'server_limit' };
    }

    const code = randomDigits(this.codeLength);
    const salt = crypto.randomBytes(8).toString('hex');
    const entry = {
      phone,
      salt,
      hash: hashCode(code, salt),
      attempts: 0,
      sentAt: now,
      expiresAt: now + this.ttlMs,
    };

    this.entries.set(phone, entry);
    this.sends.push({ phone, at: now });
    this.save();

    return { ok: true, code, entry };
  }

  release(phone) {
    this.entries.delete(phone);
    this.save();
  }

  verify(phone, code) {
    this.purge();
    const entry = this.entries.get(phone);
    if (!entry) return { ok: false, reason: 'no_code' };
    if (entry.expiresAt < Date.now()) {
      this.entries.delete(phone);
      this.save();
      return { ok: false, reason: 'expired' };
    }
    if (entry.attempts >= this.maxAttempts) {
      this.entries.delete(phone);
      this.save();
      return { ok: false, reason: 'too_many_attempts' };
    }

    const given = Buffer.from(hashCode(String(code ?? ''), entry.salt), 'hex');
    const stored = Buffer.from(entry.hash, 'hex');
    const match =
      given.length === stored.length && crypto.timingSafeEqual(given, stored);

    if (!match) {
      entry.attempts += 1;
      this.save();
      const left = this.maxAttempts - entry.attempts;
      return { ok: false, reason: 'wrong_code', attemptsLeft: Math.max(left, 0) };
    }

    this.entries.delete(phone);
    this.save();
    return { ok: true, phone };
  }

  history(limit = 15) {
    this.purge();
    return this.sends
      .slice(-limit)
      .reverse()
      .map((s) => ({
        phone: maskPhone(s.phone),
        at: s.at,
      }));
  }

  stats() {
    return {
      active: this.entries.size,
      lastHour: this.countTotal(),
      limitPerPhone: this.maxPerPhonePerHour,
      limitTotal: this.maxTotalPerHour,
    };
  }
}

export function normalizePhone(input, countryCode = '') {
  let value = String(input ?? '').replace(/\D/g, '');
  if (!value) return null;
  if (countryCode && !value.startsWith(countryCode)) {
    value = `${countryCode}${value.replace(/^0+/, '')}`;
  }
  if (value.length < 8 || value.length > 15) return null;
  return value;
}

export function maskPhone(phone) {
  const s = String(phone ?? '');
  if (s.length < 5) return s;
  return `${s.slice(0, 3)}****${s.slice(-3)}`;
}
