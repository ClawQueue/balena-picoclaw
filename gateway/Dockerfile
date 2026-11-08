FROM alpine:3.21

# Install lightweight runtime dependencies for low-memory SBCs (RPi Zero, BeagleBone Black, etc.)
# rclone is installed opportunistically because some architectures (like arm/v6) may omit it in Alpine repos.
RUN apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      curl \
      jq \
      openssl \
      sqlite \
      tar \
      tini \
      tzdata \
      zip \
    && (apk add --no-cache rclone || echo "Notice: rclone package not available for this architecture; backup.sh will skip cloud sync unless rclone binary is provided.")

WORKDIR /app

# Pre-bake the official static PicoClaw binaries (picoclaw + picoclaw-launcher)
# Supports: armv6 (RPi Zero/1), armv7 (BeagleBone Black/RPi 2), arm64 (RPi Zero 2 W/3/4/5), x86_64, riscv64
ARG PICOCLAW_VERSION=latest
RUN set -euo pipefail && \
    APK_ARCH="$(cat /etc/apk/arch 2>/dev/null || uname -m)" && \
    case "${APK_ARCH}" in \
      armhf|armv6l|armv6)   PICO_ARCH="armv6" ;; \
      armv7|armv7l)         PICO_ARCH="armv7" ;; \
      aarch64|arm64|armv8l) PICO_ARCH="arm64" ;; \
      x86_64|amd64)         PICO_ARCH="x86_64" ;; \
      riscv64)              PICO_ARCH="riscv64" ;; \
      s390x)                PICO_ARCH="s390x" ;; \
      loongarch64|loong64)  PICO_ARCH="loong64" ;; \
      *) echo "Unsupported architecture: ${APK_ARCH}" >&2; exit 1 ;; \
    esac && \
    if [ "${PICOCLAW_VERSION}" = "latest" ]; then \
      RELEASE_TAG="$(curl -fsSL https://api.github.com/repos/sipeed/picoclaw/releases/latest | jq -r '.tag_name')" ; \
    else \
      case "${PICOCLAW_VERSION}" in \
        v*) RELEASE_TAG="${PICOCLAW_VERSION}" ;; \
        *)  RELEASE_TAG="v${PICOCLAW_VERSION}" ;; \
      esac ; \
    fi && \
    VERSION_NO_V="${RELEASE_TAG#v}" && \
    TARBALL="picoclaw_Linux_${PICO_ARCH}.tar.gz" && \
    CHECKSUMS="picoclaw_${VERSION_NO_V}_checksums.txt" && \
    BASE_URL="https://github.com/sipeed/picoclaw/releases/download/${RELEASE_TAG}" && \
    mkdir -p /tmp/picoclaw-install /app/baked-bin && \
    echo "Downloading PicoClaw ${RELEASE_TAG} (${TARBALL}) for ${APK_ARCH} -> ${PICO_ARCH}..." && \
    curl -fsSL "${BASE_URL}/${TARBALL}" -o "/tmp/picoclaw-install/${TARBALL}" && \
    curl -fsSL "${BASE_URL}/${CHECKSUMS}" -o "/tmp/picoclaw-install/${CHECKSUMS}" && \
    (cd /tmp/picoclaw-install && grep " ${TARBALL}\$" "${CHECKSUMS}" | sha256sum -c -) && \
    tar -xzf "/tmp/picoclaw-install/${TARBALL}" -C /tmp/picoclaw-install && \
    install -m 0755 /tmp/picoclaw-install/picoclaw /app/baked-bin/picoclaw && \
    if [ -f /tmp/picoclaw-install/picoclaw-launcher ]; then \
      install -m 0755 /tmp/picoclaw-install/picoclaw-launcher /app/baked-bin/picoclaw-launcher ; \
    fi && \
    ln -sf /app/baked-bin/picoclaw /usr/local/bin/picoclaw && \
    if [ -f /app/baked-bin/picoclaw-launcher ]; then \
      ln -sf /app/baked-bin/picoclaw-launcher /usr/local/bin/picoclaw-launcher ; \
    fi && \
    echo "${RELEASE_TAG}" > /app/.picoclaw-image-version && \
    rm -rf /tmp/picoclaw-install

# Copy default configuration templates, optional local secrets overrides, and operational scripts
COPY config/config.json /app/config/config.json
COPY config/launcher-config.json /app/config/launcher-config.json
COPY secrets/ /app/secrets/
COPY start.sh /app/start.sh
COPY backup.sh /app/backup.sh
RUN chmod +x /app/start.sh /app/backup.sh

# Default environment tuned for 512MB RAM SBCs
ENV PICOCLAW_HOME=/root/.picoclaw \
    GOMEMLIMIT=128MiB \
    GOGC=50

EXPOSE 18800 18790

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/start.sh"]
