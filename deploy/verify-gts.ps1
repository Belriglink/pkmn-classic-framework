# ============================================================
# GTS Deployment Verification Script
# Run on the ECS instance after deployment
# ============================================================

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor White
Write-Host "  GTS Deployment Verification" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

$allOk = $true

# --- 1. Check .NET Framework 3.5 ---
Write-Host "`n[1] .NET Framework 3.5" -ForegroundColor Cyan
$net35 = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction SilentlyContinue
if ($net35 -and $net35.InstallState -eq 'Installed') {
    Write-Host "  [OK] .NET 3.5 installed" -ForegroundColor Green
} else {
    Write-Host "  [X]  .NET 3.5 NOT installed" -ForegroundColor Red
    $allOk = $false
}

# --- 2. Check .NET Framework 4.0 ---
Write-Host "`n[2] .NET Framework 4.0+" -ForegroundColor Cyan
$net4Key = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
if (Test-Path $net4Key) {
    $release = (Get-ItemProperty $net4Key -Name Release -ErrorAction SilentlyContinue).Release
    if ($release -ge 378389) {
        Write-Host "  [OK] .NET 4.x installed (Release: $release)" -ForegroundColor Green
    } else {
        Write-Host "  [!]  .NET 4.0 found but old version" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [X]  .NET 4.0 NOT installed" -ForegroundColor Red
    $allOk = $false
}

# --- 3. Check SSLv3/RC4 Registry ---
Write-Host "`n[3] SSLv3/RC4 Registry Settings" -ForegroundColor Cyan
$ssl3Key = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Server"
if (Test-Path $ssl3Key) {
    $enabled = (Get-ItemProperty $ssl3Key -Name Enabled -ErrorAction SilentlyContinue).Enabled
    if ($enabled -eq -1 -or $enabled -eq 4294967295) {
        Write-Host "  [OK] SSL 3.0 Server enabled" -ForegroundColor Green
    } else {
        Write-Host "  [!]  SSL 3.0 Server Enabled = $enabled (expected 0xffffffff)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [X]  SSL 3.0 registry key not found - reboot may be needed" -ForegroundColor Red
    $allOk = $false
}

$rc4Key = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\RC4 128/128"
if (Test-Path $rc4Key) {
    Write-Host "  [OK] RC4 128/128 cipher configured" -ForegroundColor Green
} else {
    Write-Host "  [X]  RC4 cipher registry key not found" -ForegroundColor Red
    $allOk = $false
}

# --- 4. Check GTS Service ---
Write-Host "`n[4] GTS Windows Service" -ForegroundColor Cyan
$svc = Get-Service -Name "GlobalTerminalService" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "  Status   : $($svc.Status)" -ForegroundColor $(if($svc.Status -eq 'Running'){'Green'}else{'Yellow'})
    Write-Host "  StartType: $($svc.StartType)"
    if ($svc.Status -ne 'Running') { $allOk = $false }
} else {
    Write-Host "  [X]  Service not installed" -ForegroundColor Red
    $allOk = $false
}

# --- 5. Check Port Listeners ---
Write-Host "`n[5] Port Listeners" -ForegroundColor Cyan
foreach ($port in @(12400, 12401)) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "  [OK] Port $port is listening" -ForegroundColor Green
    } else {
        Write-Host "  [X]  Port $port is NOT listening" -ForegroundColor Red
        $allOk = $false
    }
}

# --- 6. Check Firewall Rules ---
Write-Host "`n[6] Firewall Rules" -ForegroundColor Cyan
foreach ($port in @(12400, 12401)) {
    $gen = if ($port -eq 12400) { "Gen4" } else { "Gen5" }
    $rule = Get-NetFirewallRule -DisplayName "GTS $gen ($port)" -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq $true) {
        Write-Host "  [OK] Firewall rule for $gen ($port)" -ForegroundColor Green
    } else {
        Write-Host "  [!]  Firewall rule for $gen ($port) missing or disabled" -ForegroundColor Yellow
    }
}

# --- 7. Check GTS Files ---
Write-Host "`n[7] GTS Files" -ForegroundColor Cyan
$installPath = "C:\GTS\GlobalTerminalService"
$requiredFiles = @(
    "GlobalTerminalService.exe",
    "GlobalTerminalService.exe.config",
    "cert.pfx",
    "PkmnFoundations.Library.dll",
    "MySql.Data.dll"
)
foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $installPath $file
    if (Test-Path $fullPath) {
        Write-Host "  [OK] $file" -ForegroundColor Green
    } else {
        Write-Host "  [X]  $file MISSING" -ForegroundColor Red
        $allOk = $false
    }
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor White
if ($allOk) {
    Write-Host "  ALL CHECKS PASSED" -ForegroundColor Green
} else {
    Write-Host "  SOME CHECKS FAILED - see above" -ForegroundColor Red
}
Write-Host "========================================`n" -ForegroundColor White

# --- Recent Event Log ---
Write-Host "Recent GTS Event Log entries:" -ForegroundColor Cyan
try {
    $events = Get-EventLog -LogName Application -Source "Global Terminal Service" -Newest 5 -ErrorAction SilentlyContinue
    if ($events) {
        foreach ($e in $events) {
            $color = switch ($e.EntryType) {
                'Error' { 'Red' }
                'Warning' { 'Yellow' }
                default { 'Gray' }
            }
            Write-Host "  [$($e.TimeGenerated)] [$($e.EntryType)] $($e.Message.Substring(0, [Math]::Min(100, $e.Message.Length)))" -ForegroundColor $color
        }
    } else {
        Write-Host "  No GTS event log entries found." -ForegroundColor Gray
    }
} catch {
    Write-Host "  Could not read event log." -ForegroundColor Gray
}
Write-Host ""
