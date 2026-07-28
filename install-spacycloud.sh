#!/usr/bin/env bash
# ==============================================================================
# SpacyCloud Professional Installer
# Pterodactyl Panel • Wings • Cloudflare Tunnel • Theme Manager
# ==============================================================================
# Supported hosts: Ubuntu 22.04/24.04, Debian 12 (systemd required)
# Use on a clean VPS as root. Menu operations are intentionally separate.
#
#  [1] Panel      - Docker Panel + MariaDB + Redis, only local port 3000
#  [2] Wings      - QDNA node + Wings systemd service, only local port 8080
#  [3] Cloudflare - cloudflared + Tunnel connector token, separate operation
#  [4] Theme      - reserved professional Theme Installer (Coming Soon)
#  [5] Status     - non-destructive service/endpoints diagnostics
#  [6] VPS        - local QEMU/KVM cloud-image VPS manager
#
# NEVER commit the generated /opt/spacycloud-panel/.env or a Cloudflare token.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly PRODUCT='SpacyCloud'
readonly PANEL_VERSION='v1.14.1'
readonly WINGS_VERSION='v1.13.1'
readonly INSTALL_ROOT='/opt/spacycloud-panel'
readonly COMPOSE_FILE="$INSTALL_ROOT/docker-compose.yml"
readonly PANEL_ENV="$INSTALL_ROOT/.env"
readonly WINGS_CONFIG='/etc/pterodactyl/config.yml'
readonly STATE_DIR='/etc/spacycloud'
readonly STATE_FILE="$STATE_DIR/installer.env"
readonly VM_ROOT='/var/lib/spacycloud-vms'
readonly VM_CONFIG_DIR='/etc/spacycloud/vms'
readonly VM_RUNNER='/usr/local/sbin/spacycloud-vm-runner'
readonly VM_SERVICE_TEMPLATE='/etc/systemd/system/spacycloud-vm@.service'
readonly LOG_FILE='/var/log/spacycloud-installer.log'
readonly STOCK_PANEL_IMAGE="ghcr.io/pterodactyl/panel:${PANEL_VERSION}"

# State-only values: no password, database secret, application key, or CF token.
PANEL_DOMAIN=''
WINGS_DOMAIN=''
NODE_NAME='QDNA'
LOCATION_SHORT='qdna'
NODE_MEMORY_MB=''
NODE_DISK_MB=''

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'

say()      { printf '%b%s%b\n' "$C_BLUE" "[SpacyCloud] $*" "$C_RESET"; }
ok()       { printf '%b%s%b\n' "$C_GREEN" "[OK] $*" "$C_RESET"; }
warn()     { printf '%b%s%b\n' "$C_YELLOW" "[WARN] $*" "$C_RESET" >&2; }
fail()     { printf '%b%s%b\n' "$C_RED" "[ERROR] $*" "$C_RESET" >&2; return 1; }
die()      { fail "$*"; exit 1; }
line()     { printf '%b%s%b\n' "$C_CYAN" '────────────────────────────────────────────────────────────────────────' "$C_RESET"; }

on_error() {
    local code=$?
    warn "Operation stopped near line $1 (exit ${code})."
    warn "Existing services were not intentionally removed. Log: ${LOG_FILE}"
    return "$code"
}
trap 'on_error $LINENO' ERR
trap 'unset CF_TUNNEL_TOKEN ADMIN_PASSWORD DB_PASS ROOT_PASS APP_KEY HASH_SALT' EXIT

usage() {
    cat <<'EOF'
SpacyCloud Professional Installer

Interactive mode (recommended):
  sudo bash install-spacycloud.sh

The menu provides independent operations:
  1) Install | Panel (install, update, user creation, domain change)
  2) Install | QDNA Wings node
  3) Install | Cloudflare Tunnel connector
  4) Install | Theme
  5) View health/status
  6) Create/manage local QEMU/KVM VPS

Options:
  --panel       Open only the Panel submenu.
  --wings       Run only Wings setup.
  --cloudflare  Run only Cloudflare connector setup.
  --theme       Open only the theme installer.
  --status      Show diagnostics only.
  --vps         Open only the local QEMU/KVM VPS Manager.
  --help        Show this help.

For a normal first installation use the menu in this order:
  1 -> 2 -> 3 -> 4 (theme is optional)
EOF
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die 'Run as root: sudo bash install-spacycloud.sh'
}

has_real_systemd() {
    [[ -d /run/systemd/system ]] && systemctl show-environment >/dev/null 2>&1
}

require_systemd() {
    # Wings and cloudflared service management need a real host init system.
    # The local VPS manager has a no-systemd QEMU workspace mode.
    if ! has_real_systemd; then
        printf '%b%s%b\n' "$C_YELLOW" '[SpacyCloud] This feature needs a real VPS with systemd. Current workspace/container mode cannot run Wings or systemd services.' "$C_RESET"
        printf '%b%s%b\n' "$C_BLUE" '[SpacyCloud] No installation was changed. Upload/commit this script from Codespaces, then run Panel/Wings/Cloudflare on your actual VPS.' "$C_RESET"
        return 1
    fi
    return 0
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

validate_domain() {
    local value="$1" label="$2"
    [[ "$value" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] \
        || die "${label} must be a DNS hostname, for example games.example.com."
}

validate_username() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die 'Username may contain only letters, numbers, dot, underscore, and hyphen.'
}

validate_password() {
    [[ ${#1} -ge 12 ]] || die 'Use an administrator password of at least 12 characters.'
}

validate_number() {
    local value="$1" label="$2" minimum="$3"
    [[ "$value" =~ ^[0-9]+$ && "$value" -ge "$minimum" ]] || die "${label} must be a whole number of at least ${minimum}."
}

load_state() {
    [[ -f "$STATE_FILE" ]] || return 0
    # State file is written by this script with shell-escaped values and contains no secrets.
    # shellcheck disable=SC1090
    . "$STATE_FILE"
}

save_state() {
    install -d -m 0700 "$STATE_DIR"
    umask 077
    {
        printf 'PANEL_DOMAIN=%q\n' "$PANEL_DOMAIN"
        printf 'WINGS_DOMAIN=%q\n' "$WINGS_DOMAIN"
        printf 'NODE_NAME=%q\n' "$NODE_NAME"
        printf 'LOCATION_SHORT=%q\n' "$LOCATION_SHORT"
        printf 'NODE_MEMORY_MB=%q\n' "$NODE_MEMORY_MB"
        printf 'NODE_DISK_MB=%q\n' "$NODE_DISK_MB"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

prompt() {
    # prompt VARIABLE "Text" "default"
    local variable="$1" text="$2" default="$3" input
    read -r -p "${text} [${default}]: " input
    printf -v "$variable" '%s' "${input:-$default}"
}

prompt_required() {
    local variable="$1" text="$2" current="${!1:-}" input
    read -r -p "${text}${current:+ [${current}]}: " input
    printf -v "$variable" '%s' "${input:-$current}"
    [[ -n "${!variable}" ]] || die "${text} is required."
}

prompt_secret() {
    local variable="$1" text="$2" input
    read -r -s -p "${text}: " input
    printf '\n'
    printf -v "$variable" '%s' "$input"
    [[ -n "$input" ]] || die "${text} is required."
}

prompt_cloudflare_token_visible() {
    # Requested visible-input mode. This does not log stdin, but anyone able to
    # see the terminal can see the token. It also accepts a pasted full command.
    local raw extracted
    warn 'Visible token input is enabled as requested. Do not screen-share this step.'
    read -r -p 'Cloudflare connector token (or full cloudflared service install command): ' raw
    extracted=$(printf '%s' "$raw" | grep -oE 'eyJ[A-Za-z0-9_-]+' | tail -n 1 || true)
    [[ -n "$extracted" ]] || die 'No Cloudflare connector token was detected. Copy a fresh token from Cloudflare Zero Trust → Tunnels → Add a connector.'

    # Catch whitespace/markup/copy errors locally before calling cloudflared.
    if ! python3 - "$extracted" <<'PY'
import base64, json, sys
value = sys.argv[1]
try:
    value += '=' * (-len(value) % 4)
    data = json.loads(base64.urlsafe_b64decode(value).decode('utf-8'))
    assert all(key in data for key in ('a', 't', 's'))
except Exception:
    raise SystemExit(1)
PY
    then
        die 'The pasted value is not a valid Cloudflare connector-token format. Generate a fresh token and paste it without quotes or Markdown.'
    fi
    CF_TUNNEL_TOKEN="$extracted"
    unset raw extracted
}

confirm() {
    local text="$1" answer
    read -r -p "${text} Type YES to continue: " answer
    [[ "$answer" == 'YES' ]] || { warn 'Cancelled.'; return 1; }
}

prepare_logging() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

check_os() {
    [[ -r /etc/os-release ]] || die 'Cannot detect the operating system.'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die 'Use Ubuntu 22.04/24.04 or Debian 12 for this installer.' ;;
    esac
}

ensure_common_packages() {
    check_os
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl jq tar gzip unzip python3
}

ensure_docker() {
    require_systemd || return 1
    if command_exists docker && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok 'Docker Engine and Docker Compose plugin are ready.'
        return
    fi

    say 'Installing Docker Engine and Docker Compose plugin...'
    ensure_common_packages
    # shellcheck disable=SC1091
    . /etc/os-release
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker info >/dev/null
    ok 'Docker Engine installed.'
}

random_base64() { openssl rand -base64 "$1" | tr -d '\n'; }

panel_exists() { [[ -f "$COMPOSE_FILE" ]]; }

require_panel() {
    panel_exists || die 'Panel is not installed yet. Select option 1 first.'
    docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1 || die "Panel compose file is invalid: ${COMPOSE_FILE}"
}

get_panel_image() {
    awk '/^  panel:/{in_panel=1; next} in_panel && /^    image:/{print $2; exit} in_panel && /^[^ ]/{exit}' "$COMPOSE_FILE"
}

set_panel_image() {
    local image="$1"
    # Limit replacement to the panel service section, never database/cache images.
    sed -i "/^  panel:/,/^    restart:/ s#^    image:.*#    image: ${image}#" "$COMPOSE_FILE"
}

wait_http() {
    local url="$1" label="$2" attempts="${3:-60}" i status
    for ((i=1; i<=attempts; i++)); do
        status=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" || true)
        if [[ "$status" =~ ^(200|301|302|401|403)$ ]]; then
            ok "${label} responds (HTTP ${status})."
            return 0
        fi
        sleep 3
    done
    return 1
}

write_panel_stack() {
    local panel_image="$1"
    install -d -m 0750 "$INSTALL_ROOT" "$INSTALL_ROOT"/{database,redis,panel-var,panel-logs,panel-nginx,theme/public/themes/spacycloud}

    if [[ ! -f "$PANEL_ENV" ]]; then
        DB_PASS="$(random_base64 36)"
        ROOT_PASS="$(random_base64 36)"
        APP_KEY="base64:$(random_base64 32)"
        HASH_SALT="$(random_base64 32)"
        umask 077
        cat > "$PANEL_ENV" <<EOF
DB_PASS=${DB_PASS}
ROOT_PASS=${ROOT_PASS}
APP_KEY=${APP_KEY}
HASH_SALT=${HASH_SALT}
EOF
        chmod 600 "$PANEL_ENV"
        ok 'Created new root-only Panel secret file.'
    else
        # Never regenerate these values on a repair/reconfigure run: they decrypt
        # node tokens and Panel data, so changing them would break the installation.
        set -a
        # shellcheck disable=SC1090
        . "$PANEL_ENV"
        set +a
        [[ -n "${DB_PASS:-}" && -n "${ROOT_PASS:-}" && -n "${APP_KEY:-}" && -n "${HASH_SALT:-}" ]] \
            || die "${PANEL_ENV} is incomplete; refusing to overwrite existing secrets."
        ok 'Preserved existing Panel/database secrets.'
    fi

    cat > "$COMPOSE_FILE" <<EOF
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
      APP_SERVICE_AUTHOR: noreply@${PANEL_DOMAIN}
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
    chmod 640 "$COMPOSE_FILE"
}

start_panel_stack() {
    local image
    require_panel
    image=$(get_panel_image)
    [[ -n "$image" ]] || die 'Could not determine the Panel image from docker-compose.yml.'

    say 'Starting Panel, MariaDB, and Redis...'
    # A custom theme image is local-only. Pulling it would incorrectly ask Docker
    # Hub for spacycloud/pterodactyl-panel, so only pull it if it is not local.
    if docker image inspect "$image" >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" pull database cache
    else
        docker compose -f "$COMPOSE_FILE" pull database cache panel
    fi
    docker compose -f "$COMPOSE_FILE" up -d
    wait_http 'http://127.0.0.1:3000/' 'Panel local origin' 80 \
        || { docker compose -f "$COMPOSE_FILE" logs --tail=120 panel; die 'Panel did not become healthy on 127.0.0.1:3000.'; }
}

create_panel_user() {
    # email username password admin_flag (1 = administrator, 0 = normal client user)
    local email="$1" username="$2" password="$3" admin_flag="$4" exists role
    exists=$(docker compose -f "$COMPOSE_FILE" exec -T -e SPACY_ADMIN_EMAIL="$email" panel \
        php artisan tinker --execute='echo \Pterodactyl\Models\User::where("email", getenv("SPACY_ADMIN_EMAIL"))->exists() ? "yes" : "no";' \
        2>/dev/null | tr -d '\r\n' || true)

    if [[ "$exists" == 'yes' ]]; then
        warn "A user with ${email} already exists. Its password was not modified."
        return
    fi

    [[ "$admin_flag" == '1' ]] && role='administrator' || role='client user'
    say "Creating Panel ${role}..."
    docker compose -f "$COMPOSE_FILE" exec -T \
        -e SPACY_ADMIN_EMAIL="$email" \
        -e SPACY_ADMIN_USERNAME="$username" \
        -e SPACY_ADMIN_PASSWORD="$password" \
        -e SPACY_ADMIN_FLAG="$admin_flag" \
        panel sh -lc 'php artisan p:user:make --email="$SPACY_ADMIN_EMAIL" --username="$SPACY_ADMIN_USERNAME" --name-first="Spacy" --name-last="User" --password="$SPACY_ADMIN_PASSWORD" --admin="$SPACY_ADMIN_FLAG"' \
        >/dev/null
    ok "Panel ${role} created."
}

install_panel() {
    require_systemd || return 0
    line
    printf '%b%s%b\n' "$C_BOLD" '  [1] PTERODACTYL PANEL INSTALL / REPAIR' "$C_RESET"
    line
    ensure_docker || return 0
    load_state

    prompt_required PANEL_DOMAIN 'Panel public domain (example: games.example.com)'
    PANEL_DOMAIN="${PANEL_DOMAIN,,}"
    validate_domain "$PANEL_DOMAIN" 'Panel domain'

    local admin_email admin_username admin_password panel_image
    prompt_required admin_email 'Panel administrator email'
    [[ "$admin_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Administrator email is invalid.'
    prompt admin_username 'Panel administrator username' 'admin'
    validate_username "$admin_username"
    prompt_secret admin_password 'Panel administrator password (minimum 12 characters)'
    validate_password "$admin_password"

    panel_image="$STOCK_PANEL_IMAGE"
    if panel_exists; then
        panel_image=$(get_panel_image)
        [[ -n "$panel_image" ]] || panel_image="$STOCK_PANEL_IMAGE"
        warn "Existing Panel stack detected. It will be repaired/reconfigured while keeping database and .env secrets."
    fi

    confirm "Install/reconfigure Panel for https://${PANEL_DOMAIN}?" || return 0
    write_panel_stack "$panel_image"
    save_state
    start_panel_stack
    create_panel_user "$admin_email" "$admin_username" "$admin_password" 1
    unset admin_password

    ok "Panel is ready locally at http://127.0.0.1:3000 and configured for https://${PANEL_DOMAIN}."
    warn 'It becomes public only after option 3 connects the Cloudflare Tunnel and its Public Hostname route is configured.'
}

backup_panel_database() {
    require_panel
    local backup_dir backup_file
    backup_dir='/root/spacycloud-backups'
    backup_file="${backup_dir}/panel-$(date +%Y%m%d_%H%M%S).sql.gz"
    install -d -m 0700 "$backup_dir"
    set -a
    # shellcheck disable=SC1090
    . "$PANEL_ENV"
    set +a
    say "Creating Panel database backup: ${backup_file}"
    docker compose -f "$COMPOSE_FILE" exec -T -e MYSQL_PWD="$ROOT_PASS" database \
        mariadb-dump -uroot --single-transaction --routines --events panel | gzip -1 > "$backup_file"
    [[ -s "$backup_file" ]] || die 'Database backup is empty; update cancelled.'
    ok 'Panel database backup created.'
}

fetch_panel_versions() {
    # GitHub provides the official Panel release catalogue. We request several
    # pages so the menu is not limited to the newest 30 releases.
    local page body
    for page in 1 2 3 4; do
        body=$(curl -fsSL --connect-timeout 12 --max-time 30 \
            "https://api.github.com/repos/pterodactyl/panel/releases?per_page=100&page=${page}" || true)
        [[ -n "$body" && "$body" != '[]' ]] || break
        jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' <<<"$body" || true
    done | awk 'NF && !seen[$0]++' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
}

update_panel() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  PANEL UPDATE — OFFICIAL RELEASE CATALOGUE' "$C_RESET"
    line
    require_panel
    ensure_docker || return 0

    local current versions selected_number selected_version
    current=$(get_panel_image)
    say "Current Panel image: ${current}"
    say 'Fetching official stable Pterodactyl Panel releases...'
    mapfile -t versions < <(fetch_panel_versions)
    [[ ${#versions[@]} -gt 0 ]] || die 'Could not fetch the official Panel release list. Check VPS internet access and try again.'

    echo
    printf '%-5s %s\n' 'No.' 'Pterodactyl Panel version'
    line
    local i
    for i in "${!versions[@]}"; do
        printf '%-5s %s\n' "$((i + 1))" "${versions[$i]}"
    done
    echo
    read -r -p 'Enter release number (0 to cancel): ' selected_number
    [[ "$selected_number" == '0' || -z "$selected_number" ]] && return 0
    [[ "$selected_number" =~ ^[0-9]+$ && "$selected_number" -ge 1 && "$selected_number" -le "${#versions[@]}" ]] \
        || die 'Invalid release number.'
    selected_version="${versions[$((selected_number - 1))]}"

    if [[ "$current" == spacycloud/* ]]; then
        warn 'A local custom theme image is currently active.'
        warn "Updating switches to the official ${selected_version} Panel image. Reinstall/rebuild your compatible theme through menu 4 afterward."
    fi
    confirm "Back up the database and update Panel to ${selected_version}?" || return 0
    backup_panel_database

    set_panel_image "ghcr.io/pterodactyl/panel:${selected_version}"
    docker compose -f "$COMPOSE_FILE" pull database cache panel
    docker compose -f "$COMPOSE_FILE" up -d
    wait_http 'http://127.0.0.1:3000/' "Panel ${selected_version} local origin" 100 \
        || { docker compose -f "$COMPOSE_FILE" logs --tail=160 panel; die 'Updated Panel did not become healthy.'; }
    ok "Panel updated to ${selected_version}."
}

panel_create_user() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  [3] PANEL USER MANAGEMENT' "$C_RESET"
    line
    require_panel
    cat <<'EOF'
  [1] Create normal Panel user
  [2] Create Panel administrator
  [0] Back
EOF
    local user_type email username password admin_flag
    read -r -p 'Select user type: ' user_type
    case "$user_type" in
        1) admin_flag=0 ;;
        2) admin_flag=1 ;;
        0|'') return 0 ;;
        *) warn 'Invalid user type.'; return 0 ;;
    esac

    prompt_required email 'User email'
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'User email is invalid.'
    prompt username 'Username' 'user'
    validate_username "$username"
    prompt_secret password 'User password (minimum 12 characters)'
    validate_password "$password"
    confirm "Create ${username} (${email})?" || { unset password; return 0; }
    create_panel_user "$email" "$username" "$password" "$admin_flag"
    unset password
}

panel_change_domain() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  PANEL DOMAIN CHANGE' "$C_RESET"
    line
    require_panel
    load_state
    local previous="$PANEL_DOMAIN"
    prompt_required PANEL_DOMAIN 'New Panel public domain'
    PANEL_DOMAIN="${PANEL_DOMAIN,,}"
    validate_domain "$PANEL_DOMAIN" 'Panel domain'
    [[ "$PANEL_DOMAIN" != "$previous" ]] || { warn 'The Panel domain is unchanged.'; return 0; }
    confirm "Change Panel domain from ${previous:-unset} to ${PANEL_DOMAIN}?" || { PANEL_DOMAIN="$previous"; return 0; }

    local image
    image=$(get_panel_image)
    write_panel_stack "$image"
    # Keep the existing local Wings configuration aligned with the new Panel APP_URL.
    if [[ -f "$WINGS_CONFIG" ]]; then
        sed -i "s#^remote:.*#remote: 'https://${PANEL_DOMAIN}'#" "$WINGS_CONFIG"
        systemctl restart wings || warn 'Wings restart failed; check: systemctl status wings'
    fi
    docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate panel
    wait_http 'http://127.0.0.1:3000/' 'Panel local origin after domain change' 60 \
        || die 'Panel did not become healthy after the domain change.'
    save_state
    ok 'Panel domain was updated locally.'
    warn "Update the Cloudflare Public Hostname so ${PANEL_DOMAIN} maps to http://localhost:3000, then run menu 3/5 to test it."
}

panel_menu() {
    local choice image panel_state state_color
    while true; do
        load_state
        if panel_exists; then
            image=$(get_panel_image)
            panel_state='INSTALLED'
            state_color="$C_GREEN"
        else
            image='—'
            panel_state='NOT INSTALLED'
            state_color="$C_YELLOW"
        fi
        line
        printf '%b%s%b\n' "$C_BOLD" '  [1] INSTALL | PANEL' "$C_RESET"
        line
        printf '  Status : %b%s%b\n' "$state_color" "$panel_state" "$C_RESET"
        printf '  Domain : %s\n' "${PANEL_DOMAIN:-not configured}"
        printf '  Image  : %s\n\n' "$image"
        cat <<'EOF'
  [1] Install / Repair Panel
  [2] Update Panel — show official Pterodactyl versions
  [3] Create users — normal user or administrator
  [4] Change Panel domain
  [5] Panel status
  [0] Back
EOF
        read -r -p 'Select Panel option: ' choice
        case "$choice" in
            1) install_panel ;;
            2) update_panel ;;
            3) panel_create_user ;;
            4) panel_change_domain ;;
            5) show_status ;;
            0|'') return 0 ;;
            *) warn 'Invalid Panel selection.' ;;
        esac
    done
}

choose_wings_subnet() {
    local octet subnet occupied
    occupied=$(docker network ls -q | xargs -r -n1 docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' || true)
    for octet in 30 31 29 28 27 26 25; do
        subnet="172.${octet}.0.0/16"
        if ! grep -Fqx "$subnet" <<<"$occupied"; then
            printf '%s' "$subnet"
            return 0
        fi
    done
    die 'Could not find a free private Docker subnet for Wings.'
}

install_wings_binary() {
    local arch asset tmp
    case "$(dpkg --print-architecture)" in
        amd64) asset='wings_linux_amd64' ;;
        arm64) asset='wings_linux_arm64' ;;
        *) die "Unsupported Wings CPU architecture: $(dpkg --print-architecture)" ;;
    esac
    say "Installing Pterodactyl Wings ${WINGS_VERSION}..."
    tmp=$(mktemp)
    curl -fL --retry 3 --connect-timeout 15 \
        "https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/${asset}" -o "$tmp"
    install -m 0755 "$tmp" /usr/local/bin/wings
    rm -f "$tmp"
    /usr/local/bin/wings version | head -1
}

get_or_create_wings_node() {
    local location_id node_id
    location_id=$(docker compose -f "$COMPOSE_FILE" exec -T -e SPACY_LOCATION_SHORT="$LOCATION_SHORT" panel php artisan tinker --execute='
        $l = \Pterodactyl\Models\Location::firstOrCreate(
            ["short" => getenv("SPACY_LOCATION_SHORT")],
            ["long" => "SpacyCloud " . strtoupper(getenv("SPACY_LOCATION_SHORT")) . " Location"]
        ); echo $l->id;
    ' 2>/dev/null | tr -d '\r\n')
    [[ "$location_id" =~ ^[0-9]+$ ]] || die 'Could not create/find the Panel location.'

    node_id=$(docker compose -f "$COMPOSE_FILE" exec -T -e SPACY_WINGS_DOMAIN="$WINGS_DOMAIN" panel php artisan tinker --execute='
        echo \Pterodactyl\Models\Node::where("fqdn", getenv("SPACY_WINGS_DOMAIN"))->value("id");
    ' 2>/dev/null | tr -d '\r\n' || true)

    if [[ -z "$node_id" ]]; then
        say "Creating ${NODE_NAME} node in the Panel..." >&2
        docker compose -f "$COMPOSE_FILE" exec -T panel php artisan p:node:make \
            --name="$NODE_NAME" \
            --description="SpacyCloud ${NODE_NAME} Gaming Node" \
            --locationId="$location_id" \
            --fqdn="$WINGS_DOMAIN" \
            --public=1 --scheme=https --proxy=1 --maintenance=0 \
            --maxMemory="$NODE_MEMORY_MB" --overallocateMemory=0 \
            --maxDisk="$NODE_DISK_MB" --overallocateDisk=0 --uploadSize=100 \
            --daemonListeningPort=443 --daemonSFTPPort=2022 \
            --daemonBase=/var/lib/pterodactyl/volumes >/dev/null
        node_id=$(docker compose -f "$COMPOSE_FILE" exec -T -e SPACY_WINGS_DOMAIN="$WINGS_DOMAIN" panel php artisan tinker --execute='
            echo \Pterodactyl\Models\Node::where("fqdn", getenv("SPACY_WINGS_DOMAIN"))->value("id");
        ' 2>/dev/null | tr -d '\r\n')
    else
        warn "Existing Wings node for ${WINGS_DOMAIN} found (ID ${node_id}); resource limits are preserved."
    fi
    [[ "$node_id" =~ ^[0-9]+$ ]] || die 'Could not determine Wings node ID.'
    printf '%s' "$node_id"
}

write_wings_config() {
    local node_id="$1" subnet gateway
    subnet=$(choose_wings_subnet)
    gateway="${subnet%0/16}1"

    install -d -m 0755 /etc/pterodactyl /var/lib/pterodactyl/{volumes,archives,backups} /var/log/pterodactyl
    docker compose -f "$COMPOSE_FILE" exec -T panel php artisan p:node:configuration "$node_id" --format=yaml > "$WINGS_CONFIG"

    # Panel reaches the node through the public Cloudflare HTTPS endpoint :443.
    # Wings itself is intentionally local-only on :8080 so cloudflared proxies it.
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
    systemctl is-active --quiet wings || { journalctl -u wings --no-pager -n 120; die 'Wings failed to start.'; }
    ok "Wings is active. API: 127.0.0.1:8080 | SFTP: 0.0.0.0:2022 | game network: ${subnet}"
}

install_wings() {
    require_systemd || return 0
    line
    printf '%b%s%b\n' "$C_BOLD" '  [2] QDNA WINGS INSTALL / CONFIGURE' "$C_RESET"
    line
    ensure_docker || return 0
    load_state
    require_panel

    if [[ -z "$PANEL_DOMAIN" ]]; then
        prompt_required PANEL_DOMAIN 'Panel public domain (the domain used in Panel setup)'
        PANEL_DOMAIN="${PANEL_DOMAIN,,}"
        validate_domain "$PANEL_DOMAIN" 'Panel domain'
    fi
    prompt_required WINGS_DOMAIN 'Wings public domain (example: inwings.example.com)'
    WINGS_DOMAIN="${WINGS_DOMAIN,,}"
    validate_domain "$WINGS_DOMAIN" 'Wings domain'
    [[ "$WINGS_DOMAIN" != "$PANEL_DOMAIN" ]] || die 'Wings domain must differ from Panel domain.'

    prompt NODE_NAME 'Node name' "$NODE_NAME"
    prompt LOCATION_SHORT 'Location short code' "$LOCATION_SHORT"
    [[ "$NODE_NAME" =~ ^[A-Za-z0-9_.\ -]{1,100}$ ]] || die 'Node name contains unsupported characters.'
    [[ "$LOCATION_SHORT" =~ ^[A-Za-z0-9_-]{1,60}$ ]] || die 'Location code contains unsupported characters.'

    local default_memory default_disk node_id
    default_memory=$(( $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) * 70 / 100 ))
    default_disk=$(( $(df -BM / | awk 'NR==2 {gsub(/M/, "", $4); print $4}') * 70 / 100 ))
    prompt NODE_MEMORY_MB 'Node memory allocation in MB' "${NODE_MEMORY_MB:-$default_memory}"
    prompt NODE_DISK_MB 'Node disk allocation in MB' "${NODE_DISK_MB:-$default_disk}"
    validate_number "$NODE_MEMORY_MB" 'Node memory' 512
    validate_number "$NODE_DISK_MB" 'Node disk' 2048

    confirm "Create/configure node ${NODE_NAME} for https://${WINGS_DOMAIN}?" || return 0
    install_wings_binary
    node_id=$(get_or_create_wings_node)
    write_wings_config "$node_id"
    save_state

    local status
    status=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/ || true)
    [[ "$status" == '401' ]] && ok 'Wings local API health check is HTTP 401 (expected).' \
        || warn "Wings local API returned ${status:-no response}; inspect: journalctl -u wings -n 100 --no-pager"
    warn 'Next select option 3 and make sure Cloudflare maps this domain to http://localhost:8080.'
}

install_cloudflared_package() {
    if command_exists cloudflared; then
        ok "cloudflared already installed: $(cloudflared --version | head -1)"
        return
    fi
    ensure_common_packages
    local package tmp
    case "$(dpkg --print-architecture)" in
        amd64) package='cloudflared-linux-amd64.deb' ;;
        arm64) package='cloudflared-linux-arm64.deb' ;;
        *) die "Unsupported cloudflared CPU architecture: $(dpkg --print-architecture)" ;;
    esac
    say 'Installing cloudflared...'
    tmp=$(mktemp --suffix=.deb)
    curl -fL --retry 3 --connect-timeout 15 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/${package}" -o "$tmp"
    apt-get install -y "$tmp"
    rm -f "$tmp"
    ok 'cloudflared installed.'
}

configure_cloudflare() {
    # Deliberately minimal by request: option 3 installs cloudflared when absent,
    # accepts one connector-token paste, and connects. Hostnames/routes are not
    # prompted for or modified here; they remain configured in Cloudflare.
    require_systemd || return 0
    line
    printf '%b%s%b\n' "$C_BOLD" '  [3] INSTALL | CLOUDFLARE TUNNEL' "$C_RESET"
    line
    install_cloudflared_package

    local CF_TUNNEL_TOKEN
    prompt_cloudflare_token_visible
    say 'Connecting cloudflared to the supplied Tunnel token...'

    # A connector service can only hold one token. Replace it automatically so
    # this option remains a single paste-and-connect action as requested.
    if systemctl is-active --quiet cloudflared || systemctl is-enabled --quiet cloudflared 2>/dev/null; then
        systemctl disable --now cloudflared >/dev/null 2>&1 || true
        cloudflared service uninstall >/dev/null 2>&1 || true
    fi

    # cloudflared performs final online validation and creates its root-owned
    # systemd service. It does not create/alter Cloudflare Public Hostnames.
    if ! cloudflared service install "$CF_TUNNEL_TOKEN"; then
        unset CF_TUNNEL_TOKEN
        warn 'Cloudflare rejected this connector token. Generate a fresh token from the active tunnel and paste it again.'
        warn 'Do not reuse a token already exposed in chat or on screen.'
        return 0
    fi
    unset CF_TUNNEL_TOKEN
    systemctl daemon-reload
    systemctl enable --now cloudflared
    sleep 2
    systemctl is-active --quiet cloudflared || { journalctl -u cloudflared --no-pager -n 100; die 'cloudflared service did not start.'; }
    ok 'Cloudflare Tunnel connector is installed and connected.'
}

theme_menu() {
    # Reserved in this release: no bundled or third-party theme is installed.
    line
    printf '%b%s%b\n' "$C_BOLD" '  [4] INSTALL | THEME' "$C_RESET"
    line
    cat <<'EOF'

                    ✦  COMING SOON  ✦

  The SpacyCloud Theme Installer is being prepared.
  No bundled, leaked, or third-party theme is installed by this script.

  Your existing Panel remains unchanged.
EOF
}

show_status() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  [5] SPACYCLOUD STATUS' "$C_RESET"
    line
    load_state
    printf 'Panel domain: %s\nWings domain: %s\nNode: %s\n' "${PANEL_DOMAIN:-not configured}" "${WINGS_DOMAIN:-not configured}" "${NODE_NAME:-not configured}"
    echo

    if panel_exists; then
        echo 'Docker services:'
        docker compose -f "$COMPOSE_FILE" ps || true
        printf 'Panel local HTTP: '
        curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 3 --max-time 8 http://127.0.0.1:3000/ || true
    else
        warn 'Panel stack is not installed.'
    fi

    printf '\nWings: '
    systemctl is-active wings 2>/dev/null || true
    printf 'Wings local HTTP: '
    curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 3 --max-time 8 http://127.0.0.1:8080/ || true
    printf 'cloudflared: '
    systemctl is-active cloudflared 2>/dev/null || true

    if [[ -n "$PANEL_DOMAIN" ]]; then
        printf 'Panel public HTTP: '
        curl -ksS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 --max-time 10 "https://${PANEL_DOMAIN}/" || true
    fi
    if [[ -n "$WINGS_DOMAIN" ]]; then
        printf 'Wings public HTTP: '
        curl -ksS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 --max-time 10 "https://${WINGS_DOMAIN}/" || true
    fi
    echo
    echo "Logs: ${LOG_FILE}"
}

# ==============================================================================
# Local VPS Manager — QEMU/KVM cloud-image virtual machines
# ==============================================================================

vm_config_path() { printf '%s/%s.env' "$VM_CONFIG_DIR" "$1"; }
vm_disk_path() { printf '%s/%s/disk.qcow2' "$VM_ROOT" "$1"; }
vm_seed_path() { printf '%s/%s/seed.iso' "$VM_ROOT" "$1"; }

vm_validate_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,30}$ ]] \
        || die 'VM name must use 1-31 letters, numbers, or hyphens and begin with a letter/number.'
}

vm_validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
        || die 'VM hostname must be a valid single DNS label.'
}

vm_validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'VM username must be lowercase and use letters, digits, underscore, or hyphen.'
}

vm_validate_port() {
    validate_number "$1" "$2" 1
    [[ "$1" -le 65535 ]] || die "$2 must be 65535 or lower."
}

vm_port_is_free() {
    local port="$1"
    ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

vm_require_dependencies() {
    # QEMU works in both real VPS mode (systemd) and a root-enabled workspace.
    # Without /dev/kvm it transparently uses software emulation (TCG).
    [[ "$(dpkg --print-architecture)" == 'amd64' ]] \
        || die 'The VPS Manager currently supports amd64 hosts because its official cloud images are amd64.'

    say 'Checking QEMU/KVM and cloud-image dependencies...'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    # Includes the requested packages plus qemu-utils and socat for disk and live-console management.
    apt-get install -y qemu-system qemu-utils cloud-image-utils wget lsof socat

    install -d -m 0700 "$VM_CONFIG_DIR"
    install -d -m 0755 "$VM_ROOT/images"
    vm_write_runner
    vm_write_service_template

    if [[ -e /dev/kvm ]]; then
        ok 'KVM acceleration is available.'
    else
        warn 'KVM acceleration is unavailable. Workspace VM mode will use slower software emulation (TCG).'
    fi
    if has_real_systemd; then
        ok 'VPS lifecycle mode: systemd service.'
    else
        ok 'VPS lifecycle mode: workspace background process (nohup + PID tracking).'
    fi
}

vm_write_runner() {
    cat > "$VM_RUNNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
name="${1:?VM name is required}"
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,30}$ ]] || exit 2
config="/etc/spacycloud/vms/${name}.env"
root="/var/lib/spacycloud-vms/${name}"
[[ -r "$config" && -f "$root/disk.qcow2" && -f "$root/seed.iso" ]] || exit 3
# Configs are generated root-only by SpacyCloud VPS Manager.
# shellcheck disable=SC1090
. "$config"

if [[ -e /dev/kvm ]]; then
    accel_args=(-accel kvm -cpu host)
else
    accel_args=(-accel tcg -cpu max)
fi

# QEMU exposes guest ttyS0 on a local Unix socket. SpacyCloud attaches the
# invoking terminal with socat so boot messages and the guest login prompt are
# interactive without stopping the VM when the terminal disconnects.
console_socket="${root}/console.sock"
rm -f "$console_socket"

exec /usr/bin/qemu-system-x86_64 \
    -name "$VM_NAME" \
    "${accel_args[@]}" \
    -machine q35 \
    -m "${VM_RAM_MB}M" \
    -smp "$VM_CPU" \
    -boot order=c \
    -drive "file=${root}/disk.qcow2,if=virtio,format=qcow2,cache=none" \
    -drive "file=${root}/seed.iso,if=virtio,format=raw,readonly=on" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp::${VM_SSH_PORT}-:22,hostfwd=tcp::${VM_APP_PORT}-:8080" \
    -display none \
    -monitor none \
    -chardev "socket,id=serial0,path=${console_socket},server=on,wait=off" \
    -serial chardev:serial0 \
    -no-reboot
EOF
    chmod 0755 "$VM_RUNNER"
}

vm_write_service_template() {
    cat > "$VM_SERVICE_TEMPLATE" <<'EOF'
[Unit]
Description=SpacyCloud local VPS (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/spacycloud-vm-runner %i
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    if has_real_systemd; then
        systemctl daemon-reload
    fi
}

vm_load_config() {
    local name="$1" config
    vm_validate_name "$name"
    config=$(vm_config_path "$name")
    [[ -r "$config" ]] || die "VM '${name}' does not exist."
    # Config files are generated by vm_write_config and root-only.
    # shellcheck disable=SC1090
    . "$config"
}

vm_write_config() {
    local config
    config=$(vm_config_path "$VM_NAME")
    umask 077
    {
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'VM_OS_LABEL=%q\n' "$VM_OS_LABEL"
        printf 'VM_IMAGE_URL=%q\n' "$VM_IMAGE_URL"
        printf 'VM_HOSTNAME=%q\n' "$VM_HOSTNAME"
        printf 'VM_USERNAME=%q\n' "$VM_USERNAME"
        printf 'VM_RAM_MB=%q\n' "$VM_RAM_MB"
        printf 'VM_CPU=%q\n' "$VM_CPU"
        printf 'VM_DISK_GB=%q\n' "$VM_DISK_GB"
        printf 'VM_SSH_PORT=%q\n' "$VM_SSH_PORT"
        printf 'VM_APP_PORT=%q\n' "$VM_APP_PORT"
    } > "$config"
    chmod 600 "$config"
}

vm_write_cloud_init() {
    local password="$1" vm_dir password_hash
    vm_dir="$VM_ROOT/$VM_NAME"
    password_hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    umask 077
    cat > "$vm_dir/user-data" <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
manage_etc_hosts: true
users:
  - name: ${VM_USERNAME}
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    passwd: ${password_hash}
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, serial-getty@ttyS0.service ]
EOF
    cat > "$vm_dir/meta-data" <<EOF
instance-id: spacycloud-${VM_NAME}
local-hostname: ${VM_HOSTNAME}
EOF
    cloud-localds "$vm_dir/seed.iso" "$vm_dir/user-data" "$vm_dir/meta-data"
    chmod 600 "$vm_dir/user-data" "$vm_dir/meta-data" "$vm_dir/seed.iso"
    unset password password_hash
}

vm_select_os() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  VPS OPERATING SYSTEM CATALOGUE' "$C_RESET"
    line
    cat <<'EOF'
  [1] Ubuntu Server 20.04 LTS — Focal Fossa
  [2] Ubuntu Server 22.04 LTS — Jammy Jellyfish
  [3] Ubuntu Server 24.04 LTS — Noble Numbat
  [4] Ubuntu Server 26.04 LTS — Resolute Raccoon
  [5] Debian 11 — Bullseye
  [6] Debian 12 — Bookworm
  [7] Debian 13 — Trixie
  [0] Cancel
EOF
    local choice
    read -r -p 'Select operating system: ' choice
    case "$choice" in
        1)
            VM_OS_LABEL='Ubuntu 20.04 LTS (Focal)'
            VM_IMAGE_URL='https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img'
            ;;
        2)
            VM_OS_LABEL='Ubuntu 22.04 LTS (Jammy)'
            VM_IMAGE_URL='https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img'
            ;;
        3)
            VM_OS_LABEL='Ubuntu 24.04 LTS (Noble)'
            VM_IMAGE_URL='https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img'
            ;;
        4)
            VM_OS_LABEL='Ubuntu 26.04 LTS (Resolute)'
            VM_IMAGE_URL='https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img'
            ;;
        5)
            VM_OS_LABEL='Debian 11 (Bullseye)'
            VM_IMAGE_URL='https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2'
            ;;
        6)
            VM_OS_LABEL='Debian 12 (Bookworm)'
            VM_IMAGE_URL='https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2'
            ;;
        7)
            VM_OS_LABEL='Debian 13 (Trixie)'
            VM_IMAGE_URL='https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2'
            ;;
        0|'') return 1 ;;
        *) warn 'Invalid operating-system selection.'; return 1 ;;
    esac
    return 0
}

vm_download_base_image() {
    local filename base part
    filename=$(basename "${VM_IMAGE_URL%%\?*}")
    base="$VM_ROOT/images/$filename"
    if [[ -s "$base" ]]; then
        qemu-img info "$base" >/dev/null 2>&1 || die "Cached image is invalid: ${base}"
        ok "Using cached base image: ${filename}"
    else
        part="${base}.part"
        say "Downloading official cloud image: ${VM_OS_LABEL}"
        rm -f "$part"
        wget --https-only --show-progress --timeout=30 --tries=3 -O "$part" "$VM_IMAGE_URL"
        qemu-img info "$part" >/dev/null 2>&1 || die 'Downloaded cloud image is invalid.'
        mv "$part" "$base"
        chmod 644 "$base"
        ok 'Base cloud image downloaded and verified by qemu-img.'
    fi
    VM_BASE_IMAGE="$base"
}

vm_prompt_free_port() {
    # variable, label, default
    local variable="$1" label="$2" default="$3"
    while true; do
        prompt "$variable" "$label" "$default"
        vm_validate_port "${!variable}" "$label"
        if vm_port_is_free "${!variable}"; then
            return 0
        fi
        warn "Host TCP port ${!variable} is already in use. Choose another port."
        default="${!variable}"
    done
}

vm_create() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  CREATE LOCAL VPS' "$C_RESET"
    line
    vm_require_dependencies || return 0
    vm_select_os || return 0

    local VM_PASSWORD available_ram free_gb
    prompt VM_NAME 'VM name (example: web01)' 'vps01'
    vm_validate_name "$VM_NAME"
    [[ ! -e "$(vm_config_path "$VM_NAME")" ]] || die "VM '${VM_NAME}' already exists. Use Manage VPS instead."
    prompt VM_HOSTNAME 'Guest hostname' "$VM_NAME"
    vm_validate_hostname "$VM_HOSTNAME"
    prompt VM_USERNAME 'Guest username' 'spacy'
    vm_validate_username "$VM_USERNAME"
    prompt_secret VM_PASSWORD 'Guest password (minimum 12 characters)'
    validate_password "$VM_PASSWORD"
    prompt VM_RAM_MB 'RAM in MB' '2048'
    validate_number "$VM_RAM_MB" 'RAM' 512
    prompt VM_CPU 'CPU cores' '2'
    validate_number "$VM_CPU" 'CPU cores' 1
    prompt VM_DISK_GB 'Virtual disk in GB' '20'
    validate_number "$VM_DISK_GB" 'Virtual disk' 8
    vm_prompt_free_port VM_SSH_PORT 'Host SSH port' '2220'
    vm_prompt_free_port VM_APP_PORT 'Host web/application port (guest :8080)' '8080'
    [[ "$VM_SSH_PORT" != "$VM_APP_PORT" ]] || die 'SSH and application host ports must be different.'

    available_ram=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    free_gb=$(df -BG "$VM_ROOT" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if (( VM_RAM_MB > available_ram - 384 )); then
        warn "Requested ${VM_RAM_MB} MB leaves little host RAM (currently ${available_ram} MB available). The VM may cause the host to run out of memory."
    fi
    if (( VM_DISK_GB > free_gb )); then
        warn "Virtual disk is ${VM_DISK_GB} GB but host free disk is ${free_gb} GB. The qcow2 disk starts sparse, but it can fill the host later."
    fi

    cat <<EOF

Selected VPS:
  OS:       ${VM_OS_LABEL}
  Hostname: ${VM_HOSTNAME}
  Username: ${VM_USERNAME}
  RAM:      ${VM_RAM_MB} MB
  CPU:      ${VM_CPU} cores
  Disk:     ${VM_DISK_GB} GB virtual qcow2
  SSH:      host TCP ${VM_SSH_PORT} -> guest TCP 22
  App:      host TCP ${VM_APP_PORT} -> guest TCP 8080
EOF
    confirm 'Create this local VPS?' || { unset VM_PASSWORD; return 0; }

    vm_download_base_image
    install -d -m 0700 "$VM_ROOT/$VM_NAME"
    qemu-img create -f qcow2 -F qcow2 -b "$VM_BASE_IMAGE" "$(vm_disk_path "$VM_NAME")" "${VM_DISK_GB}G"
    vm_write_cloud_init "$VM_PASSWORD"
    unset VM_PASSWORD
    vm_write_config
    if has_real_systemd; then
        systemctl enable "spacycloud-vm@${VM_NAME}.service" >/dev/null
    else
        : > "$VM_ROOT/$VM_NAME/console.log"
        rm -f "$VM_ROOT/$VM_NAME/qemu.pid"
    fi
    ok "VPS '${VM_NAME}' was created. It is currently stopped."
    vm_manage "$VM_NAME"
}

vm_workspace_pid_file() { printf '%s/%s/qemu.pid' "$VM_ROOT" "$1"; }

vm_workspace_running() {
    local name="$1" pid_file pid
    pid_file=$(vm_workspace_pid_file "$name")
    [[ -r "$pid_file" ]] || return 1
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

vm_is_running() {
    local name="$1"
    if has_real_systemd; then
        systemctl is-active --quiet "spacycloud-vm@${name}.service"
    else
        vm_workspace_running "$name"
    fi
}

vm_state() {
    local name="$1"
    if vm_is_running "$name"; then
        printf 'active'
    else
        printf 'inactive'
    fi
}

vm_console_socket() { printf '%s/%s/console.sock' "$VM_ROOT" "$1"; }

vm_attach_console() {
    local name="$1" socket i
    vm_load_config "$name"
    if ! vm_is_running "$name"; then
        warn "VM '${name}' is not running. Select Start VM first."
        return 0
    fi
    socket=$(vm_console_socket "$name")
    for ((i=0; i<30; i++)); do
        [[ -S "$socket" ]] && break
        sleep 1
    done
    [[ -S "$socket" ]] || { warn 'The QEMU serial console socket did not become available. Check VM logs.'; return 0; }

    line
    printf '%b%s%b\n' "$C_BOLD" "  LIVE VM CONSOLE — ${VM_NAME}" "$C_RESET"
    line
    cat <<EOF
  Boot output and the guest login screen are shown below.
  Login user : ${VM_USERNAME}
  SSH port   : ${VM_SSH_PORT}

  To leave this live console and keep the VM running, press Ctrl+].
EOF
    echo
    # escape=0x1d is Ctrl+] and closes only socat, not the guest VM.
    socat STDIO,raw,echo=0,escape=0x1d "UNIX-CONNECT:${socket}" || true
    printf '\n'
    ok 'Detached from live console. The VM remains running.'
}

vm_start() {
    local name="$1" pid_file log_file pid
    vm_load_config "$name"
    if vm_is_running "$name"; then
        warn "VM '${name}' is already running. Opening its live console."
        vm_attach_console "$name"
        return 0
    fi

    if has_real_systemd; then
        systemctl start "spacycloud-vm@${name}.service"
        sleep 2
        if ! vm_is_running "$name"; then
            journalctl -u "spacycloud-vm@${name}.service" --no-pager -n 80 || true
            warn 'VM did not start. Review the service log above.'
            return 0
        fi
    else
        # Codespaces/workspace fallback: QEMU is detached with a tracked PID.
        # It remains a local VM in this workspace, not an external cloud VPS.
        log_file="$VM_ROOT/$name/console.log"
        pid_file=$(vm_workspace_pid_file "$name")
        nohup "$VM_RUNNER" "$name" >> "$log_file" 2>&1 < /dev/null &
        pid=$!
        printf '%s\n' "$pid" > "$pid_file"
        sleep 3
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file"
            tail -n 80 "$log_file" || true
            warn 'Workspace QEMU process exited during boot. Review the console log above.'
            return 0
        fi
    fi

    ok "VM '${name}' is booting. Cloud-init can take 1-3 minutes on first boot."
    say "SSH: ssh -p ${VM_SSH_PORT} ${VM_USERNAME}@HOST_IP"
    say "Guest application forward: HOST_IP:${VM_APP_PORT} -> guest :8080"
    vm_attach_console "$name"
}

vm_stop() {
    local name="$1" pid_file pid i
    if has_real_systemd; then
        systemctl stop "spacycloud-vm@${name}.service" || true
    else
        pid_file=$(vm_workspace_pid_file "$name")
        if [[ -r "$pid_file" ]]; then
            pid=$(cat "$pid_file" 2>/dev/null || true)
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                for ((i=0; i<10; i++)); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 1
                done
                kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    fi
    rm -f "$(vm_console_socket "$name")"
    ok "VM '${name}' stopped."
}

vm_edit_configuration() {
    local name="$1" choice default
    vm_load_config "$name"
    if vm_is_running "$name"; then
        warn 'Stop the VM before changing CPU, RAM, or host ports.'
        return 0
    fi
    line
    printf '%b%s%b\n' "$C_BOLD" "  EDIT VPS CONFIGURATION — ${name}" "$C_RESET"
    line
    cat <<EOF
  [1] Change RAM          (current: ${VM_RAM_MB} MB)
  [2] Change CPU cores    (current: ${VM_CPU})
  [3] Change SSH port     (current: ${VM_SSH_PORT})
  [4] Change app port     (current: ${VM_APP_PORT} -> guest :8080)
  [0] Back
EOF
    read -r -p 'Select setting: ' choice
    case "$choice" in
        1)
            prompt VM_RAM_MB 'New RAM in MB' "$VM_RAM_MB"
            validate_number "$VM_RAM_MB" 'RAM' 512
            ;;
        2)
            prompt VM_CPU 'New CPU cores' "$VM_CPU"
            validate_number "$VM_CPU" 'CPU cores' 1
            ;;
        3)
            default="$VM_SSH_PORT"
            vm_prompt_free_port VM_SSH_PORT 'New host SSH port' "$default"
            [[ "$VM_SSH_PORT" != "$VM_APP_PORT" ]] || die 'SSH and application ports must be different.'
            ;;
        4)
            default="$VM_APP_PORT"
            vm_prompt_free_port VM_APP_PORT 'New host application port' "$default"
            [[ "$VM_SSH_PORT" != "$VM_APP_PORT" ]] || die 'SSH and application ports must be different.'
            ;;
        0|'') return 0 ;;
        *) warn 'Invalid setting.'; return 0 ;;
    esac
    vm_write_config
    ok 'VPS configuration saved. Start the VM to apply it.'
}

vm_delete() {
    local name="$1"
    confirm "Permanently delete VPS '${name}' and its virtual disk?" || return 0
    if has_real_systemd; then
        systemctl disable --now "spacycloud-vm@${name}.service" >/dev/null 2>&1 || true
    else
        vm_stop "$name" >/dev/null 2>&1 || true
    fi
    rm -f "$(vm_config_path "$name")"
    rm -rf "$VM_ROOT/$name"
    ok "VPS '${name}' was deleted. Cached base images were preserved."
}

vm_manage() {
    local name="$1" choice state
    vm_validate_name "$name"
    [[ -f "$(vm_config_path "$name")" ]] || { warn "VPS '${name}' does not exist."; return 0; }

    while true; do
        vm_load_config "$name"
        state=$(vm_state "$name")
        line
        printf '%b%s%b\n' "$C_BOLD" "  VPS MANAGER — ${VM_NAME}" "$C_RESET"
        line
        printf '  User     : %s\n' "$VM_USERNAME"
        printf '  OS       : %s\n' "$VM_OS_LABEL"
        printf '  Hostname : %s\n' "$VM_HOSTNAME"
        printf '  Status   : %s\n' "${state:-inactive}"
        printf '  Resources: %s MB RAM | %s CPU cores | %s GB disk\n' "$VM_RAM_MB" "$VM_CPU" "$VM_DISK_GB"
        printf '  Ports    : SSH %s -> 22 | App %s -> 8080\n\n' "$VM_SSH_PORT" "$VM_APP_PORT"
        cat <<'EOF'
  [1] Start VM
  [2] Stop VM
  [3] Restart VM
  [4] Edit configuration
  [5] View boot/service logs
  [6] Delete VPS
  [7] Open live console
  [0] Back
EOF
        read -r -p 'Select VPS action: ' choice
        case "$choice" in
            1) vm_start "$name" ;;
            2) vm_stop "$name" ;;
            3) vm_stop "$name"; vm_start "$name" ;;
            4) vm_edit_configuration "$name" ;;
            5)
                if has_real_systemd; then
                    journalctl -u "spacycloud-vm@${name}.service" --no-pager -n 120 || true
                else
                    tail -n 120 "$VM_ROOT/$name/console.log" 2>/dev/null || warn 'No workspace console log exists yet.'
                fi
                ;;
            6) vm_delete "$name"; return 0 ;;
            7) vm_attach_console "$name" ;;
            0|'') return 0 ;;
            *) warn 'Invalid VPS action.' ;;
        esac
    done
}

vm_list() {
    local config name state
    shopt -s nullglob
    local configs=("$VM_CONFIG_DIR"/*.env)
    shopt -u nullglob
    if [[ ${#configs[@]} -eq 0 ]]; then
        warn 'No local VPS exists yet.'
        return 0
    fi
    printf '%-14s %-14s %-28s %-10s %-8s %-8s %-9s %-9s\n' 'USER' 'NAME' 'OS' 'STATE' 'RAM' 'CPU' 'SSH' 'APP'
    line
    for config in "${configs[@]}"; do
        name=$(basename "$config" .env)
        vm_load_config "$name"
        state=$(vm_state "$name")
        printf '%-14s %-14s %-28s %-10s %-8s %-8s %-9s %-9s\n' \
            "$VM_USERNAME" "$VM_NAME" "$VM_OS_LABEL" "${state:-inactive}" \
            "${VM_RAM_MB}M" "$VM_CPU" "$VM_SSH_PORT" "$VM_APP_PORT"
    done
}

vps_menu() {
    # Supports real VPS mode and Codespaces/workspace QEMU fallback mode.
    while true; do
        line
        printf '%b%s%b\n' "$C_BOLD" '  [6] LOCAL VPS MANAGER' "$C_RESET"
        line
        cat <<'EOF'
  [1] Create VPS
  [2] List VPS instances
  [3] Manage existing VPS
  [0] Back
EOF
        local choice name
        read -r -p 'Select VPS option: ' choice
        case "$choice" in
            1) vm_create ;;
            2) vm_list ;;
            3)
                vm_list
                read -r -p 'Enter VPS name to manage: ' name
                [[ -n "$name" ]] && vm_manage "$name"
                ;;
            0|'') return 0 ;;
            *) warn 'Invalid VPS selection.' ;;
        esac
    done
}

print_menu() {
    clear 2>/dev/null || true
    printf '%b\n' "${C_CYAN}"
    cat <<'EOF'
   _____                         ________                __
  / ___/____  ____ __________  / ____/ /___  __  ______/ /
  \__ \/ __ \/ __ `/ ___/ _ \/ /   / / __ \/ / / / __  /
 ___/ / /_/ / /_/ / /__/  __/ /___/ / /_/ / /_/ / /_/ /
/____/ .___/\__,_/\___/\___/\____/_/\____/\__,_/\__,_/
    /_/
EOF
    printf '%b\n' "$C_RESET"
    printf 'Pterodactyl Panel • Wings • Cloudflare Tunnel • Local VPS Manager\n'
    if has_real_systemd; then
        printf '%b%s%b\n\n' "$C_GREEN" '● VPS MODE — systemd services available' "$C_RESET"
    else
        printf '%b%s%b\n\n' "$C_YELLOW" '● DEVELOPER WORKSPACE MODE — Panel/Wings/Cloudflare need a real VPS; option 6 runs local QEMU VPS mode (TCG if no KVM)' "$C_RESET"
    fi
    cat <<'EOF'
  [1] Install | Panel
  [2] Install | QDNA Wings
  [3] Install | Cloudflare Tunnel
  [4] Install | Theme
  [5] Health & Status
  [6] VPS Manager
  [0] Exit
EOF
    echo
}

interactive_menu() {
    local choice
    while true; do
        print_menu
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) panel_menu ;;
            2) install_wings ;;
            3) configure_cloudflare ;;
            4) theme_menu ;;
            5) show_status ;;
            6) vps_menu ;;
            0|'') say 'Goodbye.'; return 0 ;;
            *) warn 'Choose a number from the menu.' ;;
        esac
        echo
        read -r -p 'Press Enter to return to the menu...' _
    done
}

install_self_command() {
    # Best effort only. A raw curl process-substitution source can disappear after
    # exit, so installing a local command is convenient but never required.
    local source="$0"
    [[ -r "$source" ]] || return 0
    install -d -m 0755 /usr/local/sbin
    cp "$source" /usr/local/sbin/spacycloud 2>/dev/null || true
    chmod 0755 /usr/local/sbin/spacycloud 2>/dev/null || true
}

main() {
    # Help is intentionally available without root and without creating a log file.
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
    esac

    require_root
    prepare_logging
    install_self_command
    case "${1:-}" in
        '') interactive_menu ;;
        --panel) panel_menu ;;
        --wings) install_wings ;;
        --cloudflare) configure_cloudflare ;;
        --theme) theme_menu ;;
        --status) show_status ;;
        --vps) vps_menu ;;
        *) usage; die "Unknown option: $1" ;;
    esac
}

main "$@"
