#!/bin/bash
# يضيف مسار SSE إلى موقع nginx الحالي دون المساس ببقية الإعدادات.
# ★ exact match (=) أعلى أولوية من location /، فيتعامل هذا المسار
#   مع خدمة notify (3002) والباقي يبقى على qrlogn (3000).
set -euo pipefail

SITE=/etc/nginx/sites-available/qrlogn
[ -f "$SITE" ] || SITE=/etc/nginx/sites-enabled/qrlogn
BAK="$SITE.bak-$(date +%Y%m%d-%H%M%S)"
cp "$SITE" "$BAK"
echo "نسخة احتياطية: $BAK"

if grep -q 'location = /api/realtime' "$SITE"; then
  echo "المسار موجود أصلاً — لا تغيير."
  exit 0
fi

BLOCK='
    # ============================================================
    #  بثّ الإشعارات الفوري (SSE) — خدمة notify على 127.0.0.1:3002
    #  ★ proxy_buffering off إلزامي: بدونه يجمع nginx الأحداث ولا
    #    تصل إلى الجهاز إلا عند إغلاق الاتصال.
    # ============================================================
    location = /api/realtime {
        proxy_pass http://127.0.0.1:3002;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # فحص صحة خدمة البثّ (بلا مصادقة، لا يسرّب شيئاً)
    location = /api/health {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
    }
'

# ندرج الكتلة قبل آخر قوس إغلاق في كتلة server
python3 - "$SITE" <<PY
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = """$BLOCK"""
i = s.rstrip().rfind('}')
s = s[:i] + block + s[i:]
open(p, 'w', encoding='utf-8').write(s)
print("أُدرجت الكتلة")
PY

nginx -t
systemctl reload nginx
echo "تم التحديث"
