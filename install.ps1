# Install blizzard-legacy-dl on Windows.
#
#   irm https://raw.githubusercontent.com/jaenster/blizzard-legacy-dl/main/install.ps1 | iex
#
# -Dir chooses where it lands (default %LOCALAPPDATA%\Programs\blizzard-legacy-dl),
# -Version pins a release instead of taking the latest.
param(
  [string]$Dir = "$env:LOCALAPPDATA\Programs\blizzard-legacy-dl",
  [string]$Version = "latest"
)
$ErrorActionPreference = "Stop"

# PROCESSOR_ARCHITECTURE reports the *process* architecture, so an x64 PowerShell emulated on
# an ARM machine would say AMD64. PROCESSOR_ARCHITEW6432 holds the real one in that case.
$native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = if ($native -eq "ARM64") { "aarch64" } else { "x86_64" }
$asset = "blizzard-legacy-dl-$arch-windows.exe"
$base = if ($Version -eq "latest") {
  "https://github.com/jaenster/blizzard-legacy-dl/releases/latest/download"
} else {
  "https://github.com/jaenster/blizzard-legacy-dl/releases/download/$Version"
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$out = Join-Path $Dir "blizzard-legacy-dl.exe"
Write-Host "downloading $asset"
Invoke-WebRequest -Uri "$base/$asset" -OutFile $out

# Check against the published SHA256SUMS when it is available.
try {
  $sums = (Invoke-WebRequest -Uri "$base/SHA256SUMS").Content
  $want = ($sums -split "`n" | Where-Object { $_ -match [regex]::Escape($asset) }) -split '\s+' | Select-Object -First 1
  if ($want) {
    $got = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLower()
    if ($want.ToLower() -ne $got) { throw "checksum mismatch for $asset" }
    Write-Host "checksum ok"
  }
} catch { Write-Host "note: could not verify checksum" }

$user = [Environment]::GetEnvironmentVariable("Path", "User")
if ($user -notlike "*$Dir*") {
  [Environment]::SetEnvironmentVariable("Path", "$user;$Dir", "User")
  Write-Host "added $Dir to your PATH; open a new terminal to pick it up"
}
Write-Host "installed $out"
