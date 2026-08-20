[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Relink
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

$projectRefFile = Join-Path $projectRoot 'supabase\.temp\project-ref'
if (-not (Test-Path -LiteralPath $projectRefFile)) {
  throw 'No linked Supabase project was found. Run: npx.cmd --yes supabase@2.111.0 link'
}
$projectRef = (Get-Content -LiteralPath $projectRefFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($projectRef)) {
  throw 'The linked Supabase project reference is empty.'
}

function Invoke-SupabaseCli([string[]]$Arguments) {
  & npx.cmd --yes supabase@2.111.0 @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Supabase command failed: supabase $($Arguments -join ' ')"
  }
}

Write-Host "Target project: $projectRef" -ForegroundColor Cyan
Invoke-SupabaseCli @('--version')

if ($Relink) {
  Write-Host 'Supabase may ask for the database password; it is never saved by this script.' -ForegroundColor Yellow
  Invoke-SupabaseCli @('link', '--project-ref', $projectRef)
}

Write-Host 'Comparing local and remote migration history...' -ForegroundColor Cyan
Invoke-SupabaseCli @('migration', 'list', '--linked')

Write-Host 'Previewing pending migration SQL...' -ForegroundColor Cyan
Invoke-SupabaseCli @('db', 'push', '--linked', '--dry-run')

if (-not $Apply) {
  Write-Host 'Preview only. Re-run with -Apply after reviewing the output.' -ForegroundColor Yellow
  exit 0
}

$confirmation = Read-Host "Type DEPLOY $projectRef to apply these migrations"
if ($confirmation -ne "DEPLOY $projectRef") {
  throw 'Deployment cancelled. No migration was applied.'
}

Write-Host 'Applying migrations...' -ForegroundColor Yellow
Invoke-SupabaseCli @('db', 'push', '--linked', '--yes')

Write-Host 'Verifying migration history...' -ForegroundColor Cyan
Invoke-SupabaseCli @('migration', 'list', '--linked')
Write-Host 'Supabase migration deployment completed.' -ForegroundColor Green
