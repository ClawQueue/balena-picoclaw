# PicoClaw on Balena (`balena-picoclaw`)

Turn a **Raspberry Pi Zero**, **BeagleBone Black**, or any low-spec single-board computer into a 24/7, self-healing, zero-maintenance **[PicoClaw](https://picoclaw.io/)** AI agent appliance running on **balenaOS**.

Inspired by [`ClawQueue/openclaw-balena`](https://github.com/ClawQueue/openclaw-balena), this stack pairs PicoClaw's ultra-lightweight Go runtime (**<10MB RAM core**) with a hardened, flash-friendly Balena architecture engineered specifically for **512MB RAM** and **microSD / 4GB eMMC** devices.

[![Deploy with balena](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/ClawQueue/balena-picoclaw)

---

## Why PicoClaw + Balena on Low-Spec SBCs?

Standard Node.js/Python AI agent stacks require >1GB RAM and do not support `ARMv6` (Raspberry Pi Zero / Pi 1) or fit comfortably on the BeagleBone Black (`ARMv7`, 512MB RAM, 4GB eMMC).

PicoClaw is written in Go as a single self-contained binary (`CGO_ENABLED=0`). Combined with balenaOS, you get:

- **True `ARMv6` & `ARMv7` Hardware Support**: Automatically detects and installs official pre-compiled static binaries (`armv6`, `armv7`, `arm64`, `riscv64`, `x86_64`) with SHA256 verification—no heavy in-container compilation.
- **Tiny Memory Footprint**:
  - **`launcher` mode (default)**: Runs the full PicoClaw WebUI Console + managed Gateway (`~25–35MB RAM`).
  - **`gateway` mode (ultra-low-memory headless)**: Runs `picoclaw gateway` directly (`<15MB RAM`), freeing maximum memory on constrained boards.
  - Tuned Go garbage collector defaults (`GOMEMLIMIT=128MiB`, `GOGC=50`, HAProxy `nbthread 1`) so the entire appliance stack idles under **50MB RAM**.
- **microSD & eMMC Wear Protection**:
  - Volatile logs (`$PICOCLAW_HOME/logs`), upgrade downloads, and backup staging are mounted in **RAM (`tmpfs`)** so they never wear out your flash storage.
  - All SQLite databases (`launcher-auth.db`, etc.) are automatically configured with `PRAGMA journal_mode=WAL` and `PRAGMA synchronous=NORMAL`.
  - Default snapshot retention is capped at `2` versions to fit comfortably on a BeagleBone Black's 4GB onboard eMMC.
- **Hardware Peripheral Access (`I2C`, `SPI`, `Serial/UART`)**: Built-in support for PicoClaw's hardware tools (`/dev/i2c-*`, `/dev/spidev*`, `/dev/ttyAMA*`, `/dev/ttyO*`, `/dev/ttyS*`) to read sensors and control actuators directly from your AI agent.

---

## Supported Hardware

| Board Family | Architecture | Balena Device Type | RAM | Recommended `PICOCLAW_MODE` |
| :--- | :--- | :--- | :--- | :--- |
| **Raspberry Pi Zero / Zero W / Pi 1** | `ARMv6` (`armhf`) | `raspberry-pi` | 512MB | `launcher` or `gateway` |
| **Orange Pi Zero / One / Lite** | `ARMv7` (`armv7hf`) | `orange-pi-zero` / `orange-pi-one` / `orange-pi-lite` | 256MB–512MB | `launcher` or `gateway` |
| **BeagleBone Black / Green / Pocket** | `ARMv7` (`armv7hf`) | `beaglebone-black` / `beaglebone-green` / `beaglebone-pocket` | 512MB | `launcher` or `gateway` |
| **Raspberry Pi Zero 2 W** | `ARMv7` / `ARM64` | `raspberrypi0-2w-64` / `raspberry-pi2` | 512MB | `launcher` |
| **Raspberry Pi 2 / 3 / 4 / 5** | `ARMv7` / `ARM64` | `raspberry-pi2` / `raspberrypi3` / `raspberrypi4-64` / `raspberrypi5` | 1GB–16GB | `launcher` |
| **Generic x86_64 / Mini PCs** | `amd64` (`x86_64`) | `generic-amd64` | Any | `launcher` |

---

## Architecture Overview

The stack runs two lightweight containers sharing the host network (`network_mode: host`) for mDNS/LAN discovery, webhook listeners, and hardware bus access:

1. **`proxy` (`haproxy:2.9-alpine`, ~8MB RAM)**:
   - Generates a persistent 10-year ECDSA P-256 TLS certificate on `/data/certs/server.pem` (instant `<50ms` generation on a 1GHz ARMv6 CPU).
   - Terminates HTTPS on `:8443` (local LAN) and HTTP on `:80` (Balena Cloud Public Device URL).
   - Preserves `Host`, `X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-Port` headers required by PicoClaw's WebUI CSRF protection and `/pico/ws` WebSocket URL resolver.
   - Automatically fails over from `picoclaw-launcher` (`127.0.0.1:18800`) to headless `picoclaw gateway` (`127.0.0.1:18790`) when `PICOCLAW_MODE=gateway`, and routes `/webhook/*`, `/health`, and `/ready` directly to the gateway.
2. **`gateway` (`alpine:3.21` + official `picoclaw` & `picoclaw-launcher` static binaries)**:
   - Manages versioned snapshots in `/data/picoclaw/versions/<version>/`.
   - Seeds credentials (`dashboard.password` and `gateway.token`), runs first-boot onboarding, configures `.security.yml`, and runs the RAM-buffered `rclone` cloud backup daemon.

---

## Quick Start Deployment

### Option A: One-Click Deploy to Balena Cloud
Click the **Deploy with balena** button at the top of this README, select your target device type (e.g., `Raspberry Pi (v1 / Zero / Zero W)` or `BeagleBone Black`), flash your SD card / eMMC, and power on the board.

### Option B: Deploy via Balena CLI
```bash
git clone https://github.com/ClawQueue/balena-picoclaw.git
cd balena-picoclaw
balena login
balena push <your-fleet-name>
```

---

## Connecting to Your PicoClaw Appliance

### 1. Retrieve Your Credentials from Balena Logs
Once the device boots, look at the **`gateway`** service logs in the Balena Cloud dashboard:

```text
==================================================================
  PicoClaw Balena Appliance
  Version        : v0.3.1 (armv6)
  Runtime Mode   : launcher (GOMEMLIMIT=128MiB, GOGC=50)
  Home Directory : /data/picoclaw/versions/v0.3.1/picoclaw-home
------------------------------------------------------------------
  WebUI Password : <24-char-password>
  Pico WS Token  : <64-char-hex-token>
  Public URL     : https://<uuid>.balena-devices.com
  Local LAN URL  : https://<device-ip>:8443
==================================================================
```

### 2. Access the WebUI Console
- **Via Balena Public Device URL**: Enable **Public Device URL** in the Balena dashboard and open `https://<uuid>.balena-devices.com`.
- **Via Local Network (LAN)**: Open `https://<device-ip>:8443` in your browser and accept the self-signed ECDSA certificate.
- Sign in using the **WebUI Password** printed in the logs (or set your own via `PICOCLAW_DASHBOARD_PASSWORD`).
- From the WebUI, configure your LLM provider API keys (OpenAI, Anthropic, Gemini, DeepSeek, OpenRouter, etc.), enable chat channels (Telegram, Discord, Slack, WhatsApp, Matrix, MQTT, etc.), and chat directly with your agent!

### 3. Headless / CLI Onboarding (`balena ssh`)
If you prefer configuring via CLI or are running in headless `PICOCLAW_MODE=gateway` mode, open a terminal into the `gateway` service from the Balena dashboard (or run `balena ssh <fleet-or-uuid> gateway`):

```bash
# View status and active configuration
picoclaw status

# Interactive chat test
picoclaw agent -m "Hello from my Raspberry Pi Zero!"

# Manage skills, cron jobs, or authentication
picoclaw skills list
picoclaw auth status
```

---

## Configuration & Environment Variables

Set these as **Fleet Variables** or **Device Variables** in the Balena Cloud dashboard:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PICOCLAW_MODE` | `launcher` | `launcher` runs WebUI Console + Gateway (`~25–35MB RAM`). Set to `gateway` for ultra-low-memory headless mode (`<15MB RAM`). |
| `PICOCLAW_VERSION` | `image` | PicoClaw release to run (`image` uses pre-baked binary, `latest` fetches latest GitHub release, or pin e.g. `v0.3.1`). |
| `PICOCLAW_KEEP_VERSIONS` | `2` | Number of version snapshots to keep on `/data/picoclaw/versions` for rollback. |
| `PICOCLAW_DASHBOARD_PASSWORD` | *(auto-generated)* | Custom password for the PicoClaw WebUI Console. Persisted in `/data/picoclaw/dashboard.password`. |
| `PICOCLAW_GATEWAY_TOKEN` | *(auto-generated)* | Custom token for the Pico WebSocket channel (`/pico/ws`). Persisted in `/data/picoclaw/gateway.token`. |
| `PICOCLAW_ENABLE_HARDWARE` | `false` | Set to `true` to enable `i2c`, `spi`, `serial`, and `devices` tools in `config.json`. |
| `PICOCLAW_DEFAULT_MODEL` | *(from config)* | Override default model alias (`agents.defaults.model_name`), e.g. `gpt-5.4`, `gemini-2.5-flash`, `claude-sonnet-4.6`. |
| `PICOCLAW_ALLOW_ORIGINS` | *(auto)* | Comma-separated extra WebSocket CORS origins (e.g., `https://picoclaw.local:8443`). |
| `PICOCLAW_GATEWAY_STOP` | `false` | Set to `true` to pause the container entrypoint (`sleep infinity`) for debugging via `balena ssh`. |
| `GOMEMLIMIT` | `128MiB` | Soft memory limit for the Go runtime garbage collector. |
| `GOGC` | `50` | Go GC aggressiveness (`50` triggers GC earlier than default `100` to keep RSS low). |
| `OPENAI_API_KEY` | *(optional)* | Pre-seeds `gpt-5.4` API key in `.security.yml` on first boot. |
| `ANTHROPIC_API_KEY` | *(optional)* | Pre-seeds `claude-sonnet-4.6` API key in `.security.yml` on first boot. |
| `GEMINI_API_KEY` | *(optional)* | Pre-seeds `gemini-2.5-flash` API key in `.security.yml` on first boot. |
| `DEEPSEEK_API_KEY` | *(optional)* | Pre-seeds `deepseek-chat` API key in `.security.yml` on first boot. |
| `OPENROUTER_API_KEY` | *(optional)* | Pre-seeds `openrouter-auto` API key in `.security.yml` on first boot. |
| `RCLONE_REMOTE` | `gdrive:picoclaw-backups` | Target `rclone` remote path for automated cloud backups. |
| `BACKUP_INTERVAL` | `86400` | Seconds between automated backups (`86400` = 24 hours). |
| `BACKUP_RETENTION_DAYS` | `30d` | Minimum age of remote backup archives before automatic pruning. |
| `PICOCLAW_EXTRA_PKGS` | *(optional)* | Space-separated Alpine packages to install at container boot (e.g. `openssh-client iputils nmap`). |

> **Tip**: All native PicoClaw environment overrides (such as `PICOCLAW_CHANNELS_TELEGRAM_TOKEN`, `PICOCLAW_CHANNELS_DISCORD_TOKEN`, `PICOCLAW_CHANNELS_MQTT_BROKER`, etc.) are also supported out of the box!

---

## Local Customizations & Private Overrides (`gateway/secrets/`)

To keep your fork clean for public Git commits while deploying personal models, OAuth tokens, or LAN tool permissions to your devices, place any of the following git-ignored files inside `gateway/secrets/` (baked at `balena push` time) or `/data/picoclaw/secrets/` on the device:

- **`config.override.json`**: Deep-merged (`jq -s '.[0] * .[1]'`) onto `$PICOCLAW_HOME/config.json` on every boot. See `gateway/secrets/config.override.json.example`.
- **`secrets.env`**: Sourced by `start.sh` at container startup for private environment variables or `PICOCLAW_EXTRA_PKGS`. See `gateway/secrets/secrets.env.example`.
- **`auth.json`**: Pre-seeds OAuth provider credentials (`$PICOCLAW_HOME/auth.json`) on fresh flashes.
- **`.security.yml`**: Overrides `$PICOCLAW_HOME/.security.yml`.
- **`init.sh`**: Custom shell script executed on startup before PicoClaw launches.

---

## Hardware Tools on Raspberry Pi Zero & BeagleBone Black (`I2C` / `SPI` / `UART`)

PicoClaw includes native hardware tools (`i2c`, `spi`, `serial`) that allow your AI agent to scan buses, read sensors (BME280, INA219, MPU6050, etc.), and talk to microcontrollers over UART.

1. Set the device variable `PICOCLAW_ENABLE_HARDWARE=true`.
2. **On Raspberry Pi Zero / Zero 2 W**:
   - In the Balena dashboard under **Device Configuration**, ensure `Define DT parameters` includes `"i2c_arm=on","spi=on"`.
3. **On BeagleBone Black / Green**:
   - The `gateway` container has `SYS_RAWIO` and `/dev` access to `/dev/i2c-*`, `/dev/spidev*`, and `/dev/ttyO*` / `/dev/ttyS*`.

---

## Upgrades, Snapshots & Instant Rollback

Every version of PicoClaw runs inside an isolated snapshot directory at `/data/picoclaw/versions/<version>/`:

```text
/data/picoclaw/
├── active_version               # Currently booted version (e.g. v0.3.1)
├── dashboard.password           # Persistent WebUI Console password
├── gateway.token                # Persistent Pico Channel WebSocket token
├── bin -> versions/v0.3.1/bin   # Symlink to active binaries
└── versions/
    └── v0.3.1/
        ├── bin/
        │   ├── picoclaw
        │   └── picoclaw-launcher
        └── picoclaw-home/       # Isolated $PICOCLAW_HOME for this version
            ├── config.json
            ├── .security.yml
            ├── launcher-config.json
            ├── launcher-auth.db
            └── workspace/
```

- **Upgrading**: Set `PICOCLAW_VERSION=latest` (or a specific tag like `v0.3.2`). On restart, `start.sh` clones your existing `picoclaw-home` state into the new version directory, downloads and SHA256-verifies the release tarball in RAM (`/tmp`), and switches the active symlinks.
- **Automatic Rollback**: If a newly requested version fails download, SHA256 verification, or binary execution check, `start.sh` automatically rolls back to your previous working snapshot.
- **Manual Downgrade**: Change `PICOCLAW_VERSION` back to the previous tag in Balena Cloud—your prior snapshot is still intact on disk.

---

## Automated RAM-Buffered Cloud Backups

To protect your agent's memory, workspace, and configuration against physical SD card loss without causing flash wear:

1. SSH into the `gateway` container (`balena ssh <uuid> gateway`) and run:
   ```bash
   rclone config
   ```
   *(Or place your `rclone.conf` at `/data/picoclaw/rclone.conf` or set `RCLONE_CONFIG_*` environment variables).*
2. Set `RCLONE_REMOTE` (default: `gdrive:picoclaw-backups`).
3. Every 24 hours (`BACKUP_INTERVAL`), `backup.sh` safely snapshots SQLite databases (`sqlite3 .backup`) and workspace files into `/tmp` (RAM `tmpfs`), compresses them in memory, uploads the `.zip` to your cloud remote, and cleans up `/tmp` immediately.

---

## License

MIT License — see [PicoClaw](https://github.com/sipeed/picoclaw) and [openclaw-balena](https://github.com/ClawQueue/openclaw-balena).
