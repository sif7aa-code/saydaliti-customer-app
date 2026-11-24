$env:Path = "C:\Users\amjad\bin;$env:Path"
Set-Location 'M:\strasopa\tools'
Write-Host "Supabase CLI" -ForegroundColor Cyan
supabase --version
Write-Host ""
Write-Host " 1) سجّل الدخول:  supabase login" -ForegroundColor Yellow
Write-Host " 2) تأكد من مشروعك:"
Write-Host ""
$ok = $false
for ($i=0; $i -lt 400; $i++) {
  $out = supabase projects list 2>$null | Out-String
  if ($out -match 'rwuldrktcghnmhvepbzg') {
    Write-Host "  ✔ تم العثور على مشروعك rwuldrktcghnmhvepbzg" -ForegroundColor Green
    $ok = $true
    break
  }
  Start-Sleep -Seconds 3
}
if ($ok) {
  Write-Host ""
  Write-Host "  الآن لا تغلق هذه النافذة — سيُنشر المُرسِل تلقائياً." -ForegroundColor Green
  & powershell -NoProfile -ExecutionPolicy Bypass -File 'M:\strasopa\tools\deploy_push.ps1'
  Write-Host ""
  Write-Host "انتهى. هذه النافذة يمكنك إغلاقها." -ForegroundColor Cyan
} else {
  Write-Host "  لم يتم تسجيل الدخول." -ForegroundColor Red
}
