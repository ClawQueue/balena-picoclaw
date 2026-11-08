#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Balena PicoClaw Gateway Entrypoint
# Optimized for low-spec SBCs (Raspberry Pi Zero, BeagleBone Black, etc.)
# ==============================================================================

DATA_DIR="/data/picoclaw"
SECRETS_DATA_DIR="$DATA_DIR/secrets"
SECRETS_APP_DIR="/app/secrets"
VERSIONS_DIR="$DATA_DIR/versions"
ACTIVE_VERSION_FILE="$DATA_DIR/active_version"
TOKEN_FILE="$DATA_DIR/gateway.token"
PASSWORD_FILE="$DATA_DIR/dashboard.password"
BAKED_VERSION_FILE="/app/.picoclaw-image-version"

# Load optional secrets.env overrides (build-time /app/secrets first, then persistent /data/picoclaw/secrets)
for env_file in "$SECRETS_APP_DIR/secrets.env" "$SECRETS_DATA_DIR/secrets.env"; do
  if [ -f "$env_file" ]; then
    echo "Loading environment overrides from $env_file..."
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
done

KEEP_VERSIONS="${PICOCLAW_KEEP_VERSIONS:-2}"
PICOCLAW_MODE="${PICOCLAW_MODE:-launcher}"

# Install optional extra Alpine packages if requested via PICOCLAW_EXTRA_PKGS
if [ -n "${PICOCLAW_EXTRA_PKGS:-}" ]; then
  echo "Installing extra Alpine packages: ${PICOCLAW_EXTRA_PKGS}..."
  # shellcheck disable=SC2086
  apk add --no-cache $PICOCLAW_EXTRA_PKGS || echo "WARNING: Failed to install some packages from PICOCLAW_EXTRA_PKGS"
fi

# Go runtime memory tuning for 256MB–512MB RAM SBCs (Orange Pi Zero, RPi Zero, BeagleBone Black)
TOTAL_MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 524288)"
if [ -n "${PICOCLAW_GOMEMLIMIT:-}" ]; then
  export GOMEMLIMIT="$PICOCLAW_GOMEMLIMIT"
elif [ "$TOTAL_MEM_KB" -le 300000 ] 2>/dev/null; then
  # 256MB RAM boards (e.g. Orange Pi Zero 256MB)
  export GOMEMLIMIT="64MiB"
else
  export GOMEMLIMIT="${GOMEMLIMIT:-128MiB}"
fi
export GOGC="${PICOCLAW_GOGC:-${GOGC:-50}}"

mkdir -p "$DATA_DIR" "$VERSIONS_DIR"

# ------------------------------------------------------------------------------
# 1. Architecture Detection
# ------------------------------------------------------------------------------
detect_pico_arch() {
  local apk_arch
  apk_arch="$(cat /etc/apk/arch 2>/dev/null || uname -m)"
  case "$apk_arch" in
    armhf|armv6l|armv6)   echo "armv6" ;;
    armv7|armv7l)         echo "armv7" ;;
    aarch64|arm64|armv8l) echo "arm64" ;;
    x86_64|amd64)         echo "x86_64" ;;
    riscv64)              echo "riscv64" ;;
    s390x)                echo "s390x" ;;
    loongarch64|loong64)  echo "loong64" ;;
    *)
      echo "ERROR: Unsupported architecture '${apk_arch}'" >&2
      return 1
      ;;
  esac
}

PICO_ARCH="$(detect_pico_arch)"

# ------------------------------------------------------------------------------
# 2. Version Resolution & Snapshot Management
#    Snapshots live in /data/picoclaw/versions/<vX.Y.Z>/{bin,picoclaw-home}
#    allowing instant rollback and zero-flash-wear RAM-staged upgrades.
# ------------------------------------------------------------------------------
IMAGE_VERSION="v0.3.1"
if [ -f "$BAKED_VERSION_FILE" ]; then
  IMAGE_VERSION="$(tr -d '[:space:]' < "$BAKED_VERSION_FILE")"
fi

ACTIVE_VERSION=""
if [ -f "$ACTIVE_VERSION_FILE" ]; then
  ACTIVE_VERSION="$(tr -d '[:space:]' < "$ACTIVE_VERSION_FILE")"
fi

normalize_version() {
  local v="$1"
  case "$v" in
    v*) echo "$v" ;;
    *)  echo "v$v" ;;
  esac
}

REQUESTED_VERSION="${PICOCLAW_VERSION:-}"
if [ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "image" ] || [ "$REQUESTED_VERSION" = "baked" ]; then
  # Default to active snapshot if present, otherwise use the image's pre-baked version
  if [ -n "$ACTIVE_VERSION" ] && [ -x "$VERSIONS_DIR/$ACTIVE_VERSION/bin/picoclaw" ]; then
    TARGET_VERSION="$ACTIVE_VERSION"
  else
    TARGET_VERSION="$IMAGE_VERSION"
  fi
elif [ "$REQUESTED_VERSION" = "latest" ]; then
  echo "Resolving latest PicoClaw release tag from GitHub..."
  LATEST_TAG="$(curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/repos/sipeed/picoclaw/releases/latest 2>/dev/null | jq -r '.tag_name // empty' || true)"
  if [ -n "$LATEST_TAG" ]; then
    TARGET_VERSION="$(normalize_version "$LATEST_TAG")"
    echo "Resolved latest version: $TARGET_VERSION"
  elif [ -n "$ACTIVE_VERSION" ] && [ -x "$VERSIONS_DIR/$ACTIVE_VERSION/bin/picoclaw" ]; then
    echo "WARNING: Could not reach GitHub API; keeping active version $ACTIVE_VERSION"
    TARGET_VERSION="$ACTIVE_VERSION"
  else
    echo "WARNING: Could not reach GitHub API; falling back to image version $IMAGE_VERSION"
    TARGET_VERSION="$IMAGE_VERSION"
  fi
else
  TARGET_VERSION="$(normalize_version "$REQUESTED_VERSION")"
fi

install_version_binaries() {
  local ver="$1"
  local dest_bin_dir="$2"
  local ver_no_v="${ver#v}"

  mkdir -p "$dest_bin_dir"

  # Fast path: copy pre-baked binaries from image if version matches
  if [ "$ver" = "$IMAGE_VERSION" ] && [ -x "/app/baked-bin/picoclaw" ]; then
    echo "Seeding PicoClaw $ver (${PICO_ARCH}) from pre-baked container image..."
    cp -f /app/baked-bin/picoclaw "$dest_bin_dir/picoclaw"
    chmod 0755 "$dest_bin_dir/picoclaw"
    if [ -x "/app/baked-bin/picoclaw-launcher" ]; then
      cp -f /app/baked-bin/picoclaw-launcher "$dest_bin_dir/picoclaw-launcher"
      chmod 0755 "$dest_bin_dir/picoclaw-launcher"
    fi
    return 0
  fi

  # Download release archive into RAM tmpfs (/tmp) to avoid SD card wear
  local dl_dir="/tmp/picoclaw-dl-$$"
  local tarball="picoclaw_Linux_${PICO_ARCH}.tar.gz"
  local checksums="picoclaw_${ver_no_v}_checksums.txt"
  local base_url="https://github.com/sipeed/picoclaw/releases/download/${ver}"

  mkdir -p "$dl_dir"
  echo "Downloading PicoClaw $ver (${tarball}) into RAM tmpfs..."
  if ! curl -fsSL --connect-timeout 15 --max-time 180 "${base_url}/${tarball}" -o "${dl_dir}/${tarball}"; then
    rm -rf "$dl_dir"
    return 1
  fi

  if curl -fsSL --connect-timeout 15 --max-time 30 "${base_url}/${checksums}" -o "${dl_dir}/${checksums}"; then
    echo "Verifying SHA256 checksum for ${tarball}..."
    if ! (cd "$dl_dir" && grep " ${tarball}\$" "$checksums" | sha256sum -c -); then
      echo "ERROR: SHA256 checksum verification failed for ${tarball}!" >&2
      rm -rf "$dl_dir"
      return 1
    fi
  else
    echo "WARNING: Could not fetch ${checksums}; proceeding without checksum check."
  fi

  if ! tar -xzf "${dl_dir}/${tarball}" -C "$dl_dir"; then
    rm -rf "$dl_dir"
    return 1
  fi

  install -m 0755 "${dl_dir}/picoclaw" "$dest_bin_dir/picoclaw"
  if [ -f "${dl_dir}/picoclaw-launcher" ]; then
    install -m 0755 "${dl_dir}/picoclaw-launcher" "$dest_bin_dir/picoclaw-launcher"
  fi

  rm -rf "$dl_dir"
  return 0
}

SNAP_DIR="$VERSIONS_DIR/$TARGET_VERSION"

if [ -x "$SNAP_DIR/bin/picoclaw" ]; then
  echo "Using existing snapshot for PicoClaw $TARGET_VERSION ($PICO_ARCH)..."
else
  echo "Preparing new snapshot for PicoClaw $TARGET_VERSION ($PICO_ARCH)..."
  NEW_SNAP_DIR="$VERSIONS_DIR/${TARGET_VERSION}.staging-$$"
  rm -rf "$NEW_SNAP_DIR"
  mkdir -p "$NEW_SNAP_DIR/bin" "$NEW_SNAP_DIR/picoclaw-home"

  # Clone state from current active version if upgrading/downgrading
  if [ -n "$ACTIVE_VERSION" ] && [ -d "$VERSIONS_DIR/$ACTIVE_VERSION/picoclaw-home" ]; then
    echo "Cloning state from previous snapshot ($ACTIVE_VERSION) -> ($TARGET_VERSION)..."
    cp -a "$VERSIONS_DIR/$ACTIVE_VERSION/picoclaw-home/." "$NEW_SNAP_DIR/picoclaw-home/"
    rm -rf "$NEW_SNAP_DIR/picoclaw-home/logs" \
           "$NEW_SNAP_DIR/picoclaw-home/.picoclaw.pid" \
           "$NEW_SNAP_DIR/picoclaw-home/picoclaw.pid.json"
  elif [ -d "$DATA_DIR/.picoclaw" ] && [ ! -L "$DATA_DIR/.picoclaw" ]; then
    echo "Migrating legacy /data/picoclaw/.picoclaw into snapshot $TARGET_VERSION..."
    cp -a "$DATA_DIR/.picoclaw/." "$NEW_SNAP_DIR/picoclaw-home/"
  fi

  if install_version_binaries "$TARGET_VERSION" "$NEW_SNAP_DIR/bin" && \
     "$NEW_SNAP_DIR/bin/picoclaw" version >/dev/null 2>&1; then
    rm -rf "$SNAP_DIR"
    mv "$NEW_SNAP_DIR" "$SNAP_DIR"
    echo "Successfully installed PicoClaw $TARGET_VERSION"
  else
    echo "ERROR: Failed to install or verify PicoClaw $TARGET_VERSION!"
    rm -rf "$NEW_SNAP_DIR"
    if [ -n "$ACTIVE_VERSION" ] && [ -x "$VERSIONS_DIR/$ACTIVE_VERSION/bin/picoclaw" ]; then
      echo "Rolling back to previous working snapshot: $ACTIVE_VERSION"
      TARGET_VERSION="$ACTIVE_VERSION"
      SNAP_DIR="$VERSIONS_DIR/$TARGET_VERSION"
    elif [ "$TARGET_VERSION" != "$IMAGE_VERSION" ]; then
      echo "Falling back to pre-baked image version: $IMAGE_VERSION"
      TARGET_VERSION="$IMAGE_VERSION"
      SNAP_DIR="$VERSIONS_DIR/$TARGET_VERSION"
      mkdir -p "$SNAP_DIR/bin" "$SNAP_DIR/picoclaw-home"
      install_version_binaries "$TARGET_VERSION" "$SNAP_DIR/bin"
    else
      exit 1
    fi
  fi
fi

echo "$TARGET_VERSION" > "$ACTIVE_VERSION_FILE"

# Prune older version snapshots to conserve eMMC/SD storage (BeagleBone Black has 4GB eMMC)
if [ "$KEEP_VERSIONS" -gt 0 ] 2>/dev/null; then
  INSTALLED_COUNT=$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  if [ "$INSTALLED_COUNT" -gt "$KEEP_VERSIONS" ]; then
    for old_dir in $(ls -1dt "$VERSIONS_DIR"/* 2>/dev/null | tail -n +$((KEEP_VERSIONS + 1))); do
      old_ver="$(basename "$old_dir")"
      if [ "$old_ver" != "$TARGET_VERSION" ]; then
        echo "Pruning old snapshot version: $old_ver"
        rm -rf "$old_dir"
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 3. Symlinks, RAM Log Redirection & Shell Environment
# ------------------------------------------------------------------------------
export PICOCLAW_HOME="$SNAP_DIR/picoclaw-home"
export PICOCLAW_CONFIG="$PICOCLAW_HOME/config.json"
export PICOCLAW_BINARY="/data/picoclaw/bin/picoclaw"

mkdir -p "$PICOCLAW_HOME" "$PICOCLAW_HOME/workspace"

# Point /data/picoclaw/bin and /root/.picoclaw at the active snapshot
ln -sfn "$SNAP_DIR/bin" "$DATA_DIR/bin"
ln -sfn "$PICOCLAW_HOME" /root/.picoclaw
ln -sf /data/picoclaw/bin/picoclaw /usr/local/bin/picoclaw
if [ -x "$SNAP_DIR/bin/picoclaw-launcher" ]; then
  ln -sf /data/picoclaw/bin/picoclaw-launcher /usr/local/bin/picoclaw-launcher
fi

# Redirect gateway/launcher log files to RAM tmpfs (/tmp) to prevent microSD/eMMC wear
mkdir -p /tmp/picoclaw-logs
if [ -d "$PICOCLAW_HOME/logs" ] && [ ! -L "$PICOCLAW_HOME/logs" ]; then
  rm -rf "$PICOCLAW_HOME/logs"
fi
ln -sfn /tmp/picoclaw-logs "$PICOCLAW_HOME/logs"

# Clean up any stale PID files left by an unclean power cycle
rm -f "$PICOCLAW_HOME/.picoclaw.pid" "$PICOCLAW_HOME/picoclaw.pid.json"

# ------------------------------------------------------------------------------
# 4. Credentials Management (Dashboard Password & Pico Gateway Token)
# ------------------------------------------------------------------------------
if [ -n "${PICOCLAW_GATEWAY_TOKEN:-}" ]; then
  GATEWAY_TOKEN="$PICOCLAW_GATEWAY_TOKEN"
  echo -n "$GATEWAY_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
elif [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
  GATEWAY_TOKEN="$(cat "$TOKEN_FILE")"
else
  GATEWAY_TOKEN="$(openssl rand -hex 32)"
  echo -n "$GATEWAY_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
export PICOCLAW_CHANNELS_PICO_TOKEN="$GATEWAY_TOKEN"

FORCE_PASSWORD_SYNC="false"
if [ -n "${PICOCLAW_DASHBOARD_PASSWORD:-}" ]; then
  DASHBOARD_PASSWORD="$PICOCLAW_DASHBOARD_PASSWORD"
  if [ ! -f "$PASSWORD_FILE" ] || [ "$(cat "$PASSWORD_FILE" 2>/dev/null || true)" != "$DASHBOARD_PASSWORD" ]; then
    echo -n "$DASHBOARD_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    FORCE_PASSWORD_SYNC="true"
  fi
elif [ -f "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
  DASHBOARD_PASSWORD="$(cat "$PASSWORD_FILE")"
else
  DASHBOARD_PASSWORD="$(openssl rand -hex 12)"
  echo -n "$DASHBOARD_PASSWORD" > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  FORCE_PASSWORD_SYNC="true"
fi

# Configure interactive shell profile for `balena ssh` sessions
mkdir -p /etc/profile.d
cat <<EOF > /etc/profile.d/picoclaw.sh
export PICOCLAW_HOME="$PICOCLAW_HOME"
export PICOCLAW_CONFIG="$PICOCLAW_CONFIG"
export PICOCLAW_BINARY="$PICOCLAW_BINARY"
export PICOCLAW_CHANNELS_PICO_TOKEN="$GATEWAY_TOKEN"
export GOMEMLIMIT="$GOMEMLIMIT"
export GOGC="$GOGC"
export PATH="/data/picoclaw/bin:/usr/local/bin:\$PATH"
EOF
chmod 0644 /etc/profile.d/picoclaw.sh
if [ -f /etc/bash.bashrc ] && ! grep -q "/etc/profile.d/picoclaw.sh" /etc/bash.bashrc 2>/dev/null; then
  echo '[ -f /etc/profile.d/picoclaw.sh ] && . /etc/profile.d/picoclaw.sh' >> /etc/bash.bashrc
fi

# ------------------------------------------------------------------------------
# 5. First-Boot Onboarding & Configuration Patching
# ------------------------------------------------------------------------------
if [ ! -f "$PICOCLAW_CONFIG" ]; then
  echo "First boot detected for snapshot $TARGET_VERSION — initializing PicoClaw workspace..."
  if ! (yes n 2>/dev/null | /data/picoclaw/bin/picoclaw onboard >/dev/null 2>&1); then
    echo "Seeding default config.json template..."
  fi
  if [ ! -f "$PICOCLAW_CONFIG" ]; then
    cp /app/config/config.json "$PICOCLAW_CONFIG"
  fi
fi

# Build allow_origins list for WebSocket connections (defaults to ["*"] so any LAN IP,
# .local hostname, or Balena Public URL works out-of-the-box; Pico WS token still authenticates).
ALLOW_ORIGINS_JSON='["*"]'
EXTRA_ORIGINS_RAW="${PICOCLAW_ALLOWED_ORIGINS:-${PICOCLAW_ALLOW_ORIGINS:-}}"
if [ -n "$EXTRA_ORIGINS_RAW" ]; then
  ALLOW_ORIGINS_JSON='[]'
  IFS=',' read -ra EXTRA_ORIGINS <<< "$EXTRA_ORIGINS_RAW"
  for origin in "${EXTRA_ORIGINS[@]}"; do
    origin_trimmed="$(echo "$origin" | xargs)"
    if [ -n "$origin_trimmed" ]; then
      ALLOW_ORIGINS_JSON=$(echo "$ALLOW_ORIGINS_JSON" | jq --arg o "$origin_trimmed" '. + [$o] | unique')
    fi
  done
  if [ -n "${BALENA_DEVICE_UUID:-}" ]; then
    ALLOW_ORIGINS_JSON=$(echo "$ALLOW_ORIGINS_JSON" | jq --arg url "https://${BALENA_DEVICE_UUID}.balena-devices.com" '. + [$url] | unique')
  fi
  if [ -n "${PICOCLAW_PUBLIC_ORIGIN:-}" ]; then
    ALLOW_ORIGINS_JSON=$(echo "$ALLOW_ORIGINS_JSON" | jq --arg url "$PICOCLAW_PUBLIC_ORIGIN" '. + [$url] | unique')
  fi
fi

ENABLE_HW="false"
if [ "${PICOCLAW_ENABLE_HARDWARE:-false}" = "true" ] || [ "${PICOCLAW_ENABLE_HARDWARE:-0}" = "1" ]; then
  ENABLE_HW="true"
fi

DEFAULT_MODEL="${PICOCLAW_DEFAULT_MODEL:-}"

# Patch config.json non-destructively using jq
TMP_CFG="$(mktemp /tmp/picoclaw-config.XXXXXX)"
if jq \
  --argjson origins "$ALLOW_ORIGINS_JSON" \
  --argjson enable_hw "$ENABLE_HW" \
  --arg default_model "$DEFAULT_MODEL" \
  '
  .version = (.version // 3) |
  .gateway.host = "127.0.0.1" |
  .gateway.port = 18790 |
  .channel_list = (.channel_list // {}) |
  .channel_list.pico = (.channel_list.pico // {}) |
  .channel_list.pico.enabled = true |
  .channel_list.pico.type = "pico" |
  .channel_list.pico.settings = (.channel_list.pico.settings // {}) |
  .channel_list.pico.settings.allow_origins = (((.channel_list.pico.settings.allow_origins // []) + $origins) | unique) |
  .channel_list.pico.settings.ping_interval = (.channel_list.pico.settings.ping_interval // 30) |
  .channel_list.pico.settings.read_timeout = (.channel_list.pico.settings.read_timeout // 60) |
  .channel_list.pico.settings.write_timeout = (.channel_list.pico.settings.write_timeout // 10) |
  .channel_list.pico.settings.max_connections = (.channel_list.pico.settings.max_connections // 32) |
  .tools = (.tools // {}) |
  .tools.cron = (.tools.cron // {}) |
  .tools.cron.allow_command = (.tools.cron.allow_command // true) |
  (if $enable_hw then
    .tools.i2c.enabled = true |
    .tools.spi.enabled = true |
    .tools.serial.enabled = true |
    .devices.enabled = true
  else . end) |
  (if ($default_model | length) > 0 then
    .agents.defaults.model_name = $default_model
  else . end)
  ' "$PICOCLAW_CONFIG" > "$TMP_CFG"; then
  mv "$TMP_CFG" "$PICOCLAW_CONFIG"
  chmod 600 "$PICOCLAW_CONFIG"
else
  rm -f "$TMP_CFG"
  echo "WARNING: Failed to patch $PICOCLAW_CONFIG with jq; keeping existing file."
fi

# Apply optional config.override.json from /app/secrets or /data/picoclaw/secrets (deep merge via jq)
for override_cfg in "$SECRETS_APP_DIR/config.override.json" "$SECRETS_DATA_DIR/config.override.json"; do
  if [ -f "$override_cfg" ] && [ -s "$override_cfg" ]; then
    echo "Applying configuration override from $override_cfg..."
    TMP_OVR="$(mktemp /tmp/picoclaw-override.XXXXXX)"
    if jq -s '.[0] * .[1]' "$PICOCLAW_CONFIG" "$override_cfg" > "$TMP_OVR"; then
      mv "$TMP_OVR" "$PICOCLAW_CONFIG"
      chmod 600 "$PICOCLAW_CONFIG"
    else
      rm -f "$TMP_OVR"
      echo "WARNING: Failed to merge $override_cfg; check JSON syntax."
    fi
  fi
done

# Seed optional OAuth credentials (auth.json) from secrets if not already present in $PICOCLAW_HOME
for secret_auth in "$SECRETS_APP_DIR/auth.json" "$SECRETS_DATA_DIR/auth.json"; do
  if [ -f "$secret_auth" ] && [ -s "$secret_auth" ] && [ ! -f "$PICOCLAW_HOME/auth.json" ]; then
    echo "Seeding OAuth credentials from $secret_auth..."
    cp "$secret_auth" "$PICOCLAW_HOME/auth.json"
    chmod 600 "$PICOCLAW_HOME/auth.json"
  fi
done

# Seed optional custom .security.yml from secrets if provided
for secret_sec in "$SECRETS_APP_DIR/.security.yml" "$SECRETS_DATA_DIR/.security.yml"; do
  if [ -f "$secret_sec" ] && [ -s "$secret_sec" ]; then
    echo "Applying .security.yml override from $secret_sec..."
    cp "$secret_sec" "$PICOCLAW_HOME/.security.yml"
    chmod 600 "$PICOCLAW_HOME/.security.yml"
  fi
done

# Initialize .security.yml if not present (or inject optional env API keys on first boot)
SECURITY_YML="$PICOCLAW_HOME/.security.yml"
if [ ! -f "$SECURITY_YML" ]; then
  {
    echo "channel_list:"
    echo "  pico:"
    echo "    settings:"
    echo "      token: \"${GATEWAY_TOKEN}\""
    if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${DEEPSEEK_API_KEY:-}" ] || [ -n "${OPENROUTER_API_KEY:-}" ]; then
      echo "model_list:"
      [ -n "${OPENAI_API_KEY:-}" ] && printf '  gpt-5.4:0:\n    api_keys:\n      - "%s"\n' "$OPENAI_API_KEY"
      [ -n "${ANTHROPIC_API_KEY:-}" ] && printf '  claude-sonnet-4.6:0:\n    api_keys:\n      - "%s"\n' "$ANTHROPIC_API_KEY"
      [ -n "${GEMINI_API_KEY:-}" ] && printf '  gemini-2.5-flash:0:\n    api_keys:\n      - "%s"\n' "$GEMINI_API_KEY"
      [ -n "${DEEPSEEK_API_KEY:-}" ] && printf '  deepseek-chat:0:\n    api_keys:\n      - "%s"\n' "$DEEPSEEK_API_KEY"
      [ -n "${OPENROUTER_API_KEY:-}" ] && printf '  openrouter-auto:0:\n    api_keys:\n      - "%s"\n' "$OPENROUTER_API_KEY"
    fi
  } > "$SECURITY_YML"
  chmod 600 "$SECURITY_YML"
fi

# Run optional custom startup hook (init.sh) from secrets if present
for secret_init in "$SECRETS_APP_DIR/init.sh" "$SECRETS_DATA_DIR/init.sh"; do
  if [ -f "$secret_init" ]; then
    echo "Executing custom startup script $secret_init..."
    bash "$secret_init"
  fi
done

# Configure launcher-config.json and seed bcrypt dashboard password store
LAUNCHER_CFG="$PICOCLAW_HOME/launcher-config.json"
AUTH_DB="$PICOCLAW_HOME/launcher-auth.db"
if [ ! -f "$LAUNCHER_CFG" ]; then
  cp /app/config/launcher-config.json "$LAUNCHER_CFG"
fi

if [ "$FORCE_PASSWORD_SYNC" = "true" ] || [ ! -f "$AUTH_DB" ]; then
  rm -f "$AUTH_DB"
  TMP_LCFG="$(mktemp /tmp/picoclaw-lcfg.XXXXXX)"
  if jq --arg pw "$DASHBOARD_PASSWORD" '
    .port = 18800 |
    .public = true |
    .allow_localhost_bypass = true |
    .trusted_proxy_cidrs = ((.trusted_proxy_cidrs // []) + ["127.0.0.1/32", "::1/128"] | unique) |
    .launcher_token = $pw
  ' "$LAUNCHER_CFG" > "$TMP_LCFG"; then
    mv "$TMP_LCFG" "$LAUNCHER_CFG"
    chmod 600 "$LAUNCHER_CFG"
  else
    rm -f "$TMP_LCFG"
  fi
else
  TMP_LCFG="$(mktemp /tmp/picoclaw-lcfg.XXXXXX)"
  if jq '
    .port = 18800 |
    .public = true |
    .allow_localhost_bypass = true |
    .trusted_proxy_cidrs = ((.trusted_proxy_cidrs // []) + ["127.0.0.1/32", "::1/128"] | unique)
  ' "$LAUNCHER_CFG" > "$TMP_LCFG"; then
    mv "$TMP_LCFG" "$LAUNCHER_CFG"
    chmod 600 "$LAUNCHER_CFG"
  else
    rm -f "$TMP_LCFG"
  fi
fi

# ------------------------------------------------------------------------------
# 6. SQLite Flash Wear Optimization (WAL Mode + Synchronous NORMAL)
# ------------------------------------------------------------------------------
if command -v sqlite3 >/dev/null 2>&1; then
  find "$PICOCLAW_HOME" -maxdepth 3 \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | while read -r db; do
    sqlite3 "$db" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;" >/dev/null 2>&1 || true
  done
fi

# ------------------------------------------------------------------------------
# 7. Status Banner & Maintenance Pause Check
# ------------------------------------------------------------------------------
echo "=================================================================="
echo "  PicoClaw Balena Appliance"
echo "  Version        : $TARGET_VERSION ($PICO_ARCH)"
echo "  Runtime Mode   : $PICOCLAW_MODE (GOMEMLIMIT=$GOMEMLIMIT, GOGC=$GOGC)"
echo "  Home Directory : $PICOCLAW_HOME"
echo "------------------------------------------------------------------"
echo "  WebUI Password : $DASHBOARD_PASSWORD"
echo "  Pico WS Token  : $GATEWAY_TOKEN"
if [ -n "${BALENA_DEVICE_UUID:-}" ]; then
  echo "  Public URL     : https://${BALENA_DEVICE_UUID}.balena-devices.com"
fi
echo "  Local LAN URL  : https://<device-ip> (or :8443)"
echo "=================================================================="

if [ "${PICOCLAW_GATEWAY_STOP:-false}" = "true" ] || [ "${PICOCLAW_GATEWAY_STOP:-0}" = "1" ]; then
  echo "PICOCLAW_GATEWAY_STOP is enabled. Pausing container for maintenance via 'balena ssh'..."
  sleep infinity
fi

# Start background backup daemon
/app/backup.sh &

# ------------------------------------------------------------------------------
# 8. Launch PicoClaw
# ------------------------------------------------------------------------------
if [ "$PICOCLAW_MODE" = "gateway" ] || [ ! -x "/data/picoclaw/bin/picoclaw-launcher" ]; then
  echo "Starting headless PicoClaw Gateway on 127.0.0.1:18790 (<15MB RAM footprint)..."
  exec /data/picoclaw/bin/picoclaw gateway
else
  echo "Starting PicoClaw WebUI Console & Gateway Manager on 127.0.0.1:18800..."
  exec /data/picoclaw/bin/picoclaw-launcher -console -public -no-browser "$PICOCLAW_CONFIG"
fi
