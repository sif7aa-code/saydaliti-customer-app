const el = (id) => document.getElementById(id);

let adminKey = sessionStorage.getItem('wa_admin_key') || '';
let apiKey = '';
let lastQr = '';

const hideTimer = new Map();

function showSecret(id, value, label) {
  const node = el(id);
  clearTimeout(hideTimer.get(id));
  node.textContent = value;
  node.classList.remove('masked');
  const btn = el(id + 'Toggle');
  if (btn) btn.textContent = 'إخفاء';
  hideTimer.set(
    id,
    setTimeout(() => hideSecret(id, label), 30000),
  );
}

function hideSecret(id, label) {
  const node = el(id);
  node.textContent = label;
  node.classList.add('masked');
  const btn = el(id + 'Toggle');
  if (btn) btn.textContent = 'إظهار';
}

const STATES = {
  stopped: ['متوقف', 'err'],
  connecting: ['جاري الاتصال…', 'warn'],
  disconnected: ['منقطع الاتصال — إعادة المحاولة', 'warn'],
  waiting_scan: ['امسح رمز QR من واتساب', 'warn'],
  connected: ['مربوط وجاهز لإرسال الأكواد', 'ok'],
  logged_out: ['تم فصل الجلسة — حدّث رمز QR', 'err'],
};

function adminHeaders() {
  return adminKey ? { 'x-admin-key': adminKey } : {};
}

async function askAdminKey() {
  if (adminKey) return true;
  const value = window.prompt('أدخل ADMIN_KEY');
  if (!value) return false;
  adminKey = value.trim();
  sessionStorage.setItem('wa_admin_key', adminKey);
  return true;
}

async function call(url, options = {}) {
  const res = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...adminHeaders(),
      ...(options.headers || {}),
    },
  });
  if (res.status === 401 && (await res.clone().json().catch(() => ({}))).error === 'admin_key_required') {
    if (await askAdminKey()) return call(url, options);
  }
  const data = await res.json().catch(() => ({ ok: false, error: 'bad_response' }));
  return { status: res.status, data };
}

async function loadApiKey() {
  if (apiKey) return true;
  try {
    const res = await fetch('/api/panel-key', { headers: adminHeaders() });
    if (res.ok) {
      const data = await res.json();
      if (data?.apiKey) {
        apiKey = data.apiKey;
        return true;
      }
    }
  } catch {}
  const value = window.prompt(
    'مفتاح الـ API لتجربة الإرسال.\nانسخه من ملف data/keys.json على السيرفر.',
  );
  if (!value) return false;
  apiKey = value.trim();
  return true;
}

function renderQr(dataUrl) {
  if (dataUrl === lastQr) return;
  lastQr = dataUrl;
  if (!dataUrl) {
    el('qrWrap').innerHTML = '<div class="spinner"></div>';
    return;
  }
  el('qrWrap').innerHTML = `<img src="${dataUrl}" alt="QR" />`;
}

async function poll() {
  try {
    const res = await fetch('/api/status');
    const d = await res.json();
    applyStatus(d);
  } catch {
    el('badge').textContent = 'السيرفر متوقف';
    el('badge').className = 'badge err';
  }
}

function applyStatus(d) {
  const [label, cls] = STATES[d.state] || [d.state, ''];
  const text = d.connected && !d.ready ? `${label} — جارٍ المزامنة، انتظر قليلاً` : label;
  el('badge').textContent = text;
  el('badge').className = `badge ${cls}`;
  el('stateText').textContent = d.lastError ? `${text} — ${d.lastError}` : text;
  el('phone').textContent = d.phone || '—';
  el('active').textContent = d.stats?.active ?? '—';
  el('lastHour').textContent = d.stats?.lastHour ?? '—';
  el('ttl').textContent = `${d.ttlMinutes} دقيقة`;
  renderQr(d.qr);
}

/**
 * بثّ فوري بدل الاستطلاع كل ثانيتين.
 *
 * ★ كان الاستطلاع يعرض رمز QR متأخراً حتى ثانيتين بعد جيله، ويجلب
 *   سجلّ الأحداث كاملاً (`/api/logs`) كل ثانيتين بلا داع.
 *   مع البث: الرمز يصل فور توليده، والسجلّ يُجلب كل ٥ ثوانٍ فقط.
 *   الاستطلاع يبقى خطّ أمان كل ٣٠ ثانية (لو انقطع البث).
 */
let es = null;
let logTimer = null;

function startStream() {
  if (es) es.close();
  es = new EventSource(`/api/realtime?phone=panel&roles=admin`);

  es.addEventListener('wa.qr', (e) => {
    const d = JSON.parse(e.data);
    if (d.qr) renderQr(d.qr);
    else renderQr(null);
    refreshStatus();
  });

  es.addEventListener('wa.state', () => {
    refreshStatus();
  });

  es.onerror = () => {
    // EventSource يعيد الاتصال بنفسه تلقائياً؛ نكتفي بالحالة.
    el('badge').textContent = 'انقطع البث — يعيد الاتصال…';
  };
}

async function refreshStatus() {
  try {
    const res = await fetch('/api/status');
    applyStatus(await res.json());
    loadLogs();
  } catch {}
}

loadApiKey();

startStream();
poll();
logTimer = setInterval(loadLogs, 5000);
setInterval(poll, 30000);

async function loadLogs() {
  const { data } = await call('/api/logs');
  if (!data?.logs) return;
  el('logs').innerHTML = data.logs
    .slice()
    .reverse()
    .map((l) => {
      const t = new Date(l.at).toLocaleTimeString('en-GB');
      return `<li><span>${l.message}</span><span>${t}</span></li>`;
    })
    .join('');
}

el('btnRefresh').addEventListener('click', async () => {
  el('btnRefresh').disabled = true;
  const { data } = await call('/api/qr/refresh', { method: 'POST', body: '{}' });
  if (data?.ok) lastQr = '';
  else el('stateText').textContent = `خطأ: ${data?.error ?? 'unknown'}`;
  setTimeout(() => (el('btnRefresh').disabled = false), 3000);
});

el('btnLogout').addEventListener('click', async () => {
  if (!window.confirm('هل تريد فصل الجلسة ومسح الربط؟')) return;
  await call('/api/logout', { method: 'POST', body: '{}' });
  lastQr = '';
});

const ERRORS = {
  invalid_phone: 'رقم غير صحيح، اكتبه بالصيغة الدولية.',
  phone_limit: 'تجاوزت الحد المسموح لهذا الرقم.',
  server_limit: 'تجاوزت حد الإرسال العام، انتظر قليلاً.',
  invalid_api_key: 'مفتاح الـ API غير صحيح.',
  whatsapp_not_connected: 'واتساب غير مربوط بعد — امسح رمز QR.',
  number_not_on_whatsapp: 'هذا الرقم ليس على واتساب.',
  check_timeout: 'انتهت مهلة الفحص، حاول مجدداً.',
  send_timeout: 'انتهت مهلة الإرسال، حاول مجدداً.',
  send_failed: 'رفض واتساب الرسالة (قد يكون الرقم محظوراً).',
  no_code: 'أرسل الكود أولاً أو انتهت صلاحيته.',
  expired: 'انتهت صلاحية الكود، أرسل كوداً جديداً.',
  too_many_attempts: 'محاولات خاطئة كثيرة، أرسل كوداً جديداً.',
  wrong_code: 'الكود غير صحيح.',
  missing_fields: 'أكمل الحقول.',
};

let lastPhone = '';
let tokenStore = '';

function resetLogin() {
  lastPhone = '';
  el('step2').classList.add('hidden');
  el('tokenBox').classList.add('hidden');
  el('codeInput').value = '';
  el('verifyMsg').className = 'msg';
  el('verifyMsg').textContent = '';
  el('sendMsg').className = 'msg';
  el('sendMsg').textContent = '';
  el('phoneInput').value = '';
  el('phoneInput').focus();
}

async function sendCode() {
  const msg = el('sendMsg');
  const phone = el('phoneInput').value.trim();
  msg.className = 'msg';
  msg.textContent = 'جارٍ الإرسال…';

  if (!(await loadApiKey())) {
    msg.className = 'msg err';
    msg.textContent = 'يلزم مفتاح الـ API.';
    return;
  }

  const { data } = await call('/api/auth/code', {
    method: 'POST',
    body: JSON.stringify({ phone }),
    headers: { 'Content-Type': 'application/json', ...adminHeaders(), 'x-api-key': apiKey },
  });

  if (data?.ok) {
    lastPhone = phone;
    const delivery =
      data.delivery === 'sent'
        ? 'سُلّم لواتساب.'
        : data.delivery === 'pending'
          ? 'تم الإرسال، بانتظار تأكيد واتساب.'
          : '';
    msg.className = 'msg ok';
    msg.textContent = `تم إرسال الكود إلى ${data.phone} — صالح ${data.expiresIn} ثانية. ${delivery}`;
    el('step2').classList.remove('hidden');
    el('codeInput').focus();
  } else {
    msg.className = 'msg err';
    msg.textContent =
      data?.error === 'cooldown'
        ? `انتظر ${data.retryAfter} ثانية قبل إعادة الإرسال.`
        : ERRORS[data?.error] || `خطأ: ${data?.error}`;
  }
}

el('sendForm').addEventListener('submit', (event) => {
  event.preventDefault();
  sendCode();
});

el('btnResend').addEventListener('click', () => {
  if (lastPhone) el('phoneInput').value = lastPhone;
  sendCode();
});

el('verifyForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  const msg = el('verifyMsg');
  const code = el('codeInput').value.trim();
  msg.className = 'msg';
  msg.textContent = 'جارٍ التحقق…';

  const { data } = await call('/api/auth/verify', {
    method: 'POST',
    body: JSON.stringify({ phone: lastPhone, code }),
    headers: { 'Content-Type': 'application/json', ...adminHeaders(), 'x-api-key': apiKey },
  });

  if (data?.ok) {
    msg.className = 'msg ok';
    msg.textContent = `تم تسجيل الدخول: ${data.phone}`;
    el('tokenBox').classList.remove('hidden');
    tokenStore = data.token;
    showSecret('tokenOut', data.token, '••••••••••••••••••••');
    el('codeInput').value = '';
  } else {
    msg.className = 'msg err';
    const left = data?.attemptsLeft != null ? ` (متبقٍ ${data.attemptsLeft})` : '';
    msg.textContent = (ERRORS[data?.error] || `خطأ: ${data?.error}`) + left;
    if (['no_code', 'expired', 'too_many_attempts'].includes(data?.error)) {
      el('tokenBox').classList.add('hidden');
    }
  }
});

el('codeInput').addEventListener('input', (event) => {
  event.target.value = event.target.value.replace(/\D/g, '').slice(0, 6);
});

el('btnCopy').addEventListener('click', async () => {
  const token = el('tokenOut').textContent;
  if (!token || token.startsWith('•')) {
    showSecret('tokenOut', tokenStore, '••••••••••••••••••••');
    el('btnCopy').textContent = 'الإظهار أولاً';
    setTimeout(() => (el('btnCopy').textContent = 'نسخ التوكن'), 1500);
    return;
  }
  try {
    await navigator.clipboard.writeText(token);
    el('btnCopy').textContent = 'تم النسخ';
    setTimeout(() => (el('btnCopy').textContent = 'نسخ التوكن'), 1500);
  } catch {
    el('btnCopy').textContent = 'انسخ يدوياً';
  }
});

el('tokenOutToggle').addEventListener('click', () => {
  const shown = !el('tokenOut').classList.contains('masked');
  if (shown) {
    hideSecret('tokenOut', '••••••••••••••••••••');
  } else {
    showSecret('tokenOut', tokenStore, '••••••••••••••••••••');
  }
});

el('keyOutToggle').addEventListener('click', () => {
  const shown = !el('keyOut').classList.contains('masked');
  if (shown) {
    hideSecret('keyOut', '••••••••••••••••••••');
  } else if (apiKey) {
    showSecret('keyOut', apiKey, '••••••••••••••••••••');
  }
});

el('btnNewLogin').addEventListener('click', () => {
  resetLogin();
  tokenStore = '';
  el('tokenOut').textContent = '••••••••••••••••••••';
  el('tokenOut').classList.add('masked');
});

el('btnKey').addEventListener('click', async () => {
  const out = el('keyOut');
  if (out.classList.contains('masked')) {
    if (await loadApiKey()) {
      showSecret('keyOut', apiKey, '••••••••••••••••••••');
    } else {
      out.textContent = 'المفتاح في ملف data/keys.json على السيرفر.';
    }
  } else {
    hideSecret('keyOut', '••••••••••••••••••••');
  }
});

// ★ التهيئة في أعلى الملف (startStream + poll + logTimer).
//   التكرار هنا كان يعيد فتح بثّ ثانٍ ويضاعف الاستطلاع.
