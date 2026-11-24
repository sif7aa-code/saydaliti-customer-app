# Build the size-optimized release packages (PowerShell).
#
#   .\tools\build_apk.ps1              -> 3 split APKs (one per CPU arch)
#   .\tools\build_apk.ps1 -Arm64Only   -> single arm64 APK (most devices)
#   .\tools\build_apk.ps1 -Bundle      -> App Bundle for Google Play
#   .\tools\build_apk.ps1 -NoObfuscate -> skip Dart obfuscation
#
# The script REFUSES to report sizes unless the build really produced fresh
# files, so a failed build can never be mistaken for a successful one.

param(
  [switch]$Arm64Only,
  [switch]$Bundle,
  [switch]$NoObfuscate
)

# Native tools (flutter/gradle) write warnings to stderr, so stderr must not
# be treated as terminating. We check $LASTEXITCODE and file freshness instead.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# NOTE: flags only. The subcommand is written explicitly below, so 'build'
# and 'apk' must NOT be in this list.
$flags = @('--release')
if (-not $NoObfuscate) {
  $flags += '--obfuscate'
  # forward slashes: with a backslash flutter parses it as separate args.
  $flags += '--split-debug-info=build/symbols'
}

New-Item -ItemType Directory -Force -Path 'build\symbols' | Out-Null

Write-Host ''
Write-Host '> fetching packages... ' -NoNewline
flutter pub get 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'FAILED'; exit 1 }
Write-Host 'done'

$stamp = Get-Date
if ($Bundle) {
  $target = 'appbundle'
  $out = 'build\app\outputs\bundle\release\app-release.aab'
} elseif ($Arm64Only) {
  $target = 'apk'
  $flags += '--target-platform'
  $flags += 'android-arm64'
  $out = 'build\app\outputs\flutter-apk\app-release.apk'
} else {
  $target = 'apk'
  $flags += '--split-per-abi'
  $out = 'build\app\outputs\flutter-apk\*.apk'
}

flutter build $target @flags
$exit = $LASTEXITCODE

$files = @(Get-ChildItem $out -ErrorAction SilentlyContinue)
$fresh = @($files | Where-Object { $_.LastWriteTime -gt $stamp.AddSeconds(-10) })

if ($exit -ne 0 -or $fresh.Count -eq 0) {
  Write-Host ''
  Write-Host 'BUILD FAILED - no new package produced.' -ForegroundColor Red
  if ($exit -ne 0) { Write-Host "  flutter exit code: $exit" -ForegroundColor Red }
  Write-Host '  Old files still on disk (do NOT ship them):' -ForegroundColor DarkYellow
  $files | ForEach-Object {
    '    {0,-40} {1,7:N2} MB  {2}' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime
  }
  exit 1
}

Write-Host ''
Write-Host '---------------- RESULT (fresh) ----------------' -ForegroundColor Cyan
$fresh | ForEach-Object {
  '  {0,-40} {1,7:N2} MB  {2}' -f $_.Name, ($_.Length / 1MB), $_.LastWriteTime.ToString('HH:mm:ss')
}

# Copy to dist/ with clear names so the user finds them easily.
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
foreach ($f in $fresh) {
  $n = $f.BaseName -replace '^app-', '' -replace '-release$', ''
  Copy-Item $f.FullName (Join-Path $dist "Strasopa-$n.apk") -Force
}

Write-Host ''
Write-Host 'dist/ (copy this to the phone):' -ForegroundColor Green
Get-ChildItem $dist -ErrorAction SilentlyContinue | ForEach-Object {
  '  {0,-36} {1,7:N2} MB' -f $_.Name, ($_.Length / 1MB)
}
Write-Host ''
Write-Host 'debug symbols: build\symbols' -ForegroundColor DarkGray
