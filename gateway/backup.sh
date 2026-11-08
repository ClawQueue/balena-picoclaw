#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# PicoClaw RAM-Buffered Cloud Backup Daemon
# Stages snapshots in /tmp (tmpfs in RAM) to avoid SD card / eMMC wear on
# Raspberry Pi Zero and BeagleBone Black devices.
# ==============================================================================

BACKUP_INTERVAL="${BACKUP_INTERVAL:-86400}" # Default: 24 hours
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:picoclaw-backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30d}"

echo "[Backup] Daemon started (interval=${BACKUP_INTERVAL}s, remote=${RCLONE_REMOTE}, retention=${RETENTION_DAYS})."

is_rclone_configured() {
  if ! command -v rclone >/dev/null 2>&1; then
    return 1
  fi
  if [ -f "/root/.config/rclone/rclone.conf" ] && [ -s "/root/.config/rclone/rclone.conf" ]; then
    return 0
  fi
  if [ -f "/data/picoclaw/rclone.conf" ] && [ -s "/data/picoclaw/rclone.conf" ]; then
    export RCLONE_CONFIG="/data/picoclaw/rclone.conf"
    return 0
  fi
  if env | grep -q "^RCLONE_CONFIG_"; then
    return 0
  fi
  return 1
}

while true; do
  # Wait 5 minutes after boot before first check so startup CPU/RAM stays free
  sleep 300

  if ! is_rclone_configured; then
    sleep "$BACKUP_INTERVAL"
    continue
  fi

  TIMESTAMP="$(date +"%Y-%m-%d_%H-%M-%S")"
  STAGING_DIR="/tmp/picoclaw-backup-staging"
  ARCHIVE_PATH="/tmp/picoclaw-backup-${TIMESTAMP}.zip"
  SOURCE_DIR="${PICOCLAW_HOME:-/root/.picoclaw}"

  echo "[Backup] Starting RAM-buffered backup at ${TIMESTAMP}..."
  rm -rf "$STAGING_DIR" "$ARCHIVE_PATH"
  mkdir -p "$STAGING_DIR/picoclaw-home"

  if [ -d "$SOURCE_DIR" ]; then
    # Copy non-database, non-log files into RAM staging directory
    rsync_or_cp() {
      (
        cd "$SOURCE_DIR" || exit 1
        find . -mindepth 1 -maxdepth 1 \
          ! -name "logs" \
          ! -name ".picoclaw.pid" \
          ! -name "picoclaw.pid.json" \
          -exec cp -a {} "$STAGING_DIR/picoclaw-home/" \;
      )
    }
    rsync_or_cp || true

    # Perform safe online SQLite backups for any .db / .sqlite files
    if command -v sqlite3 >/dev/null 2>&1; then
      find "$SOURCE_DIR" -maxdepth 3 \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | while read -r db_file; do
        rel_path="${db_file#"$SOURCE_DIR"/}"
        target_db="$STAGING_DIR/picoclaw-home/$rel_path"
        mkdir -p "$(dirname "$target_db")"
        rm -f "$target_db" "${target_db}-wal" "${target_db}-shm"
        sqlite3 "$db_file" ".backup '$target_db'" 2>/dev/null || cp -f "$db_file" "$target_db"
      done
    fi
  fi

  # Include appliance metadata & credentials
  for meta in /data/picoclaw/active_version /data/picoclaw/gateway.token /data/picoclaw/dashboard.password; do
    if [ -f "$meta" ]; then
      cp -f "$meta" "$STAGING_DIR/"
    fi
  done

  # Compress in RAM (/tmp)
  (cd "$STAGING_DIR" && zip -rq "$ARCHIVE_PATH" .)

  if [ -f "$ARCHIVE_PATH" ]; then
    echo "[Backup] Uploading $(basename "$ARCHIVE_PATH") to ${RCLONE_REMOTE}..."
    if rclone copy "$ARCHIVE_PATH" "$RCLONE_REMOTE"; then
      echo "[Backup] Upload complete. Pruning backups older than ${RETENTION_DAYS}..."
      rclone delete "$RCLONE_REMOTE" --min-age "$RETENTION_DAYS" || true
    else
      echo "[Backup] WARNING: rclone upload failed."
    fi
  fi

  # Free RAM tmpfs immediately
  rm -rf "$STAGING_DIR" "$ARCHIVE_PATH"
  echo "[Backup] Cycle finished. Sleeping for ${BACKUP_INTERVAL}s."

  sleep "$BACKUP_INTERVAL"
done
