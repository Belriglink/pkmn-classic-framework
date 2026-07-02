# ============================================================
# GTS Master Deployment Script - One-click deployment
# Run as Administrator on Alibaba Cloud ECS (Windows Server)
# ============================================================

param(
    [Parameter(Mandatory=$true, HelpMessage="RDS MySQL internal hostname")]
    [string]$RdsHost,
    [string]$RdsPort = "3306",
    [string]$Database = "gts",
    [Parameter(Mandatory=$true, HelpMessage="Database username")]
    [string]$Username,
    [Parameter(Mandatory=$true, HelpMessage="Database password")]
    [string]$Password,
    [string]$InstallPath = "C:\GTS\GlobalTerminalService",
    [switch]$SkipDatabaseInit,
    [switch]$SkipReboot
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($msg) { Write-Host "`n========== $msg ==========" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [X]  $msg" -ForegroundColor Red }

# --- Check Administrator ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator."
    exit 1
}

Write-Host @"
============================================
  GTS Master Deployment
  RDS Host: $RdsHost`:$RdsPort
  Database: $Database
  User:     $Username
============================================
"@ -ForegroundColor White

# ----------------------------------------------------------
# Phase 1: Install .NET Framework 3.5
# ----------------------------------------------------------
Write-Step "Phase 1: .NET Framework 3.5"
$net35 = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue
if ($net35 -and $net35.InstallState -eq 'Installed') {
    Write-OK ".NET 3.5 already installed"
} else {
    DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart
    Write-OK ".NET 3.5 installed"
}

# Verify .NET 4.0+
$net4Key = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
if (-not (Test-Path $net4Key)) {
    Write-Err ".NET Framework 4.0 is NOT installed!"
    Write-Warn "Download: https://www.microsoft.com/download/details.aspx?id=17851"
    exit 1
}
Write-OK ".NET Framework 4.0+ verified"

# ----------------------------------------------------------
# Phase 2: Copy binaries to install path
# ----------------------------------------------------------
Write-Step "Phase 2: Install GTS binaries"
$sourceBin = Join-Path $scriptDir "GlobalTerminalService"
if (-not (Test-Path $sourceBin)) {
    Write-Err "Binaries not found: $sourceBin"
    exit 1
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}
Copy-Item -Path "$sourceBin\*" -Destination $InstallPath -Force
Write-OK "Binaries copied to $InstallPath"

# ----------------------------------------------------------
# Phase 3: Configure database connection
# ----------------------------------------------------------
Write-Step "Phase 3: Configure database connection"
$configPath = Join-Path $InstallPath "GlobalTerminalService.exe.config"
& $scriptDir\configure-db.ps1 -RdsHost $RdsHost -RdsPort $RdsPort -Database $Database -Username $Username -Password $Password -ConfigPath $configPath
Write-OK "Database connection configured"

# ----------------------------------------------------------
# Phase 4: Initialize database schema (optional)
# ----------------------------------------------------------
if (-not $SkipDatabaseInit) {
    Write-Step "Phase 4: Initialize database schema"
    $sqlFile = Join-Path $scriptDir "database.sql"
    & $scriptDir\init-database.ps1 -RdsHost $RdsHost -RdsPort $RdsPort -Database $Database -Username $Username -Password $Password -SqlFile $sqlFile
}

# ----------------------------------------------------------
# Phase 5: Apply SSLv3/RC4 registry settings
# ----------------------------------------------------------
Write-Step "Phase 5: SSLv3/RC4 registry settings"
$regFile = Join-Path $scriptDir "sslv3-rc4-enable.reg"
if (Test-Path $regFile) {
    reg import $regFile
    Write-OK "SSLv3/RC4 registry applied"
} else {
    Write-Warn "Registry file not found: $regFile"
}

# ----------------------------------------------------------
# Phase 6: Install Windows Service
# ----------------------------------------------------------
Write-Step "Phase 6: Install Windows Service"

# Remove existing service if present
$existing = Get-Service -Name "GlobalTerminalService" -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Status -eq 'Running') {
        Stop-Service -Name "GlobalTerminalService" -Force
        Start-Sleep -Seconds 3
    }
    sc.exe delete "GlobalTerminalService" | Out-Null
    Start-Sleep -Seconds 2
    Write-Warn "Removed existing service"
}

$exePath = Join-Path $InstallPath "GlobalTerminalService.exe"
$installUtil = Get-ChildItem "C:\Windows\Microsoft.NET\Framework\v4.0*\installutil.exe" | Select-Object -Last 1
if ($installUtil) {
    & $installUtil.FullName $exePath
} else {
    & $exePath install
}
Write-OK "Service installed"

# ----------------------------------------------------------
# Phase 7: Configure firewall
# ----------------------------------------------------------
Write-Step "Phase 7: Configure firewall"
foreach ($port in @(12400, 12401)) {
    $gen = if ($port -eq 12400) { "Gen4" } else { "Gen5" }
    $ruleName = "GTS $gen ($port)"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port | Out-Null
        Write-OK "Firewall rule: $ruleName"
    } else {
        Write-OK "Firewall rule exists: $ruleName"
    }
}

# ----------------------------------------------------------
# Phase 8: Start service
# ----------------------------------------------------------
Write-Step "Phase 8: Start service"
Start-Sleep -Seconds 2
try {
    Start-Service -Name "GlobalTerminalService" -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "GlobalTerminalService"
    if ($svc.Status -eq 'Running') {
        Write-OK "GTS service is RUNNING"
    } else {
        Write-Warn "Service status: $($svc.Status)"
    }
} catch {
    Write-Err "Failed to start: $($_.Exception.Message)"
    Write-Warn "Check Event Viewer -> Windows Logs -> Application"
}

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
Write-Host @"
`n============================================
  Deployment Complete!
============================================
  Service:  GlobalTerminalService
  Path:     $InstallPath
  Ports:    12400 (Gen4), 12401 (Gen5 SSL)
  Database: $Database@$RdsHost`:$RdsPort
"@ -ForegroundColor White

# Check if reboot needed for SSLv3
if (-not $SkipReboot) {
    $sslKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Server"
    if (Test-Path $sslKey) {
        Write-Host "`n  [!] SSLv3/RC4 changes require a REBOOT to take effect." -ForegroundColor Yellow
        Write-Host "      Run: Restart-Computer -Force" -ForegroundColor Yellow
        Write-Host "      After reboot, verify: .\verify-gts.ps1" -ForegroundColor Yellow
    }
}

Write-Host "`n  Next steps:" -ForegroundColor Cyan
Write-Host "  1. Reboot if SSLv3 was just applied"
Write-Host "  2. Run: .\verify-gts.ps1"
Write-Host "  3. Check Event Viewer for GTS logs"
Write-Host ""
