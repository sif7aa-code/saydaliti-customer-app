# تشغيل دائم للعامل الإشعارات (Push Worker) — Windows
#
#   .\tools\start_push_worker.ps1          → تشغيل في النافذة الحالية
#   .\tools\start_push_worker.ps1 -Hidden  → تشغيل مخفي في الخلفية
#
# لماذا هذا ضروري؟
#   إشعار الجهاز المغلق لا يصل إلا من FCM، و FCM لا يُرسَل إلا من هذا
#   العامل. بلا عامل يعمل باستمرار، لا يمكن لأي تطبيق أن يوقظ تطبيقاً
#   مغلقاً. (التطبيق وحده يعرض إشعاراً إذا كان في الخلفية فقط.)

param([switch]$Hidden)

$ErrorActionPreference = 'Continue'
$tools = $PSScriptRoot
Set-Location $tools

if (-not (Test-Path (Join-Path $tools 'service-account.json'))) {
  Write-Host 'ERROR: service-account.json not found next to the script.' -ForegroundColor Red
  Write-Host 'Download it from Firebase Console > Project Settings > Service Accounts.' -ForegroundColor Yellow
  exit 1
}

if (-not (Test-Path (Join-Path $tools 'node_modules\firebase-admin'))) {
  Write-Host '> installing firebase-admin ...' -NoNewline
  npm install --silent 2>&1 | Out-Null
  Write-Host ' done'
}

Write-Host ''
Write-Host '  Push Worker - watches orders every 4 seconds' -ForegroundColor Cyan
Write-Host '  Keep this window open. Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

if ($Hidden) {
  Start-Process -FilePath 'node' -ArgumentList 'push_worker.js' `
    -WorkingDirectory $tools -WindowStyle Hidden
  Start-Sleep -Seconds 2
  Write-Host 'Started in the background (hidden).' -ForegroundColor Green
  Write-Host 'To stop it:  taskkill /IM node.exe /F' -ForegroundColor DarkGray
} else {
  node push_worker.js
}
