#!/usr/bin/env bash
# SpacyCloud — Pterodactyl Panel + Wings + Cloudflare Tunnel installer
# https://github.com/REPLACE_WITH_YOUR_USERNAME/SpacyCloud-Installer
#
# Supported: clean Ubuntu 22.04/24.04 or Debian 12 VPS, run as root.
# This installer uses Docker for the Panel and native systemd for Wings.
# Panel origin: 127.0.0.1:3000 | Wings origin: 127.0.0.1:8080 | SFTP: :2022

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME='SpacyCloud installer'
readonly PANEL_VERSION='v1.14.1'
readonly WINGS_VERSION='v1.13.1'
readonly INSTALL_ROOT='/opt/spacycloud-panel'
readonly PANEL_COMPOSE="$INSTALL_ROOT/docker-compose.yml"
readonly WINGS_CONFIG='/etc/pterodactyl/config.yml'
readonly LOG_FILE='/var/log/spacycloud-installer.log'

NON_INTERACTIVE=0
ASSUME_YES=0
FORCE=0
SKIP_CLOUDFLARED=0
SKIP_THEME=0
REPLACE_CLOUDFLARED=0

# Optional non-interactive environment variables:
# PANEL_DOMAIN, WINGS_DOMAIN, CF_TUNNEL_TOKEN, ADMIN_EMAIL, ADMIN_USERNAME,
# ADMIN_PASSWORD, NODE_NAME, LOCATION_SHORT, NODE_MEMORY_MB, NODE_DISK_MB.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
WINGS_DOMAIN="${WINGS_DOMAIN:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
NODE_NAME="${NODE_NAME:-QDNA}"
LOCATION_SHORT="${LOCATION_SHORT:-qdna}"
NODE_MEMORY_MB="${NODE_MEMORY_MB:-}"
NODE_DISK_MB="${NODE_DISK_MB:-}"

c_reset='\033[0m'; c_red='\033[0;31m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_blue='\033[0;34m'; c_cyan='\033[0;36m'

usage() {
    cat <<'EOF'
SpacyCloud Pterodactyl installer

Usage:
  sudo bash install-spacycloud.sh [options]

Options:
  --yes                    Do not ask for the final installation confirmation.
  --non-interactive        Read all values from environment variables.
  --force                  Permit installation into an existing SpacyCloud directory.
  --skip-cloudflared       Do not install/connect Cloudflare Tunnel.
  --replace-cloudflared    Replace an existing cloudflared system service (use carefully).
  --skip-theme             Use the official Panel image without the included SpacyCloud CSS skin.
  -h, --help               Show this help.

Example (interactive, recommended):
  sudo bash install-spacycloud.sh

Example (non-interactive — do NOT put secrets in shell history):
  sudo env PANEL_DOMAIN=games.example.com WINGS_DOMAIN=wings.example.com \
    CF_TUNNEL_TOKEN='your-token' ADMIN_EMAIL='admin@example.com' \
    ADMIN_USERNAME='admin' ADMIN_PASSWORD='use-a-long-password' \
    bash install-spacycloud.sh --non-interactive --yes

Cloudflare requirement:
  Before running with a connector token, configure the SAME remotely-managed
  Cloudflare Tunnel with these two Public Hostnames in Cloudflare Zero Trust:

    PANEL_DOMAIN  -> HTTP -> http://localhost:3000
    WINGS_DOMAIN  -> HTTP -> http://localhost:8080

A connector token authorizes cloudflared to join a tunnel; it does not itself
create Public Hostname routes. The installer verifies both origins locally and
checks public endpoints after cloudflared is connected.
EOF
}

log() { printf '%b[%s]%b %s\n' "$c_blue" "$SCRIPT_NAME" "$c_reset" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    warn "Installer stopped near line $1 (exit $exit_code)."
    warn "The active services were not intentionally removed. Review: $LOG_FILE"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR
# Do not retain a tunnel token or admin password in the parent shell after exit.
trap 'unset CF_TUNNEL_TOKEN ADMIN_PASSWORD DB_PASS ROOT_PASS APP_KEY HASH_SALT' EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die 'Run this installer as root: sudo bash install-spacycloud.sh'
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

validate_domain() {
    local value="$1" label="$2"
    [[ "$value" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] \
        || die "$label must be a valid DNS hostname (for example games.example.com)."
}

validate_username() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die 'Admin username may only contain letters, numbers, dot, underscore, and hyphen.'
}

validate_password() {
    [[ ${#1} -ge 12 ]] || die 'Admin password must be at least 12 characters long.'
}

prompt_value() {
    # prompt_value VARIABLE "Prompt" "default"
    local variable="$1" prompt="$2" default_value="$3" value
    if [[ -n "${!variable:-}" ]]; then
        return 0
    fi
    [[ "$NON_INTERACTIVE" -eq 0 ]] || die "$variable is required when --non-interactive is used."
    read -r -p "$prompt [$default_value]: " value
    printf -v "$variable" '%s' "${value:-$default_value}"
}

prompt_secret() {
    # prompt_secret VARIABLE "Prompt"
    local variable="$1" prompt="$2" value
    if [[ -n "${!variable:-}" ]]; then
        return 0
    fi
    [[ "$NON_INTERACTIVE" -eq 0 ]] || die "$variable is required when --non-interactive is used."
    read -r -s -p "$prompt: " value
    printf '\n'
    printf -v "$variable" '%s' "$value"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) ASSUME_YES=1 ;;
            --non-interactive) NON_INTERACTIVE=1 ;;
            --force) FORCE=1 ;;
            --skip-cloudflared) SKIP_CLOUDFLARED=1 ;;
            --replace-cloudflared) REPLACE_CLOUDFLARED=1 ;;
            --skip-theme) SKIP_THEME=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

preflight_os() {
    [[ -r /etc/os-release ]] || die 'Cannot determine operating system.'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die 'Supported operating systems are Ubuntu 22.04/24.04 and Debian 12.' ;;
    esac

    local total_mb available_mb free_gb
    total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    available_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    free_gb=$(df -BG / | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    [[ "$total_mb" -ge 2048 ]] || die "At least 2 GB RAM is required; this host has ${total_mb} MB."
    [[ "$free_gb" -ge 12 ]] || die "At least 12 GB free disk is required; this host has ${free_gb} GB."
    ok "Preflight passed (${total_mb} MB RAM, ${available_mb} MB currently available, ${free_gb} GB free disk)."
}

collect_configuration() {
    printf '%b\n' "${c_cyan}--- SpacyCloud configuration ---${c_reset}"
    prompt_value PANEL_DOMAIN 'Panel domain' 'games.example.com'
    prompt_value WINGS_DOMAIN 'Wings domain' 'wings.example.com'
    prompt_value ADMIN_EMAIL 'Administrator email' 'admin@example.com'
    prompt_value ADMIN_USERNAME 'Administrator username' 'admin'
    prompt_secret ADMIN_PASSWORD 'Administrator password (minimum 12 characters)'
    prompt_value NODE_NAME 'Wings node name' "$NODE_NAME"
    prompt_value LOCATION_SHORT 'Location short code' "$LOCATION_SHORT"

    local default_memory default_disk
    default_memory=$(( $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) * 70 / 100 ))
    default_disk=$(( $(df -BM / | awk 'NR==2 {gsub(/M/, "", $4); print $4}') * 70 / 100 ))
    prompt_value NODE_MEMORY_MB 'Node memory allocation in MB' "${NODE_MEMORY_MB:-$default_memory}"
    prompt_value NODE_DISK_MB 'Node disk allocation in MB' "${NODE_DISK_MB:-$default_disk}"

    if [[ "$SKIP_CLOUDFLARED" -eq 0 ]]; then
        prompt_secret CF_TUNNEL_TOKEN 'Cloudflare Tunnel connector token'
        [[ -n "$CF_TUNNEL_TOKEN" ]] || die 'A Cloudflare Tunnel connector token is required unless --skip-cloudflared is set.'
    fi

    PANEL_DOMAIN="${PANEL_DOMAIN,,}"
    WINGS_DOMAIN="${WINGS_DOMAIN,,}"
    validate_domain "$PANEL_DOMAIN" 'Panel domain'
    validate_domain "$WINGS_DOMAIN" 'Wings domain'
    [[ "$PANEL_DOMAIN" != "$WINGS_DOMAIN" ]] || die 'Panel and Wings domains must be different.'
    [[ "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Administrator email is invalid.'
    validate_username "$ADMIN_USERNAME"
    validate_password "$ADMIN_PASSWORD"
    [[ "$NODE_NAME" =~ ^[A-Za-z0-9_.\ -]{1,100}$ ]] || die 'Node name has unsupported characters.'
    [[ "$LOCATION_SHORT" =~ ^[A-Za-z0-9_-]{1,60}$ ]] || die 'Location short code has unsupported characters.'
    [[ "$NODE_MEMORY_MB" =~ ^[0-9]+$ && "$NODE_MEMORY_MB" -ge 512 ]] || die 'Node memory must be an integer of at least 512 MB.'
    [[ "$NODE_DISK_MB" =~ ^[0-9]+$ && "$NODE_DISK_MB" -ge 2048 ]] || die 'Node disk must be an integer of at least 2048 MB.'

    log "Panel: https://${PANEL_DOMAIN} -> local HTTP 127.0.0.1:3000"
    log "Wings: https://${WINGS_DOMAIN} -> local HTTP 127.0.0.1:8080, SFTP :2022"
}

confirm_installation() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    printf '%b\n' "${c_yellow}This will install Docker, Pterodactyl Panel, Wings, and optionally cloudflared on this VPS.${c_reset}"
    read -r -p 'Continue? Type INSTALL to continue: ' reply
    [[ "$reply" == 'INSTALL' ]] || die 'Cancelled by user.'
}

apt_install_base() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release openssl tar gzip unzip \
        jq python3 software-properties-common apt-transport-https
}

install_docker() {
    if command_exists docker && docker info >/dev/null 2>&1; then
        ok 'Docker Engine is already installed and responding.'
        return
    fi

    log 'Installing Docker Engine and Docker Compose plugin...'
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/"$(. /etc/os-release && echo "$ID")"/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker info >/dev/null
    ok 'Docker Engine installed.'
}

safe_random() {
    openssl rand -base64 "$1" | tr -d '\n'
}

write_panel_files() {
    local existing_install=0
    if [[ -e "$INSTALL_ROOT" ]]; then
        [[ "$FORCE" -eq 1 ]] || die "$INSTALL_ROOT already exists. Refusing to overwrite it. Use --force only for a deliberate repair/reconfiguration."
        [[ -f "$INSTALL_ROOT/.env" ]] || die "--force was given but $INSTALL_ROOT/.env is missing; refusing to risk an existing database."
        existing_install=1
    fi

    log 'Writing the SpacyCloud Docker Panel stack...'
    install -d -m 0750 "$INSTALL_ROOT" "$INSTALL_ROOT"/{database,redis,panel-var,panel-logs,panel-nginx,theme/public/themes/spacycloud}

    if [[ "$existing_install" -eq 1 ]]; then
        # Preserve the existing encrypted Panel/database secrets on an intentional rerun.
        set -a
        # shellcheck disable=SC1090
        . "$INSTALL_ROOT/.env"
        set +a
        [[ -n "${DB_PASS:-}" && -n "${ROOT_PASS:-}" && -n "${APP_KEY:-}" && -n "${HASH_SALT:-}" ]] \
            || die 'Existing .env is incomplete; refusing to replace Panel secrets.'
        ok 'Existing SpacyCloud secrets were preserved for this --force rerun.'
    else
        DB_PASS="$(safe_random 36)"
        ROOT_PASS="$(safe_random 36)"
        APP_KEY="base64:$(safe_random 32)"
        HASH_SALT="$(safe_random 32)"

        umask 077
        cat > "$INSTALL_ROOT/.env" <<EOF
DB_PASS=${DB_PASS}
ROOT_PASS=${ROOT_PASS}
APP_KEY=${APP_KEY}
HASH_SALT=${HASH_SALT}
EOF
        chmod 600 "$INSTALL_ROOT/.env"
    fi

    local panel_image='ghcr.io/pterodactyl/panel:v1.14.1'
    if [[ "$SKIP_THEME" -eq 0 ]]; then
        panel_image='spacycloud/pterodactyl-panel:v1.14.1-spacycloud'
        write_spacycloud_theme
    fi

    cat > "$PANEL_COMPOSE" <<EOF
services:
  database:
    image: mariadb:11.4
    restart: unless-stopped
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MARIADB_ROOT_PASSWORD: \${ROOT_PASS}
      MARIADB_DATABASE: panel
      MARIADB_USER: pterodactyl
      MARIADB_PASSWORD: \${DB_PASS}
    volumes:
      - ./database:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 18

  cache:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes --save 60 1000
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 18

  panel:
    image: ${panel_image}
    restart: unless-stopped
    depends_on:
      database:
        condition: service_healthy
      cache:
        condition: service_healthy
    environment:
      APP_NAME: SpacyCloud
      APP_ENV: production
      APP_ENVIRONMENT_ONLY: "false"
      APP_URL: https://${PANEL_DOMAIN}
      APP_TIMEZONE: Asia/Kolkata
      APP_SERVICE_AUTHOR: ${ADMIN_EMAIL}
      APP_KEY: \${APP_KEY}
      HASHIDS_SALT: \${HASH_SALT}
      TRUSTED_PROXIES: "*"
      PTERODACTYL_TELEMETRY_ENABLED: "false"
      DB_HOST: database
      DB_PORT: "3306"
      DB_DATABASE: panel
      DB_USERNAME: pterodactyl
      DB_PASSWORD: \${DB_PASS}
      CACHE_DRIVER: redis
      SESSION_DRIVER: redis
      QUEUE_CONNECTION: redis
      REDIS_HOST: cache
      REDIS_PORT: "6379"
      MAIL_MAILER: log
      MAIL_FROM_ADDRESS: noreply@${PANEL_DOMAIN}
      MAIL_FROM_NAME: SpacyCloud
    ports:
      - "127.0.0.1:3000:80"
    volumes:
      - ./panel-var:/app/var
      - ./panel-logs:/app/storage/logs
      - ./panel-nginx:/etc/nginx/http.d
EOF
    chmod 640 "$PANEL_COMPOSE"
}

write_spacycloud_theme() {
    # This is a lightweight, persistent brand skin. It does not modify Panel PHP
    # logic or React application code, so Panel upgrades stay straightforward.
    cat > "$INSTALL_ROOT/theme/Dockerfile" <<'EOF'
FROM ghcr.io/pterodactyl/panel:v1.14.1
USER root
COPY public/themes/spacycloud /app/public/themes/spacycloud
RUN sed -i 's#</head>#<link rel="stylesheet" href="{{ asset('\''themes/spacycloud/spacycloud.css'\'') }}?v=1">\n</head>#' /app/resources/views/templates/wrapper.blade.php
EOF

    cat > "$INSTALL_ROOT/theme/public/themes/spacycloud/spacycloud.css" <<'EOF'
:root { --spacy-cyan:#38d8ff; --spacy-indigo:#6774ff; --spacy-bg:#080d1b; --spacy-card:#111a31; }
html, body { background:var(--spacy-bg)!important; }
body { background-image:radial-gradient(circle at 8% -20%,rgba(56,216,255,.15),transparent 32rem),radial-gradient(circle at 95% 0,rgba(103,116,255,.12),transparent 28rem)!important; }
#NavigationBar { border-bottom:1px solid rgba(123,183,255,.16)!important; background:rgba(8,13,27,.88)!important; backdrop-filter:blur(16px); }
#NavigationBar #logo a { letter-spacing:.025em; background:linear-gradient(100deg,#fff,#8ce9ff); -webkit-background-clip:text; -webkit-text-fill-color:transparent; }
#NavigationBar #logo a::after { content:'SPACYCLOUD'; display:block; font:600 8px/1 sans-serif; letter-spacing:.22em; -webkit-text-fill-color:#38d8ff; margin-top:3px; }
.bg-neutral-700, .bg-neutral-800, .bg-neutral-900 { background-color:var(--spacy-card)!important; }
.rounded { border-color:rgba(145,193,255,.12)!important; }
button.bg-primary-500, .bg-primary-500 { background:linear-gradient(110deg,var(--spacy-cyan),var(--spacy-indigo))!important; color:#07101f!important; font-weight:700!important; }
input, select, textarea { border-color:rgba(111,178,255,.24)!important; background-color:#0c1428!important; }
::-webkit-scrollbar { width:10px; height:10px; } ::-webkit-scrollbar-thumb { background:#26385f; border-radius:999px; } ::-webkit-scrollbar-track { background:#0a1020; }
EOF

    log 'Building persistent SpacyCloud-branded Panel image (first run can take a few minutes)...'
    docker build -t spacycloud/pterodactyl-panel:v1.14.1-spacycloud "$INSTALL_ROOT/theme"
}

wait_for_http() {
    local url="$1" label="$2" attempts="${3:-60}" status
    for ((i=1; i<=attempts; i++)); do
        status=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" || true)
        if [[ "$status" =~ ^(200|301|302|401|403)$ ]]; then
            ok "$label is responding (HTTP $status)."
            return 0
        fi
        sleep 3
    done
    return 1
}

start_panel() {
    log 'Starting Panel, MariaDB, and Redis...'
    docker compose -f "$PANEL_COMPOSE" pull database cache panel
    docker compose -f "$PANEL_COMPOSE" up -d
    wait_for_http 'http://127.0.0.1:3000/' 'Panel origin' 80 \
        || { docker compose -f "$PANEL_COMPOSE" logs --tail=120 panel >&2; die 'Panel did not become healthy on 127.0.0.1:3000.'; }
}

create_admin() {
    local existing
    existing=$(docker compose -f "$PANEL_COMPOSE" exec -T -e SPACY_ADMIN_EMAIL="$ADMIN_EMAIL" panel \
        php artisan tinker --execute='echo \Pterodactyl\Models\User::where("email", getenv("SPACY_ADMIN_EMAIL"))->exists() ? "yes" : "no";' 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$existing" == 'yes' ]]; then
        warn "An account with ${ADMIN_EMAIL} already exists; its password was not changed."
        return
    fi

    log 'Creating Panel administrator...'
    docker compose -f "$PANEL_COMPOSE" exec -T \
        -e SPACY_ADMIN_EMAIL="$ADMIN_EMAIL" \
        -e SPACY_ADMIN_USERNAME="$ADMIN_USERNAME" \
        -e SPACY_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
        panel sh -lc 'php artisan p:user:make --email="$SPACY_ADMIN_EMAIL" --username="$SPACY_ADMIN_USERNAME" --name-first="Spacy" --name-last="Admin" --password="$SPACY_ADMIN_PASSWORD" --admin=1' \
        >/dev/null
    ok 'Panel administrator created.'
}

choose_wings_subnet() {
    local candidate subnet
    for candidate in 30 31 29 28 27 26; do
        subnet="172.${candidate}.0.0/16"
        if ! docker network ls -q | xargs -r -n1 docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -Fqx "$subnet"; then
            printf '%s' "$subnet"
            return 0
        fi
    done
    die 'Could not find a safe private Docker subnet for Wings.'
}

install_wings_binary() {
    local arch asset tmp
    case "$(dpkg --print-architecture)" in
        amd64) asset='wings_linux_amd64' ;;
        arm64) asset='wings_linux_arm64' ;;
        *) die "Unsupported CPU architecture for Wings: $(dpkg --print-architecture)" ;;
    esac
    log "Installing Pterodactyl Wings ${WINGS_VERSION}..."
    tmp=$(mktemp)
    curl -fL --retry 3 --connect-timeout 15 \
        "https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/${asset}" -o "$tmp"
    install -m 0755 "$tmp" /usr/local/bin/wings
    rm -f "$tmp"
    /usr/local/bin/wings version | head -1
}

create_location_and_node() {
    local location_id node_id
    location_id=$(docker compose -f "$PANEL_COMPOSE" exec -T \
        -e SPACY_LOCATION_SHORT="$LOCATION_SHORT" panel php artisan tinker --execute='
            $location = \Pterodactyl\Models\Location::firstOrCreate(
                ["short" => getenv("SPACY_LOCATION_SHORT")],
                ["long" => "SpacyCloud " . strtoupper(getenv("SPACY_LOCATION_SHORT")) . " Location"]
            ); echo $location->id;
        ' 2>/dev/null | tr -d '\r\n')
    [[ "$location_id" =~ ^[0-9]+$ ]] || die 'Could not create/find the Pterodactyl location.'

    node_id=$(docker compose -f "$PANEL_COMPOSE" exec -T \
        -e SPACY_WINGS_DOMAIN="$WINGS_DOMAIN" panel php artisan tinker --execute='
            $node = \Pterodactyl\Models\Node::where("fqdn", getenv("SPACY_WINGS_DOMAIN"))->first();
            echo $node ? $node->id : "";
        ' 2>/dev/null | tr -d '\r\n')

    if [[ -z "$node_id" ]]; then
        # This function returns only the numeric node ID on stdout.
        log "Creating Wings node ${NODE_NAME} in the Panel..." >&2
        docker compose -f "$PANEL_COMPOSE" exec -T panel php artisan p:node:make \
            --name="$NODE_NAME" \
            --description="SpacyCloud ${NODE_NAME} Gaming Node" \
            --locationId="$location_id" \
            --fqdn="$WINGS_DOMAIN" \
            --public=1 --scheme=https --proxy=1 --maintenance=0 \
            --maxMemory="$NODE_MEMORY_MB" --overallocateMemory=0 \
            --maxDisk="$NODE_DISK_MB" --overallocateDisk=0 --uploadSize=100 \
            --daemonListeningPort=443 --daemonSFTPPort=2022 \
            --daemonBase=/var/lib/pterodactyl/volumes >/dev/null
        node_id=$(docker compose -f "$PANEL_COMPOSE" exec -T \
            -e SPACY_WINGS_DOMAIN="$WINGS_DOMAIN" panel php artisan tinker --execute='
                echo \Pterodactyl\Models\Node::where("fqdn", getenv("SPACY_WINGS_DOMAIN"))->value("id");
            ' 2>/dev/null | tr -d '\r\n')
    else
        warn "A node for ${WINGS_DOMAIN} already exists (ID ${node_id}); its resource limits were left unchanged."
    fi
    [[ "$node_id" =~ ^[0-9]+$ ]] || die 'Could not create/find the Pterodactyl Wings node.'
    printf '%s' "$node_id"
}

write_wings_config() {
    local node_id="$1" subnet gateway
    subnet=$(choose_wings_subnet)
    gateway="${subnet%0/16}1"

    install -d -m 0755 /etc/pterodactyl /var/lib/pterodactyl/{volumes,archives,backups} /var/log/pterodactyl
    docker compose -f "$PANEL_COMPOSE" exec -T panel php artisan p:node:configuration "$node_id" --format=yaml > "$WINGS_CONFIG"

    # The Panel connects through Cloudflare at HTTPS/443, while Wings itself is
    # deliberately bound only to localhost:8080 for cloudflared to proxy.
    sed -i '/^api:/,/^system:/ { s/^  host: .*/  host: 127.0.0.1/; s/^  port: .*/  port: 8080/; }' "$WINGS_CONFIG"
    cat >> "$WINGS_CONFIG" <<EOF

docker:
  network:
    interface: ${gateway}
    dns:
      - 1.1.1.1
      - 1.0.0.1
    name: pterodactyl_nw
    driver: bridge
    network_mode: pterodactyl_nw
    is_internal: false
    enable_icc: true
    network_mtu: 1500
    interfaces:
      v4:
        subnet: ${subnet}
        gateway: ${gateway}
      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1011
  container_pid_limit: 512
  installer_limits:
    memory: ${NODE_MEMORY_MB}
    cpu: 250
EOF
    chmod 600 "$WINGS_CONFIG"

    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wings
    sleep 3
    systemctl is-active --quiet wings || { journalctl -u wings --no-pager -n 100 >&2; die 'Wings service failed to start.'; }
    ok "Wings is active with Docker subnet ${subnet}."
}

install_cloudflared() {
    [[ "$SKIP_CLOUDFLARED" -eq 0 ]] || { warn 'Skipping cloudflared by request.'; return; }
    local arch package tmp
    case "$(dpkg --print-architecture)" in
        amd64) package='cloudflared-linux-amd64.deb' ;;
        arm64) package='cloudflared-linux-arm64.deb' ;;
        *) die "Unsupported CPU architecture for cloudflared: $(dpkg --print-architecture)" ;;
    esac

    if ! command_exists cloudflared; then
        log 'Installing cloudflared...'
        tmp=$(mktemp --suffix=.deb)
        curl -fL --retry 3 --connect-timeout 15 \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/${package}" -o "$tmp"
        apt-get install -y "$tmp"
        rm -f "$tmp"
    fi

    if systemctl is-active --quiet cloudflared || systemctl is-enabled --quiet cloudflared 2>/dev/null; then
        if [[ "$REPLACE_CLOUDFLARED" -ne 1 ]]; then
            die 'An existing cloudflared service was found. Refusing to replace it. Use --replace-cloudflared only when this VPS should use the new connector token.'
        fi
        warn 'Replacing the existing cloudflared system service as requested.'
        cloudflared service uninstall || true
    fi

    log 'Registering this VPS as a Cloudflare Tunnel connector...'
    # cloudflared validates the token and writes a root-only systemd service.
    cloudflared service install "$CF_TUNNEL_TOKEN"
    unset CF_TUNNEL_TOKEN
    systemctl daemon-reload
    systemctl enable --now cloudflared
    sleep 3
    systemctl is-active --quiet cloudflared || { journalctl -u cloudflared --no-pager -n 100 >&2; die 'cloudflared service failed to start.'; }
    ok 'cloudflared connector is active.'
}

verify_installation() {
    wait_for_http 'http://127.0.0.1:3000/' 'Panel local origin' 10 || die 'Panel local origin is no longer healthy.'
    local wings_status
    wings_status=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/ || true)
    [[ "$wings_status" == '401' ]] || warn "Expected local Wings HTTP 401 but received '${wings_status:-no response}'. Check: systemctl status wings"

    if [[ "$SKIP_CLOUDFLARED" -eq 0 ]]; then
        sleep 5
        local public_panel public_wings
        public_panel=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "https://${PANEL_DOMAIN}/" || true)
        public_wings=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "https://${WINGS_DOMAIN}/" || true)
        [[ "$public_panel" == '200' ]] && ok 'Panel is public through Cloudflare (HTTP 200).' \
            || warn "Panel public check returned ${public_panel:-no response}. Confirm the Cloudflare Public Hostname maps ${PANEL_DOMAIN} to http://localhost:3000."
        [[ "$public_wings" == '401' ]] && ok 'Wings is public through Cloudflare (HTTP 401 is expected).' \
            || warn "Wings public check returned ${public_wings:-no response}. Confirm the Cloudflare Public Hostname maps ${WINGS_DOMAIN} to http://localhost:8080."
    fi
}

print_summary() {
    cat <<EOF

${c_green}SpacyCloud installation completed.${c_reset}

Panel URL:     https://${PANEL_DOMAIN}
Panel origin:  http://127.0.0.1:3000
Wings domain:  https://${WINGS_DOMAIN}
Wings origin:  http://127.0.0.1:8080 (local-only)
Wings SFTP:    port 2022
Node name:     ${NODE_NAME}

Useful commands:
  cd ${INSTALL_ROOT} && docker compose ps
  systemctl status wings --no-pager
  systemctl status cloudflared --no-pager
  journalctl -u wings -f

Security notes:
  • Panel database and app secrets are in ${INSTALL_ROOT}/.env (root-only).
  • The admin password and Cloudflare token are intentionally not printed or logged.
  • Cloudflare must route ${PANEL_DOMAIN} -> http://localhost:3000
    and ${WINGS_DOMAIN} -> http://localhost:8080.
  • HTTP 401 at the Wings URL is the expected healthy unauthenticated response.
EOF
}

main() {
    parse_args "$@"
    require_root
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    # Log operational output without emitting a password/token (the two variables are
    # never echoed by this script). stderr remains visible for failures.
    exec > >(tee -a "$LOG_FILE") 2>&1

    preflight_os
    collect_configuration
    confirm_installation
    apt_install_base
    install_docker
    write_panel_files
    start_panel
    create_admin
    install_wings_binary
    node_id=$(create_location_and_node)
    write_wings_config "$node_id"
    install_cloudflared
    verify_installation
    print_summary
}

main "$@"
