#!/bin/bash
# ينشئ /opt/notify/.env بمفتاح واحد مشترك مع qrlogn.
# الهدف: التطبيق لا يحتاج مفتاحاً ثانياً — نفس x-api-key الموجود اليوم.
set -euo pipefail

QRL=/opt/qrlogn/.env
OUT=/opt/notify/.env

# ★ نفس مفتاح qrlogn بالضبط. إن كان فارغاً ⇒ نولّد واحداً ونحدّث qrlogn أيضاً
#   (لأن التطبيق يحمل المفتاح في كوده، فلو تغيّر لانقطعت المصادقة).
read_key() {
  sed -n 's/^APP_API_KEY=//p' "$QRL" | head -1 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

KEY="$(read_key)"
CHANGED_QRL=0

if [ -z "$KEY" ]; then
  KEY="$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")"
  echo "APP_API_KEY كان فارغاً — وُلِّد مفتاح جديد."
  if grep -q '^APP_API_KEY=' "$QRL"; then
    sed -i "s|^APP_API_KEY=.*|APP_API_KEY=$KEY|" "$QRL"
  else
    printf '\nAPP_API_KEY=%s\n' "$KEY" >> "$QRL"
  fi
  CHANGED_QRL=1
  echo "!! حُدّث /opt/qrlogn/.env — سنطبع المفتاح في النهاية."
fi

# مفتاح Supabase: من push-worker إن وُجد (anon).
# ★ يجب استبداله بـ service_role قبل SQL_HARDEN_STAGE2.
SB="$(sed -n 's/^SUPA_ANON_KEY=//p' /opt/push-worker/.env 2>/dev/null | head -1 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -z "$SB" ]; then
  echo "!! لم يُعثر على SUPA_ANON_KEY في /opt/push-worker/.env"
fi

umask 077
cat > "$OUT" <<EOF
PORT=3002
HOST=127.0.0.1
NOTIFY_API_KEY=$KEY
SUPABASE_URL=https://rwuldrktcghnmhvepbzg.supabase.co
SUPABASE_KEY=$SB
WATCH_POLL_MS=2000
WATCH_LIMIT=60
EOF

chmod 600 "$OUT"
echo "كُتب $OUT بصلاحيات 600"
echo "KEY=$KEY"
echo "QRL_CHANGED=$CHANGED_QRL"
