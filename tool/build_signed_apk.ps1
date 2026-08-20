[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$VersionName,
  [Parameter(Mandatory = $true)]
  [int]$BuildNumber
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

if ($BuildNumber -lt 1) {
  throw 'BuildNumber must be a positive integer.'
}

$keyProperties = Join-Path $projectRoot 'android\key.properties'
if (-not (Test-Path -LiteralPath $keyProperties)) {
  throw 'android/key.properties is missing. Create it locally; never commit signing credentials.'
}

flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

flutter build apk --release --build-name=$VersionName --build-number=$BuildNumber
if ($LASTEXITCODE -ne 0) { throw 'Release APK build failed.' }

$apk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
  throw 'Flutter reported success but app-release.apk was not found.'
}

$file = Get-Item -LiteralPath $apk
$hash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash
Write-Host "APK: $($file.FullName)" -ForegroundColor Green
Write-Host "Size: $($file.Length) bytes"
Write-Host "Modified: $($file.LastWriteTime)"
Write-Host "SHA-256: $hash"
