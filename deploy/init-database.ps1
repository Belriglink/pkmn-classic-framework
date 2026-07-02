# ============================================================
# Initialize GTS Database Schema
# Run on the ECS instance (requires mysql client or MySQL Workbench)
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$RdsHost,
    [string]$RdsPort = "3306",
    [Parameter(Mandatory=$true)]
    [string]$Database = "gts",
    [Parameter(Mandatory=$true)]
    [string]$Username,
    [Parameter(Mandatory=$true)]
    [string]$Password,
    [string]$SqlFile = "C:\GTS\database.sql"
)

$ErrorActionPreference = "Stop"

Write-Host "`n[*] Initializing GTS database schema..." -ForegroundColor Cyan

if (-not (Test-Path $SqlFile)) {
    Write-Error "SQL file not found: $SqlFile"
    Write-Host "  Copy database.sql from the library/ folder to: $SqlFile" -ForegroundColor Yellow
    exit 1
}

# Try mysql client
$mysql = Get-Command mysql -ErrorAction SilentlyContinue
if ($mysql) {
    Write-Host "[*] Using mysql client to import schema..."
    Get-Content $SqlFile -Raw | & mysql -h $RdsHost -P $RdsPort -u $Username -p$Password $Database
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Database schema imported successfully." -ForegroundColor Green
    } else {
        Write-Error "Failed to import schema. Exit code: $LASTEXITCODE"
    }
} else {
    Write-Host "[!]  mysql client not found. Alternatives:" -ForegroundColor Yellow
    Write-Host "  1. Install MySQL Workbench and run the SQL file manually" -ForegroundColor Yellow
    Write-Host "  2. Use DMS (Data Management Service) in Alibaba Cloud console" -ForegroundColor Yellow
    Write-Host "  3. Install mysql client: choco install mysql-cli (if chocolatey installed)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  SQL file location: $SqlFile" -ForegroundColor Yellow
    Write-Host "  Target database:  $Database on ${RdsHost}:${RdsPort}" -ForegroundColor Yellow
}
