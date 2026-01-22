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

# Resolve server address if it's a domain
SERVER_IP="${SERVER_ADDRESS}"
if ! echo "${SERVER_ADDRESS}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Resolving ${SERVER_ADDRESS}..."
    SERVER_IP=$(dig +short "${SERVER_ADDRESS}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    if [ -z "${SERVER_IP}" ]; then
        echo "ERROR: Failed to resolve ${SERVER_ADDRESS}"
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

# Route DNS servers from /etc/resolv.conf bypassing tunnel
echo "Reading DNS servers from /etc/resolv.conf..."
grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | while read DNS_IP; do
    if echo "${DNS_IP}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Adding DNS ${DNS_IP} to tunnel bypass"
        ip route add ${DNS_IP}/32 via ${GATEWAY} dev ${IFACE} 2>/dev/null || true
    fi
done

# Change default route to tunnel
echo "Setting default route via ${TUN_NAME}..."
ip route del default 2>/dev/null || true
ip route add default via ${TUN_GW} dev ${TUN_NAME}

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
