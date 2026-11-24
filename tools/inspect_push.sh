#!/bin/bash
echo "=== push-worker env var NAMES ==="
for f in /opt/push-worker/.env /opt/push-worker/functions/push-worker/.env /root/.env; do
  if [ -f "$f" ]; then echo "--- $f"; sed -n 's/^\([A-Z_][A-Z_0-9]*\)=.*/\1/p' "$f" | tr '\n' ' '; echo; fi
done
echo "=== search for service role key anywhere readable ==="
grep -rls "service_role" /opt /root 2>/dev/null | head -5
echo "=== does push-worker have a supabase url? ==="
grep -rhoE "https://[a-z]+\.supabase\.co" /opt/push-worker /root 2>/dev/null | sort -u | head -3
echo "=== push-api (port 3001) location ==="
pm2 describe push-api 2>/dev/null | grep -E "script path|exec cwd"
echo "=== nginx qrlogn site ==="
cat /etc/nginx/sites-enabled/qrlogn
