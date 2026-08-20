[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SupabaseUrl,
  [Parameter(Mandatory = $true)]
  [string]$SupabaseAnonKey,
  [Parameter(Mandatory = $true)]
  [string]$VersionName,
  [Parameter(Mandatory = $true)]
  [int]$BuildNumber,
  [Parameter(Mandatory = $true)]
  [int]$MinimumSupportedBuildNumber,
  [Parameter(Mandatory = $true)]
  [string]$ReleaseNotes,
  [switch]$Mandatory
)

$ErrorActionPreference = 'Stop'
if ($BuildNumber -lt 1 -or $MinimumSupportedBuildNumber -lt 1) {
  throw 'Build numbers must be positive integers.'
}
if ($MinimumSupportedBuildNumber -gt $BuildNumber) {
  throw 'MinimumSupportedBuildNumber cannot exceed BuildNumber.'
}
if ([string]::IsNullOrWhiteSpace($env:RELEASE_PUBLISH_TOKEN)) {
  throw 'Set RELEASE_PUBLISH_TOKEN only for this terminal session before publishing.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
  throw 'Signed app-release.apk is missing. Run tool\build_signed_apk.ps1 first.'
}

$payload = @{
  version_name = $VersionName
  version_code = $BuildNumber
  minimum_supported_version_code = $MinimumSupportedBuildNumber
  release_notes = $ReleaseNotes
  sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
  is_mandatory = [bool]$Mandatory
} | ConvertTo-Json -Compress

$endpoint = "$($SupabaseUrl.TrimEnd('/'))/functions/v1/publish-android-release"
$headers = @{
  apikey = $SupabaseAnonKey
  'x-release-publish-token' = $env:RELEASE_PUBLISH_TOKEN
}

$response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers `
  -ContentType 'application/json' -Body $payload
$response | ConvertTo-Json -Depth 8
Write-Host 'Release metadata published. Confirm the APK asset URL is already live.' -ForegroundColor Green
