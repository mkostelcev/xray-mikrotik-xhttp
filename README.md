# xray-mikrotik-xhttp

Docker container for MikroTik with Xray VLESS+Reality+xHTTP transport and tun2socks.

## Features

- Xray with VLESS + Reality + **xHTTP** transport (bypasses DPI that kills long-lived TCP connections)
- tun2socks for transparent proxying
- Multi-architecture support: amd64, arm64, arm/v7 (MikroTik)
- Configurable via environment variables

## Usage on MikroTik

### 1. Create veth interface

```
/interface veth add address=172.18.20.6/30 gateway=172.18.20.5 name=veth-xray
/ip address add interface=veth-xray address=172.18.20.5/30
```

### 2. Create environment variables

```
/container envs
add list=xray key=SERVER_ADDRESS value=your-server.com
add list=xray key=SERVER_PORT value=443
add list=xray key=ID value=your-uuid
add list=xray key=SNI value=www.github.com
add list=xray key=PBK value=your-public-key
add list=xray key=SID value=your-short-id
add list=xray key=SPX value=/
add list=xray key=FP value=firefox
```

### 3. Create container

```
/container add remote-image=ghcr.io/mkostelcev/xray-mikrotik-xhttp:latest interface=veth-xray envlist=xray root-dir=disk1/xray start-on-boot=yes logging=yes
```

### 4. Setup routing

```
/ip firewall nat add action=masquerade chain=srcnat src-address=172.18.20.0/30
/ip route add dst-address=0.0.0.0/0 gateway=172.18.20.6 routing-table=vpn
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| SERVER_ADDRESS | Yes | - | Xray server address (IP or domain) |
| SERVER_PORT | No | 443 | Xray server port |
| ID | Yes | - | VLESS UUID |
| SNI | Yes | - | TLS SNI (Server Name Indication) |
| PBK | Yes | - | Reality public key |
| SID | Yes | - | Reality short ID |
| SPX | No | / | xHTTP path and spiderX |
| FP | No | firefox | TLS fingerprint (chrome, firefox, safari, edge) |
| ENCRYPTION | No | none | VLESS encryption |
| LOG_LEVEL | No | warning | Xray log level |

## Building

### Local build for ARM (MikroTik)

```bash
docker buildx build --platform linux/arm/v7 -t xray-mikrotik-xhttp:latest .
```

### Build with specific versions

```bash
docker buildx build \
  --build-arg XRAY_VERSION=v25.1.1 \
  --build-arg TUN2SOCKS_VERSION=v2.5.2 \
  --platform linux/arm/v7 \
  -t xray-mikrotik-xhttp:latest .
```

### Build with latest versions

```bash
docker buildx build \
  --build-arg XRAY_VERSION=latest \
  --build-arg TUN2SOCKS_VERSION=latest \
  --platform linux/arm/v7 \
  -t xray-mikrotik-xhttp:latest .
```

## Server Configuration (3x-ui)

Create inbound with:
- Protocol: VLESS
- Port: 443
- Security: Reality
- Transport: xHTTP
- Path: /
- Dest: www.github.com:443
- SNI: www.github.com

## License

MIT
