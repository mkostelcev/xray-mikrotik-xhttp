### Stage 1: Builder - download and extract binaries
FROM alpine:3.21 AS builder

ARG TARGETARCH
ARG XRAY_VERSION=v26.1.18
ARG TUN2SOCKS_VERSION=v2.6.0

RUN apk add --no-cache curl jq unzip file

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
    file /usr/local/bin/xray | grep -q "ELF" || (echo "ERROR: xray is not a valid ELF binary" && exit 1)

# Download tun2socks
RUN TUN2SOCKS_VERSION_RESOLVED="${TUN2SOCKS_VERSION}" && \
    if [ "${TUN2SOCKS_VERSION}" = "latest" ]; then \
        TUN2SOCKS_VERSION_RESOLVED=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | jq -r .tag_name); \
    fi && \
    case "${TARGETARCH}" in \
        "amd64") ARCH="amd64" ;; \
        "arm64") ARCH="arm64" ;; \
        "arm") ARCH="armv7" ;; \
        *) ARCH="amd64" ;; \
    esac && \
    echo "Downloading tun2socks ${TUN2SOCKS_VERSION_RESOLVED} for ${ARCH}..." && \
    curl -L -f -o /tmp/tun2socks.zip "https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION_RESOLVED}/tun2socks-linux-${ARCH}.zip" && \
    unzip /tmp/tun2socks.zip -d /tmp/tun2socks && \
    mv /tmp/tun2socks/tun2socks-linux-${ARCH} /usr/local/bin/tun2socks && \
    chmod +x /usr/local/bin/tun2socks && \
    file /usr/local/bin/tun2socks | grep -q "ELF" || (echo "ERROR: tun2socks is not a valid ELF binary" && exit 1)


### Stage 2: Runtime - minimal image
FROM alpine:3.21

# Runtime dependencies only
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    iproute2 \
    ca-certificates \
    && rm -rf /var/cache/apk/* /tmp/*

# Copy binaries from builder
COPY --from=builder /usr/local/bin/xray /usr/local/bin/xray
COPY --from=builder /usr/local/bin/tun2socks /usr/local/bin/tun2socks

# Verify binaries work
RUN /usr/local/bin/xray version && \
    /usr/local/bin/tun2socks --version

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
