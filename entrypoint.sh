#!/bin/bash
set -e

# If first argument is sh/bash/shell - run shell instead
if [ "$1" = "sh" ] || [ "$1" = "bash" ] || [ "$1" = "shell" ] || [ "$1" = "/bin/sh" ] || [ "$1" = "/bin/bash" ]; then
    exec /bin/bash
fi

CONFIG_DIR="/opt/xray/config"
CONFIG_FILE="${CONFIG_DIR}/config.json"
mkdir -p "${CONFIG_DIR}"

echo "=== xray-mikrotik-xhttp container ==="
echo "SERVER_ADDRESS: ${SERVER_ADDRESS}"
echo "SERVER_PORT: ${SERVER_PORT:-443}"
echo "SNI: ${SNI}"
echo "==="

# Resolve server address using DoH (DNS over HTTPS) to bypass DNS hijacking
# Primary: Cloudflare, Google, Quad9
# Secondary: Cloudflare, Google, Quad9 (alternate), AdGuard
DOH_SERVERS_PRIMARY="1.1.1.1 8.8.8.8 9.9.9.9"
DOH_SERVERS_SECONDARY="1.0.0.1 8.8.4.4 149.112.112.112 94.140.14.14"
DOH_SERVERS="${DOH_SERVERS_PRIMARY} ${DOH_SERVERS_SECONDARY}"

resolve_doh() {
    local domain=$1

    for doh_server in ${DOH_SERVERS}; do
        echo "Trying DoH server ${doh_server}..." >&2
        local result=$(curl -s --connect-timeout 5 "https://${doh_server}/dns-query?name=${domain}&type=A" \
            -H "accept: application/dns-json" 2>/dev/null | \
            jq -r '.Answer[] | select(.type==1) | .data' 2>/dev/null | head -1)

        if [ -n "$result" ]; then
            echo "Resolved via ${doh_server}" >&2
            echo "$result"
            return 0
        fi
    done

    # Fallback to traditional DNS
    echo "DoH failed, trying traditional DNS..." >&2
    dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# SERVER_IP env var overrides DNS resolution (use when DNS is blocked/hijacked)
if [ -n "${SERVER_IP}" ]; then
    echo "Using hardcoded SERVER_IP: ${SERVER_IP}"
elif echo "${SERVER_ADDRESS}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    SERVER_IP="${SERVER_ADDRESS}"
    echo "SERVER_ADDRESS is already IP: ${SERVER_IP}"
else
    echo "Resolving ${SERVER_ADDRESS} via DoH..."
    SERVER_IP=$(resolve_doh "${SERVER_ADDRESS}")
    if [ -z "${SERVER_IP}" ]; then
        echo "ERROR: Failed to resolve ${SERVER_ADDRESS}"
        echo "TIP: Set SERVER_IP env var to bypass DNS"
        exit 1
    fi
    echo "Resolved to: ${SERVER_IP}"
fi

# Generate xray config with xHTTP transport
cat > "${CONFIG_FILE}" << XRAYEOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}"
  },
  "inbounds": [
    {
      "port": 10800,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "vless-reality-xhttp",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_ADDRESS}",
            "port": ${SERVER_PORT:-443},
            "users": [
              {
                "id": "${ID}",
                "encryption": "${ENCRYPTION:-none}",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${SPX:-/}"
        },
        "realitySettings": {
          "fingerprint": "${FP:-firefox}",
          "serverName": "${SNI}",
          "publicKey": "${PBK}",
          "shortId": "${SID}",
          "spiderX": "${SPX:-/}"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
XRAYEOF

echo "Generated xray config:"
cat "${CONFIG_FILE}"
echo ""

# Get default gateway and interface
GATEWAY=$(ip route | grep default | head -1 | awk '{print $3}')
IFACE=$(ip route | grep default | head -1 | awk '{print $5}')

echo "Default gateway: ${GATEWAY}"
echo "Default interface: ${IFACE}"

# Setup tun interface
TUN_NAME="tun0"
TUN_ADDR="172.31.200.10/30"
TUN_GW="172.31.200.9"

echo "Setting up ${TUN_NAME}..."
ip tuntap add mode tun dev ${TUN_NAME} 2>/dev/null || true
ip addr add ${TUN_ADDR} dev ${TUN_NAME} 2>/dev/null || true
ip link set ${TUN_NAME} up

# Route to server bypassing tunnel
echo "Adding route to ${SERVER_IP} via ${GATEWAY}..."
ip route add ${SERVER_IP}/32 via ${GATEWAY} dev ${IFACE} 2>/dev/null || true

# Route DoH servers bypassing tunnel (for DNS resolution via HTTPS)
echo "Adding routes to DoH servers via ${GATEWAY}..."
for DOH_IP in ${DOH_SERVERS}; do
    echo "  Adding DoH ${DOH_IP} to tunnel bypass"
    ip route add ${DOH_IP}/32 via ${GATEWAY} dev ${IFACE} 2>/dev/null || true
done

# Change default route to tunnel
echo "Setting default route via ${TUN_NAME}..."
ip route del default 2>/dev/null || true
ip route add default via ${TUN_GW} dev ${TUN_NAME}

# Enable IP forwarding for MikroTik traffic
echo "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

echo "Routing table:"
ip route

echo ""
echo "Starting tun2socks..."
/usr/local/bin/tun2socks \
    -device ${TUN_NAME} \
    -proxy socks5://127.0.0.1:10800 \
    -interface ${IFACE} \
    -tcp-sndbuf 3m \
    -tcp-rcvbuf 3m \
    -loglevel silent &
TUN2SOCKS_PID=$!
echo "tun2socks started with PID ${TUN2SOCKS_PID}"

echo ""
echo "=== Container ready ==="
echo ""
echo "Starting xray (foreground)..."
exec /usr/local/bin/xray run -config "${CONFIG_FILE}"
