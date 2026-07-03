#!/bin/bash
# ============================================================
# AdGuard Home 自动化部署脚本 for Nintendo WFC GTS
# 支持: Ubuntu/Debian 和 CentOS/Alibaba Cloud Linux
# GTS Server: 101.132.168.11
# ============================================================

set -e

GTS_PUBLIC_IP="101.132.168.11"
KAERU_DNS="178.62.43.212"

echo "=========================================="
echo "  AdGuard Home DNS Server Deploy"
echo "  GTS Backend:  $GTS_PUBLIC_IP"
echo "  Auth Backend: $KAERU_DNS (Kaeru WFC)"
echo "=========================================="

# === 1. 检测系统并安装依赖 ===
echo "[1/7] Detecting OS and installing dependencies..."

if command -v apt-get &> /dev/null; then
    OS_TYPE="debian"
    echo "      OS: Debian/Ubuntu"
    apt-get update -qq
    apt-get install -y -qq curl bind9-dnsutils
elif command -v yum &> /dev/null; then
    OS_TYPE="centos"
    echo "      OS: CentOS/Alibaba Cloud Linux"
    yum install -y -q curl bind-utils
else
    echo "[ERROR] Unsupported OS"
    exit 1
fi

# 检查 Python3（用于修改 JSON 配置）
if ! command -v python3 &> /dev/null; then
    echo "      Installing python3..."
    if [ "$OS_TYPE" = "debian" ]; then
        apt-get install -y -qq python3
    else
        yum install -y -q python3
    fi
fi
echo "      [OK] Dependencies installed"

# === 2. 安装 AdGuard Home ===
echo "[2/7] Installing AdGuard Home..."
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

echo "      Waiting for AdGuard Home to start..."
sleep 5
echo "      [OK] AdGuard Home installed"

# === 3. 停止服务以便修改配置 ===
echo "[3/7] Stopping AdGuard Home for configuration..."
systemctl stop AdGuardHome
echo "      [OK] Service stopped"

# === 4. 配置 DNS 规则 ===
echo "[4/7] Configuring Nintendo WFC DNS rules..."

CONFIG_FILE="/opt/AdGuardHome/data/config.json"

python3 << PYEOF
import json

with open("$CONFIG_FILE", "r") as f:
    config = json.load(f)

config["dns"]["rewrites"] = [
    {"domain": "gamestats2.gs.nintendowifi.net", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "gamestats.gs.nintendowifi.net", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "pkgdsprod.nintendo.co.jp", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "en-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "de-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "es-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "fr-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "it-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "ko-ds.pokemon-gl.com", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "pkvldtprod.nintendo.co.jp", "answer": "$GTS_PUBLIC_IP"},
    {"domain": "nas.nintendowifi.net", "answer": "$KAERU_DNS"},
    {"domain": "naswii.nintendowifi.net", "answer": "$KAERU_DNS"},
    {"domain": "conntest.nintendowifi.net", "answer": "69.25.139.140"},
]

config["dns"]["upstream_dns"] = ["$KAERU_DNS", "8.8.8.8", "1.1.1.1"]

with open("$CONFIG_FILE", "w") as f:
    json.dump(config, f, indent=2)

print("      [OK] DNS rules configured")
PYEOF

# === 5. 配置防火墙 ===
echo "[5/7] Configuring firewall..."

if command -v ufw &> /dev/null; then
    ufw allow 53/udp comment "DNS UDP"
    ufw allow 53/tcp comment "DNS TCP"
    ufw allow 3000/tcp comment "AdGuard Web UI"
    ufw reload
elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=53/udp
    firewall-cmd --permanent --add-port=53/tcp
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --reload
else
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
fi
echo "      [OK] Firewall configured"

# === 6. 启动服务 ===
echo "[6/7] Starting AdGuard Home..."
systemctl restart AdGuardHome
systemctl enable AdGuardHome
sleep 3
echo "      [OK] Service started"

# === 7. 验证 ===
echo "[7/7] Running health checks..."

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  DNS Server IP:       $PUBLIC_IP"
echo "  DNS Port:            53 (UDP/TCP)"
echo "  Web UI:              http://$PUBLIC_IP:3000"
echo ""
echo "  GTS Backend:         $GTS_PUBLIC_IP"
echo "  Auth Backend:        $KAERU_DNS (Kaeru WFC)"
echo ""
echo "=========================================="
echo "  DNS Resolution Tests"
echo "=========================================="

PASS=0
FAIL=0

test_dns() {
    local domain=$1
    local expected=$2
    local result
    result=$(dig +short @127.0.0.1 "$domain" A 2>/dev/null | head -1)
    if [ "$result" = "$expected" ]; then
        echo "  [PASS] $domain -> $result"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $domain -> $result (expected: $expected)"
        FAIL=$((FAIL + 1))
    fi
}

test_dns "gamestats2.gs.nintendowifi.net" "$GTS_PUBLIC_IP"
test_dns "gamestats.gs.nintendowifi.net" "$GTS_PUBLIC_IP"
test_dns "pkgdsprod.nintendo.co.jp" "$GTS_PUBLIC_IP"
test_dns "ds.pokemon-gl.com" "$GTS_PUBLIC_IP"
test_dns "nas.nintendowifi.net" "$KAERU_DNS"
test_dns "naswii.nintendowifi.net" "$KAERU_DNS"

echo ""
echo "  Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "[WARNING] Some tests failed. Check configuration."
    exit 1
fi

echo ""
echo "=========================================="
echo "  ALIBABA CLOUD SECURITY GROUP"
echo "=========================================="
echo "  Open these ports in security group:"
echo "    - UDP 53    (DNS queries)"
echo "    - TCP 53    (DNS fallback)"
echo "    - TCP 3000  (Web UI, optional)"
echo ""
echo "  NDS Primary DNS:  $PUBLIC_IP"
echo "  NDS Secondary DNS: 0.0.0.0"
echo "=========================================="
