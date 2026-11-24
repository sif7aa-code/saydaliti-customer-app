Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$files = @(
  'M:\strasopa\lib\data\mock_data.dart',
  'M:\strasopa\lib\services\cart_service.dart',
  'M:\strasopa\lib\screens\account_screen.dart'
)

$ids = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
  $c = [System.IO.File]::ReadAllText($f)
  $m = [regex]::Matches($c, 'photo-[0-9a-zA-Z-]+')
  foreach ($x in $m) {
    if (-not $ids.Contains($x.Value)) { $ids.Add($x.Value) }
  }
}
Write-Output "TOTAL_UNIQUE=$($ids.Count)"

$outDir = 'M:\strasopa\assets\images'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]72)

foreach ($id in $ids) {
  $target = Join-Path $outDir "img_$id.jpg"
  if (Test-Path $target) { Write-Output "SKIP $id"; continue }
  $url = "https://images.unsplash.com/$id`?w=900&q=75&auto=format&fit=crop"
  try {
    Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\$id.bin" -UseBasicParsing -MaximumRedirection 5 | Out-Null
    $tmp = Join-Path $env:TEMP "$id.bin"
    $src = [System.Drawing.Image]::FromFile($tmp)
    $maxW = 900
    $scale = [Math]::Min(1.0, $maxW / $src.Width)
    $w = [Math]::Max(1, [int]($src.Width * $scale))
    $h = [Math]::Max(1, [int]($src.Height * $scale))
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($src, 0, 0, $w, $h)
    $bmp.Save($target, $enc, $ep)
    $g.Dispose(); $bmp.Dispose(); $src.Dispose()
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Output "OK $id ($($w)x$h) $([math]::Round((Get-Item $target).Length/1KB,1))KB"
  } catch {
    Write-Output "FAIL $id :: $($_.Exception.Message)"
  }
}

$totalKb = (Get-ChildItem $outDir -Filter 'img_*.jpg' | Measure-Object -Property Length -Sum).Sum / 1KB
Write-Output "TOTAL_IMAGES=$((Get-ChildItem $outDir -Filter 'img_*.jpg').Count) SIZE_KB=$([math]::Round($totalKb,1))"