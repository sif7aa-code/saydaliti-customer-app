$ErrorActionPreference = 'SilentlyContinue'
Set-Location 'M:\strasopa\tools'
$log = 'M:\strasopa\tools\push_worker.log'
# إعادة تشغيل تلقائية لو توقفت
while ($true) {
  "--- تشغيل $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ---" | Out-File $log -Append -Encoding UTF8
  & node 'M:\strasopa\tools\push_worker.js' 2>&1 | Out-File $log -Append -Encoding UTF8
  Start-Sleep -Seconds 10
}
