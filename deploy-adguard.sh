#!/bin/bash
# ============================================================
# AdGuard Home 自动化部署脚本 for Nintendo WFC GTS
# 支持: Ubuntu/Debian 和 CentOS/Alibaba Cloud Linux
# GTS Server: 101.132.168.11
# ============================================================

set -e

GTS_PUBLIC_IP="47.103.214.176"
KAERU_DNS="178.62.43.212"
ADMIN_USER="admin"
ADMIN_PASS="GTSadmin2024!"

echo "=========================================="
echo "  AdGuard Home DNS Server Deploy"
echo "  GTS Backend:  $GTS_PUBLIC_IP"
echo "  Auth Backend: $KAERU_DNS (Kaeru WFC)"
echo "=========================================="

# === 1. 检测系统并安装依赖 ===
echo "[1/8] Detecting OS and installing dependencies..."

if command -v apt-get &> /dev/null; then
    OS_TYPE="debian"
    echo "      OS: Debian/Ubuntu"
    apt-get update -qq
    apt-get install -y -qq curl dnsutils
elif command -v yum &> /dev/null; then
    OS_TYPE="centos"
    echo "      OS: CentOS/Alibaba Cloud Linux"
    yum install -y -q curl bind-utils
else
    echo "[ERROR] Unsupported OS"
    exit 1
fi

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
echo "[2/8] Installing AdGuard Home..."

if [ -d "/opt/AdGuardHome" ] && [ -f "/opt/AdGuardHome/AdGuardHome" ]; then
    echo "      AdGuard Home already installed, skipping..."
else
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
fi

echo "      Starting AdGuard Home..."
systemctl start AdGuardHome
sleep 5
echo "      [OK] AdGuard Home installed"

# === 3. 完成初始安装向导 ===
echo "[3/8] Running initial setup wizard..."

SETUP_DONE=false
for i in $(seq 1 10); do
    if curl -s -f http://127.0.0.1:3000/control/status > /dev/null 2>&1; then
        echo "      Already configured, skipping wizard..."
        SETUP_DONE=true
        break
    fi
    if curl -s -X POST http://127.0.0.1:3000/control/install/configure \
        -H "Content-Type: application/json" \
        -d "{
            \"dns\": {\"bind_hosts\": [\"0.0.0.0\"], \"port\": 53},
            \"web\": {\"bind_host\": \"0.0.0.0\", \"port\": 3000},
            \"username\": \"$ADMIN_USER\",
            \"password\": \"$ADMIN_PASS\"
        }" > /dev/null 2>&1; then
        echo "      Setup wizard completed"
        SETUP_DONE=true
        sleep 5
        break
    fi
    sleep 2
done

if [ "$SETUP_DONE" = false ]; then
    echo "[ERROR] Failed to complete setup wizard"
    exit 1
fi
echo "      [OK] Initial setup done"

# === 4. 配置上游 DNS ===
echo "[4/8] Configuring upstream DNS..."

AUTH_HEADER="Authorization: Basic $(echo -n "$ADMIN_USER:$ADMIN_PASS" | base64 -w 0 2>/dev/null || echo -n "$ADMIN_USER:$ADMIN_PASS" | base64)"

python3 << PYEOF
import json, urllib.request, base64

auth = base64.b64encode(("$ADMIN_USER:$ADMIN_PASS").encode()).decode()
headers = {
    "Content-Type": "application/json",
    "Authorization": "Basic " + auth
}

# 获取当前 DNS 配置
req = urllib.request.Request("http://127.0.0.1:3000/control/dns_config", headers=headers)
with urllib.request.urlopen(req) as resp:
    config = json.loads(resp.read())

# 修改上游 DNS
config["upstream_dns"] = ["$KAERU_DNS", "8.8.8.8", "1.1.1.1"]
config["bootstrap_dns"] = ["8.8.8.8", "1.1.1.1"]

# 提交修改
data = json.dumps(config).encode()
req = urllib.request.Request("http://127.0.0.1:3000/control/dns_config", data=data, headers=headers, method="PUT")
with urllib.request.urlopen(req) as resp:
    print("      Upstream DNS configured")
PYEOF

echo "      [OK] Upstream DNS set"

# === 5. 配置 DNS rewrite 规则 ===
echo "[5/8] Configuring Nintendo WFC DNS rewrites..."

python3 << PYEOF
import json, urllib.request, base64

auth = base64.b64encode(("$ADMIN_USER:$ADMIN_PASS").encode()).decode()
headers = {
    "Content-Type": "application/json",
    "Authorization": "Basic " + auth
}

rewrites = [
    ("gamestats2.gs.nintendowifi.net", "$GTS_PUBLIC_IP"),
    ("gamestats.gs.nintendowifi.net", "$GTS_PUBLIC_IP"),
    ("pkgdsprod.nintendo.co.jp", "$GTS_PUBLIC_IP"),
    ("ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("en-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("de-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("es-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("fr-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("it-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("ko-ds.pokemon-gl.com", "$GTS_PUBLIC_IP"),
    ("pkvldtprod.nintendo.co.jp", "$GTS_PUBLIC_IP"),
    ("nas.nintendowifi.net", "$KAERU_DNS"),
    ("naswii.nintendowifi.net", "$KAERU_DNS"),
    ("conntest.nintendowifi.net", "198.62.122.140"),
]

for domain, answer in rewrites:
    data = json.dumps({"domain": domain, "answer": answer}).encode()
    req = urllib.request.Request("http://127.0.0.1:3000/control/rewrite/add", data=data, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except urllib.error.HTTPError as e:
        if e.code == 400:
            pass
        else:
            raise

print(f"      {len(rewrites)} rewrite rules added")
PYEOF

echo "      [OK] DNS rewrites configured"

# === 6. 配置防火墙 ===
echo "[6/8] Configuring firewall..."

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

# === 7. 确保服务运行 ===
echo "[7/8] Ensuring service is running..."

systemctl restart AdGuardHome
systemctl enable AdGuardHome
sleep 5
echo "      [OK] Service running"

# === 8. 验证 ===
echo "[8/8] Running health checks..."

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  DNS Server IP:       $PUBLIC_IP"
echo "  DNS Port:            53 (UDP/TCP)"
echo "  Web UI:              http://$PUBLIC_IP:3000"
echo "  Admin User:          $ADMIN_USER"
echo "  Admin Password:      $ADMIN_PASS"
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

sleep 2

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
