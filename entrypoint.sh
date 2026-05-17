#!/bin/bash
set -e

# If first argument is sh/bash/shell - run shell instead
if [ "$1" = "sh" ] || [ "$1" = "bash" ] || [ "$1" = "shell" ] || [ "$1" = "/bin/sh" ] || [ "$1" = "/bin/bash" ]; then
    exec /bin/bash
fi

CONFIG_DIR="/opt/xray/config"
CONFIG_FILE="${CONFIG_DIR}/config.json"
mkdir -p "${CONFIG_DIR}"

# SERVER_ADDRESS can be a comma-separated list (e.g. "1.2.3.4,5.6.7.8" or "a.tld,b.tld")
# Reality params (ID, PBK, SID, SNI, FP, SPX, ENCRYPTION) are shared across servers.
# SERVER_PORT can also be comma-separated; if shorter than SERVER_ADDRESS list,
# the first port is reused for the missing entries.
IFS=',' read -ra _SERVERS_RAW <<< "${SERVER_ADDRESS}"
IFS=',' read -ra _PORTS_RAW   <<< "${SERVER_PORT:-443}"
declare -a SERVERS PORTS
for s in "${_SERVERS_RAW[@]}"; do SERVERS+=("$(echo "$s" | tr -d ' ')"); done
for p in "${_PORTS_RAW[@]}";   do PORTS+=("$(echo   "$p" | tr -d ' ')"); done
NUM_SERVERS=${#SERVERS[@]}
DEFAULT_PORT="${PORTS[0]:-443}"

echo "=== xray-mikrotik-xhttp container ==="
echo "Servers (${NUM_SERVERS}):"
for i in "${!SERVERS[@]}"; do
    printf '  %d) %s:%s\n' "$((i+1))" "${SERVERS[$i]}" "${PORTS[$i]:-$DEFAULT_PORT}"
done
echo "SNI: ${SNI}"
echo "==="

# DoH resolvers — bypassed via host gateway so initial DNS works even if VPN down
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
    echo "DoH failed, trying traditional DNS..." >&2
    dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# Resolve each server to an IP. Result: parallel array SERVER_IPS[i]
declare -a SERVER_IPS
for i in "${!SERVERS[@]}"; do
    SRV="${SERVERS[$i]}"
    if echo "${SRV}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ip_addr="${SRV}"
        echo "[$((i+1))] ${SRV} is already IP"
    else
        echo "[$((i+1))] resolving ${SRV} via DoH..."
        ip_addr=$(resolve_doh "${SRV}")
        if [ -z "$ip_addr" ]; then
            echo "ERROR: failed to resolve ${SRV}" >&2
            exit 1
        fi
        echo "[$((i+1))] ${SRV} -> ${ip_addr}"
    fi
    SERVER_IPS+=("$ip_addr")
done

# Build outbounds JSON. One vless outbound per server, tag=proxy-1..N
build_outbounds() {
    local first=1
    for i in "${!SERVERS[@]}"; do
        local port="${PORTS[$i]:-$DEFAULT_PORT}"
        [ "$first" -eq 1 ] && first=0 || printf ','
        cat <<JSON
    {
      "tag": "proxy-$((i+1))",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVERS[$i]}",
            "port": ${port},
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
        "xhttpSettings": { "mode": "auto", "path": "${SPX:-/}" },
        "realitySettings": {
          "fingerprint": "${FP:-firefox}",
          "serverName": "${SNI}",
          "publicKey": "${PBK}",
          "shortId": "${SID}",
          "spiderX": "${SPX:-/}"
        }
      }
    }
JSON
    done
}

# Build selector list for balancer: ["proxy-1","proxy-2",...]
build_selector_list() {
    local sep=""
    printf '['
    for i in "${!SERVERS[@]}"; do
        printf '%s"proxy-%d"' "$sep" "$((i+1))"
        sep=","
    done
    printf ']'
}

# Routing & observatory differ between single-server and multi-server
if [ "${NUM_SERVERS}" -gt 1 ]; then
    SELECTOR=$(build_selector_list)
    ROUTING_AND_OBSERVATORY=$(cat <<EOJ
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [
      {
        "tag": "vless-balance",
        "selector": ${SELECTOR},
        "strategy": { "type": "${BALANCER_STRATEGY:-leastPing}" }
      }
    ],
    "rules": [
      { "type": "field", "inboundTag": ["socks-in"], "balancerTag": "vless-balance" }
    ]
  },
  "observatory": {
    "subjectSelector": ${SELECTOR},
    "probeUrl": "${OBSERVATORY_PROBE_URL:-https://www.gstatic.com/generate_204}",
    "probeInterval": "${OBSERVATORY_PROBE_INTERVAL:-60s}"
  }
EOJ
)
else
    # single-server: directly target the only outbound
    ROUTING_AND_OBSERVATORY=$(cat <<EOJ
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["socks-in"], "outboundTag": "proxy-1" }
    ]
  }
EOJ
)
fi

OUTBOUNDS_JSON=$(build_outbounds)

cat > "${CONFIG_FILE}" <<XRAYEOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10800,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "udp": true },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
${OUTBOUNDS_JSON},
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
${ROUTING_AND_OBSERVATORY}
}
XRAYEOF

# Sanity-check JSON; fail early if it's malformed
if ! jq -e . "${CONFIG_FILE}" > /dev/null; then
    echo "ERROR: generated config.json is not valid JSON:"
    cat "${CONFIG_FILE}"
    exit 1
fi

echo "Generated xray config:"
cat "${CONFIG_FILE}"
echo ""

# Routing setup (host networking)
GATEWAY=$(ip route | grep default | head -1 | awk '{print $3}')
IFACE=$(ip route | grep default | head -1 | awk '{print $5}')
echo "Default gateway: ${GATEWAY}"
echo "Default interface: ${IFACE}"

TUN_NAME="tun0"
TUN_ADDR="172.31.200.10/30"
TUN_GW="172.31.200.9"

echo "Setting up ${TUN_NAME}..."
ip tuntap add mode tun dev ${TUN_NAME} 2>/dev/null || true
ip addr add ${TUN_ADDR} dev ${TUN_NAME} 2>/dev/null || true
ip link set ${TUN_NAME} up

# Bypass routes for ALL servers (each /32 via host gateway, never via tunnel)
for srv_ip in "${SERVER_IPS[@]}"; do
    echo "Adding bypass route ${srv_ip}/32 via ${GATEWAY}..."
    ip route add "${srv_ip}/32" via "${GATEWAY}" dev "${IFACE}" 2>/dev/null || true
done

# Bypass routes for DoH servers
for DOH_IP in ${DOH_SERVERS}; do
    ip route add "${DOH_IP}/32" via "${GATEWAY}" dev "${IFACE}" 2>/dev/null || true
done

echo "Setting default route via ${TUN_NAME}..."
ip route del default 2>/dev/null || true
ip route add default via ${TUN_GW} dev ${TUN_NAME}

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
