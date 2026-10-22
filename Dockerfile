### Stage 1: Builder - download and extract binaries
FROM alpine:3.21 AS builder

ARG TARGETARCH
ARG XRAY_VERSION=v25.12.8
ARG HEV_TUNNEL_VERSION=2.15.0

RUN apk add --no-cache curl jq unzip file upx

# Download xray
RUN XRAY_VERSION_RESOLVED="${XRAY_VERSION}" && \
    if [ "${XRAY_VERSION}" = "latest" ]; then \
        XRAY_VERSION_RESOLVED=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name); \
    fi && \
    case "${TARGETARCH}" in \
        "amd64") ARCH="64" ;; \
        "arm64") ARCH="arm64-v8a" ;; \
        "arm") ARCH="arm32-v7a" ;; \
        *) ARCH="64" ;; \
    esac && \
    echo "Downloading xray ${XRAY_VERSION_RESOLVED} for ${ARCH}..." && \
    curl -L -f -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION_RESOLVED}/Xray-linux-${ARCH}.zip" && \
    unzip /tmp/xray.zip -d /tmp/xray && \
    mv /tmp/xray/xray /usr/local/bin/ && \
    chmod +x /usr/local/bin/xray && \
    file /usr/local/bin/xray | grep -q "ELF" || (echo "ERROR: xray is not a valid ELF binary" && exit 1) && \
    upx --best --lzma /usr/local/bin/xray

# Download hev-socks5-tunnel (static release binary ~0.35 MiB, no upx needed)
RUN HEV_VERSION_RESOLVED="${HEV_TUNNEL_VERSION}" && \
    if [ "${HEV_TUNNEL_VERSION}" = "latest" ]; then \
        HEV_VERSION_RESOLVED=$(curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | jq -r .tag_name); \
    fi && \
    case "${TARGETARCH}" in \
        "amd64") ARCH="x86_64" ;; \
        "arm64") ARCH="arm64" ;; \
        "arm") ARCH="arm32v7hf" ;; \
        *) ARCH="x86_64" ;; \
    esac && \
    echo "Downloading hev-socks5-tunnel ${HEV_VERSION_RESOLVED} for ${ARCH}..." && \
    curl -L -f -o /usr/local/bin/hev-socks5-tunnel "https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION_RESOLVED}/hev-socks5-tunnel-linux-${ARCH}" && \
    chmod +x /usr/local/bin/hev-socks5-tunnel && \
    file /usr/local/bin/hev-socks5-tunnel | grep -q "ELF" || (echo "ERROR: hev-socks5-tunnel is not a valid ELF binary" && exit 1)


### Stage 2: Runtime - minimal image
FROM alpine:3.21

# Runtime dependencies only.
# Image must fit on 128 MiB flash MikroTik devices (hAP ax^3) with double
# footprint during pull (tarball + extracted). Hence:
#   - no bind-tools (~20 MiB w/ krb5/gss/libldap deps) — DNS fallback uses
#     busybox nslookup (built-in to alpine);
#   - no jq (~1.5 MiB) — DoH JSON parsed with sed in entrypoint.sh;
#   - xray UPX-compressed in builder stage (~−20 MiB).
RUN apk add --no-cache \
    bash \
    curl \
    iproute2 \
    ca-certificates \
    && rm -rf /var/cache/apk/* /tmp/*

# Copy binaries from builder
COPY --from=builder /usr/local/bin/xray /usr/local/bin/xray
COPY --from=builder /usr/local/bin/hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel

# Verify binaries work (hev-socks5-tunnel has no --version and exits non-zero
# without a config; any exit code except 126/127 proves the binary executes)
RUN /usr/local/bin/xray version && \
    { /usr/local/bin/hev-socks5-tunnel >/dev/null 2>&1; rc=$?; [ $rc -ne 126 ] && [ $rc -ne 127 ]; }

COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
