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
#
# XHTTP_PATH: xHTTP request path (default: /)
# XHTTP_MODE: xHTTP transport mode (default: auto)
# XHTTP_HOST: xHTTP Host header (default: SNI)
# LOG_LEVEL: Xray log level (default: warning)

IFS=',' read -ra _SERVERS_RAW <<< "${SERVER_ADDRESS}"
IFS=',' read -ra _PORTS_RAW   <<< "${SERVER_PORT:-443}"
declare -a SERVERS PORTS
for s in "${_SERVERS_RAW[@]}"; do SERVERS+=("$(echo "$s" | tr -d ' ')"); done
for p in "${_PORTS_RAW[@]}";   do PORTS+=("$(echo "$p" | tr -d ' ')"); done
NUM_SERVERS=${#SERVERS[@]}
DEFAULT_PORT="${PORTS[0]:-443}"

# xHTTP settings
XHTTP_PATH="${XHTTP_PATH:-/}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
XHTTP_HOST="${XHTTP_HOST:-${SNI}}"

# HEV settings
HEV_LOG="${HEV_LOG:-warn}"

# REALITY debug logging; defaults to disabled
REALITY_SHOW="${REALITY_SHOW:-false}"

echo "=== xray-mikrotik-xhttp container ==="
echo "Servers (${NUM_SERVERS}):"
for i in "${!SERVERS[@]}"; do
    printf '  %d) %s:%s\n' "$((i+1))" "${SERVERS[$i]}" "${PORTS[$i]:-$DEFAULT_PORT}"
done
echo "SNI: ${SNI}"
echo "xHTTP host: ${XHTTP_HOST}"
echo "xHTTP mode: ${XHTTP_MODE}"
echo "xHTTP path: ${XHTTP_PATH}"
echo "Log level: ${LOG_LEVEL:-warning}"
echo "HEV Log: ${HEV_LOG}"
echo "Reality Log: ${REALITY_SHOW}"
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
            -H "accept: application/dns-json" 2>/dev/null \
            | tr ',' '\n' \
            | sed -n 's/.*"data":"\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)".*/\1/p' \
            | head -1)
        if [ -n "$result" ]; then
            echo "Resolved via ${doh_server}" >&2
            echo "$result"
            return 0
        fi
    done
    echo "DoH failed, trying system resolver..." >&2
    nslookup "$domain" 2>/dev/null | awk '
        /^Name:/   { found=1; next }
        found && /^Address/ {
            ip = $NF; sub(/:.*/, "", ip)
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print ip; exit }
        }'
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
        "xhttpSettings": {
          "host": "${XHTTP_HOST}",
          "mode": "${XHTTP_MODE}",
          "path": "${XHTTP_PATH}",
          "extra": {
            "mode": "${XHTTP_MODE}",
            "xPaddingBytes": "100-1000",
            "xmux": {
              "cMaxReuseTimes": "0",
              "hMaxRequestTimes": "600-900",
              "hMaxReusableSecs": "1800-3000",
              "maxConnections": "3"
            }
          }
        },
        "realitySettings": {
          "show": ${REALITY_SHOW},
          "fingerprint": "${FP:-firefox}",
          "password": "${PBK}",
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

echo "Generated xray config:"
cat "${CONFIG_FILE}"
echo ""

# Routing setup (host networking)
GATEWAY=$(ip route | grep default | head -1 | awk '{print $3}')
IFACE=$(ip route | grep default | head -1 | awk '{print $5}')
echo "Default gateway: ${GATEWAY}"
echo "Default interface: ${IFACE}"

TUN_NAME="tun0"
TUN_ADDR="172.31.200.10"

# Bypass routes for ALL servers (each /32 via host gateway, never via tunnel)
for srv_ip in "${SERVER_IPS[@]}"; do
    echo "Adding bypass route ${srv_ip}/32 via ${GATEWAY}..."
    ip route add "${srv_ip}/32" via "${GATEWAY}" dev "${IFACE}" 2>/dev/null || true
done

# Bypass routes for DoH servers
for DOH_IP in ${DOH_SERVERS}; do
    ip route add "${DOH_IP}/32" via "${GATEWAY}" dev "${IFACE}" 2>/dev/null || true
done

echo "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Drop the eth0 default BEFORE starting the tunnel: if it fails to come up,
# forwarded client traffic must blackhole (fail closed), not leak via ISP.
# Bypass /32 routes above keep server/DoH reachability intact.
echo "Removing default route via ${IFACE}..."
ip route del default 2>/dev/null || true

# hev-socks5-tunnel creates and configures the tun device itself.
# socks5.udp='udp' = standard SOCKS5 UDP ASSOCIATE (xray socks inbound
# supports it); do NOT set 'tcp' — that needs hev-socks5-server on the far end.
HEV_CONFIG="${CONFIG_DIR}/hev-tunnel.yaml"
cat > "${HEV_CONFIG}" <<HEVEOF
tunnel:
  name: ${TUN_NAME}
  mtu: 8500
  icmp: 'reply'
  ipv4: ${TUN_ADDR}
socks5:
  address: 127.0.0.1
  port: 10800
  udp: 'udp'
misc:
  log-file: stderr
  log-level: ${HEV_LOG}
HEVEOF

echo ""
echo "Starting hev-socks5-tunnel..."
/usr/local/bin/hev-socks5-tunnel "${HEV_CONFIG}" &
TUNNEL_PID=$!

# Wait for the tun device to come up, then move the default route onto it
for i in $(seq 1 30); do
    ip link show ${TUN_NAME} >/dev/null 2>&1 && break
    kill -0 ${TUNNEL_PID} 2>/dev/null || { echo "ERROR: hev-socks5-tunnel died on startup" >&2; exit 1; }
    sleep 0.5
done
if ! ip link show ${TUN_NAME} >/dev/null 2>&1; then
    echo "ERROR: ${TUN_NAME} did not appear within 15s" >&2
    exit 1
fi
echo "hev-socks5-tunnel started with PID ${TUNNEL_PID}"

echo "Setting default route via ${TUN_NAME}..."
ip link set ${TUN_NAME} up
ip route add default dev ${TUN_NAME}

echo "Routing table:"
ip route

echo ""
echo "Starting xray..."
/usr/local/bin/xray run -config "${CONFIG_FILE}" &
XRAY_PID=$!

echo ""
echo "=== Container ready ==="

# Supervise both processes: hev-socks5-tunnel runs in the background, so its
# death would otherwise leave a "running" container with a dead tunnel. If
# either process exits, stop the container so RouterOS auto-restart
# (auto-restart-interval on the container) brings the whole stack back up.
trap 'kill ${TUNNEL_PID} ${XRAY_PID} 2>/dev/null; exit 0' TERM INT
wait -n ${TUNNEL_PID} ${XRAY_PID}
rc=$?
echo "ERROR: xray or hev-socks5-tunnel exited (rc=${rc}), stopping container" >&2
kill ${TUNNEL_PID} ${XRAY_PID} 2>/dev/null
exit 1
