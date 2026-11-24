# نشر مُرسِل الإشعارات على Supabase (يعمل ٢٤/٧ بلا جهازك)
#
#   1) install_cli.ps1      ← مرة واحدة: تثبيت Supabase CLI
#   2) deploy_push.ps1      ← نشر الدالة + ضبط الأسرار
#   3) ثم الصق SUPABASE_PUSH_WORKER.sql في SQL Editor
#
# ماذا يفعل هذا؟ يجعل الإشعار يصلك **والتطبيق مغلق تماماً**،
# لأن الإرسال يصير من خادم Supabase بدل جهازك الشخصي.

# =====================================================================
# 1) تثبيت Supabase CLI (مرة واحدة)
# =====================================================================
function Install-Cli {
  # 1) supabase.exe المرفق مع المشروع (يُفضَّل على npm الذي يفشل على ويندوز)
  $local = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'tools\supabase_cli\supabase.exe'
  if (Test-Path $local) {
    $bin = 'C:\Users\amjad\bin'
    if (-not (Test-Path $bin)) {
      New-Item -ItemType Directory -Path $bin -Force | Out-Null
    }
    Copy-Item $local (Join-Path $bin 'supabase.exe') -Force
    Unblock-File (Join-Path $bin 'supabase.exe') -ErrorAction SilentlyContinue
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$bin*") {
      [Environment]::SetEnvironmentVariable('Path', "$userPath;$bin", 'User')
    }
    $env:Path = "$bin;$env:Path"
    Write-Host " supabase.exe (local copy) -> $bin"
    return
  }
  # 2) المثبّت عبر Scoop إن وُجد
  if (Get-Command supabase -ErrorAction SilentlyContinue) {
    Write-Host ' already installed'
    return
  }
  # 3) تحميل مباشر (npm يفشل على ويندوز: لا يوجد ثنائي win32-x64)
  $tmp = Join-Path $env:TEMP 'supabase_dl'
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $url = 'https://github.com/supabase/cli/releases/latest/download/' +
    'supabase_windows_amd64.tar.gz'
  Write-Host '> downloading Supabase CLI ...'
  Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmp 'cli.tar.gz') -TimeoutSec 600
  tar -xzf (Join-Path $tmp 'cli.tar.gz') -C $tmp
  $bin = 'C:\Users\amjad\bin'
  if (-not (Test-Path $bin)) {
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
  }
  Copy-Item (Join-Path $tmp 'supabase.exe') (Join-Path $bin 'supabase.exe') -Force
  Unblock-File (Join-Path $bin 'supabase.exe') -ErrorAction SilentlyContinue
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  $env:Path = "$bin;$env:Path"
  Write-Host " supabase.exe -> $bin"
}

# =====================================================================
# 2) نشر الدالة + ضبط الأسرار
# =====================================================================
function Deploy-Push {
  $ErrorActionPreference = 'Continue'
  Set-Location (Split-Path -Parent $PSScriptRoot)

  $keyFile = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'tools\service-account.json'
  if (-not (Test-Path $keyFile)) {
    Write-Host 'ERROR: tools\service-account.json not found' -ForegroundColor Red
    exit 1
  }

  $sa = Get-Content $keyFile -Raw | ConvertFrom-Json
  $privateKey = $sa.private_key.Replace("`n", '\n')

  # كلمة سر **ثابتة**: تُقرأ من الملف إن وُجدت، وإلا تُولَّد وتُحفظ.
  # (لو غُيّرت كل مرة لأبطلت الإعداد الموجود في قاعدة البيانات.)
  $secretFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\push_secret.txt'
  if (Test-Path $secretFile) {
    $secret = (Get-Content $secretFile -Raw).Trim()
    Write-Host '> reusing existing PUSH_SECRET from push_secret.txt'
  } else {
    $secret = -join ((1..48) | ForEach-Object {
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[
        Get-Random -Maximum 62]
    })
    $secret | Out-File $secretFile -Encoding ASCII -NoNewline
    Write-Host '> generated a new PUSH_SECRET (saved to tools\push_secret.txt)'
  }

  # ملاحظة: `supabase link` يطلب كلمة مرور قاعدة البيانات (تفاعلي).
  # لا نحتاجه: النشر وSecrets يقبلان --project-ref مباشرةً بعد
  # `supabase login` فقط. لذا نتخطّاه حتى لا يعلق السكربت على سؤال.
  Write-Host '> (skipping interactive "supabase link")'

  Write-Host '> setting secrets ...'
  supabase secrets set --project-ref rwuldrktcghnmhvepbzg `
    "PUSH_SECRET=$secret"
  # المفتاح الخاص بصيغة سطر واحد مع \n
  $tmp = Join-Path $env:TEMP 'fb_key.txt'
  [System.IO.File]::WriteAllText($tmp, $privateKey)
  supabase secrets set --project-ref rwuldrktcghnmhvepbzg `
    "FIREBASE_PRIVATE_KEY@$tmp"
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  Write-Host '> deploying function ...'
  supabase functions deploy push-worker --project-ref rwuldrktcghnmhvepbzg `
    --no-verify-jwt

  if ($LASTEXITCODE -ne 0) {
    Write-Host 'DEPLOY FAILED — انظر الرسالة أعلاه.' -ForegroundColor Red
    exit 1
  }

  $url = 'https://rwuldrktcghnmhvepbzg.supabase.co/functions/v1/push-worker'
  Write-Host ''
  Write-Host '===========================================' -ForegroundColor Cyan
  Write-Host '  DEPLOYED. Now run this in Supabase SQL Editor:' -ForegroundColor Green
  Write-Host '===========================================' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '-- 1) install the server-push SQL (once)'
  Write-Host "     -- file: SUPABASE_PUSH_WORKER.sql"
  Write-Host ''
  Write-Host '-- 2) point the database at this function + turn it ON'
  Write-Host "select public.set_push_worker("
  Write-Host "  '$url',"
  Write-Host "  '$secret'"
  Write-Host ");"
  Write-Host ''
  Write-Host "update public.app_settings"
  Write-Host "   set value = '1' where key = 'push_worker_enabled';"
  Write-Host ''
  Write-Host '-- 3) verify it can actually reach the function'
  Write-Host '  select public.call_push_worker();'
  Write-Host '  select * from net._http_response order by id desc limit 3;'
  Write-Host ''
  Write-Host 'The secret is also saved in tools\push_secret.txt' -ForegroundColor Yellow
}

if ($args -contains 'install') { Install-Cli } else { Install-Cli; Deploy-Push }