#!/bin/bash
echo "=== 1) qrlogn env var NAMES ==="
sed -n 's/^\([A-Z_][A-Z_0-9]*\)=.*/\1/p' /opt/qrlogn/.env 2>/dev/null | tr '\n' ' '
echo
echo "=== 2) session file count ==="
ls /opt/qrlogn/data/session 2>/dev/null | wc -l
echo "=== 3) creds.json first byte ==="
if [ -f /opt/qrlogn/data/session/creds.json ]; then
  od -An -tx1 -N1 /opt/qrlogn/data/session/creds.json | tr -d ' '
else
  echo "MISSING"
fi
echo "=== 4) qrlogn src files present ==="
ls /opt/qrlogn/src/ 2>/dev/null | tr '\n' ' '
echo
echo "=== 5) nginx sites ==="
ls /etc/nginx/sites-enabled/ 2>/dev/null | tr '\n' ' '
echo
echo "=== 6) listening ports ==="
ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sort -u | tr '\n' ' '
echo
echo "=== 7) disk free ==="
df -h / | tail -1
echo "=== 8) qrlogn pm2 cwd ==="
pm2 describe wa 2>/dev/null | grep -E "script path|exec cwd" 
echo "=== 9) keys.json exists? ==="
ls -la /opt/qrlogn/data/keys*.json 2>/dev/null || echo "none"
