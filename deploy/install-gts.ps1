# ============================================================
# GTS Deployment Script for Alibaba Cloud ECS (Windows Server)
# Run as Administrator
# ============================================================

param(
    [string]$InstallPath = "C:\GTS\GlobalTerminalService",
    [switch]$SkipReboot
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[X]  $msg" -ForegroundColor Red }

# --- Check Administrator ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "Please run this script as Administrator."
    exit 1
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host "  GTS Deployment Script" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

# ------------------------------------------------------------
# Step 1: Install .NET Framework 3.5
# ------------------------------------------------------------
Write-Step "Checking .NET Framework 3.5..."
$net35 = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue
if ($net35 -and $net35.InstallState -eq 'Installed') {
    Write-OK ".NET Framework 3.5 is already installed."
} else {
    Write-Step "Installing .NET Framework 3.5 (required by PkmnFoundations.Library)..."
    $result = DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to install .NET 3.5. Exit code: $LASTEXITCODE"
        Write-Warn "If using Windows Server 2012+, specify alternate source: DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:`"C:\sources\sxs`""
    } else {
        Write-OK ".NET Framework 3.5 installed."
    }
}

# ------------------------------------------------------------
# Step 2: Verify .NET Framework 4.0
# ------------------------------------------------------------
Write-Step "Checking .NET Framework 4.0+..."
$net4Key = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
if (Test-Path $net4Key) {
    $release = (Get-ItemProperty $net4Key -Name Release -ErrorAction SilentlyContinue).Release
    if ($release -ge 378389) {
        Write-OK ".NET Framework 4.0+ is installed (Release: $release)."
    } else {
        Write-Warn ".NET Framework 4.0 found but version may be too old."
    }
} else {
    Write-Err ".NET Framework 4.0 is NOT installed. Please install it first."
    Write-Warn "Download: https://www.microsoft.com/download/details.aspx?id=17851"
    exit 1
}

# ------------------------------------------------------------
# Step 3: Apply SSLv3/RC4 Registry Settings
# ------------------------------------------------------------
Write-Step "Applying SSLv3/RC4 registry settings..."
$regFile = Join-Path $PSScriptRoot "sslv3-rc4-enable.reg"
if (Test-Path $regFile) {
    reg import $regFile
    if ($LASTEXITCODE -eq 0) {
        Write-OK "SSLv3/RC4 registry settings applied."
    } else {
        Write-Err "Failed to import registry settings."
    }
} else {
    Write-Warn "Registry file not found: $regFile - skipping."
}

# ------------------------------------------------------------
# Step 4: Install GTS as Windows Service
# ------------------------------------------------------------
Write-Step "Installing GTS Windows Service..."

# Check if service already exists
$existingService = Get-Service -Name "GlobalTerminalService" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Warn "Service 'GlobalTerminalService' already exists. Stopping and removing..."
    if ($existingService.Status -eq 'Running') {
        Stop-Service -Name "GlobalTerminalService" -Force
        Start-Sleep -Seconds 2
    }
    sc.exe delete "GlobalTerminalService" | Out-Null
    Start-Sleep -Seconds 2
}

$exePath = Join-Path $InstallPath "GlobalTerminalService.exe"
if (-not (Test-Path $exePath)) {
    Write-Err "GlobalTerminalService.exe not found at: $exePath"
    Write-Warn "Make sure the compiled binaries are uploaded to $InstallPath"
    exit 1
}

# Install using installutil (via the framework)
$installUtil = Get-ChildItem "C:\Windows\Microsoft.NET\Framework\v4.0*\installutil.exe" | Select-Object -Last 1
if ($installUtil) {
    & $installUtil.FullName $exePath
} else {
    # Alternative: use the exe's own install command
    & $exePath install
}

if ($LASTEXITCODE -eq 0 -or $?) {
    Write-OK "GTS service installed."
} else {
    Write-Err "Service installation may have failed. Check output above."
}

# ------------------------------------------------------------
# Step 5: Configure Firewall
# ------------------------------------------------------------
Write-Step "Configuring Windows Firewall..."

# GTS Gen4 port 12400 (TCP, no SSL)
$rule1 = Get-NetFirewallRule -DisplayName "GTS Gen4 (12400)" -ErrorAction SilentlyContinue
if (-not $rule1) {
    New-NetFirewallRule -DisplayName "GTS Gen4 (12400)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 12400 | Out-Null
    Write-OK "Firewall rule added for port 12400 (Gen4)."
} else {
    Write-OK "Firewall rule for port 12400 already exists."
}

# GTS Gen5 port 12401 (TCP, SSL)
$rule2 = Get-NetFirewallRule -DisplayName "GTS Gen5 (12401)" -ErrorAction SilentlyContinue
if (-not $rule2) {
    New-NetFirewallRule -DisplayName "GTS Gen5 (12401)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 12401 | Out-Null
    Write-OK "Firewall rule added for port 12401 (Gen5)."
} else {
    Write-OK "Firewall rule for port 12401 already exists."
}

# ------------------------------------------------------------
# Step 6: Start Service
# ------------------------------------------------------------
Write-Step "Starting GTS service..."
try {
    Start-Service -Name "GlobalTerminalService" -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "GlobalTerminalService"
    if ($svc.Status -eq 'Running') {
        Write-OK "GTS service is running!"
    } else {
        Write-Warn "Service status: $($svc.Status)"
    }
} catch {
    Write-Err "Failed to start service: $($_.Exception.Message)"
    Write-Warn "Check Event Viewer -> Windows Logs -> Application for error details."
}

# ------------------------------------------------------------
# Step 7: Verify
# ------------------------------------------------------------
Write-Step "Verifying deployment..."

# Check service
$svc = Get-Service -Name "GlobalTerminalService" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Service Status : $($svc.Status)"
    Write-Host "  Start Type     : $($svc.StartType)"
} else {
    Write-Err "Service not found!"
}

# Check ports
Write-Step "Checking port listeners..."
$ports = @(12400, 12401)
foreach ($port in $ports) {
    $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listening) {
        Write-OK "Port $port is listening."
    } else {
        Write-Warn "Port $port is NOT listening yet."
    }
}

# ------------------------------------------------------------
# Reboot notice
# ------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor White
Write-Host "  Deployment Summary" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

if (-not $SkipReboot) {
    $sslKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Server"
    if (Test-Path $sslKey) {
        Write-Warn "SSLv3/RC4 registry changes require a REBOOT to take effect."
        Write-Host "  Run: Restart-Computer -Force" -ForegroundColor Yellow
        Write-Host "  Or re-run this script with -SkipReboot after rebooting." -ForegroundColor Yellow
    }
}

Write-Host "`nDone. Check Event Viewer for GTS logs." -ForegroundColor Green
Write-Host "Event Viewer -> Windows Logs -> Application -> Source: Global Terminal Service`n" -ForegroundColor Green
