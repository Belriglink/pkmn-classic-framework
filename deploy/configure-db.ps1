# ============================================================
# Configure GTS Database Connection String
# Run as Administrator on the ECS instance
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$RdsHost,
    [Parameter(Mandatory=$true)]
    [string]$RdsPort = "3306",
    [Parameter(Mandatory=$true)]
    [string]$Database = "gts",
    [Parameter(Mandatory=$true)]
    [string]$Username,
    [Parameter(Mandatory=$true)]
    [string]$Password,
    [string]$ConfigPath = "C:\GTS\GlobalTerminalService\GlobalTerminalService.exe.config"
)

$ErrorActionPreference = "Stop"

Write-Host "`n[*] Configuring database connection string..." -ForegroundColor Cyan

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 1
}

# Build the connection string
$connString = "Server=$RdsHost;Port=$RdsPort;Database=$Database;User ID=$Username;Password=$Password;Pooling=true;charset=utf8;Allow User Variables=True"

# Load the config XML
[xml]$config = Get-Content $ConfigPath

# Find or create the connection string
$connNode = $config.configuration.connectionStrings.add | Where-Object { $_.name -eq "pkmnFoundationsConnectionString" }

if ($connNode) {
    $connNode.connectionString = $connString
    Write-Host "[OK] Updated existing connection string." -ForegroundColor Green
} else {
    $newNode = $config.CreateElement("add")
    $newNode.SetAttribute("name", "pkmnFoundationsConnectionString")
    $newNode.SetAttribute("connectionString", $connString)
    $newNode.SetAttribute("providerName", "MySql.Data.MySqlClient")
    $config.configuration.connectionStrings.AppendChild($newNode)
    Write-Host "[OK] Created new connection string." -ForegroundColor Green
}

# Save the config
$config.Save($ConfigPath)
Write-Host "[OK] Configuration saved to: $ConfigPath" -ForegroundColor Green

# Display the connection string (mask password)
$masked = $connString -replace "Password=([^;]+)", "Password=********"
Write-Host "`n  Connection String: $masked" -ForegroundColor Yellow
Write-Host ""
