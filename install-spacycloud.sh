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
#  [4] Theme      - built-in SpacyCloud skin / CSS URL / full React overlay
#  [5] Status     - non-destructive diagnostics
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
readonly LOG_FILE='/var/log/spacycloud-installer.log'
readonly STOCK_PANEL_IMAGE="ghcr.io/pterodactyl/panel:${PANEL_VERSION}"
readonly SPACYCLOUD_PANEL_IMAGE="spacycloud/pterodactyl-panel:${PANEL_VERSION}-spacycloud"
readonly OVERLAY_PANEL_IMAGE="spacycloud/pterodactyl-panel:${PANEL_VERSION}-custom"

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

Options:
  --panel       Open only the Panel submenu.
  --wings       Run only Wings setup.
  --cloudflare  Run only Cloudflare connector setup.
  --theme       Open only the theme installer.
  --status      Show diagnostics only.
  --help        Show this help.

For a normal first installation use the menu in this order:
  1 -> 2 -> 3 -> 4 (theme is optional)
EOF
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die 'Run as root: sudo bash install-spacycloud.sh'
}

require_systemd() {
    [[ -d /run/systemd/system ]] || die 'This operation needs a normal systemd VPS (not a Codespace/container).'
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
    require_systemd
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
    require_systemd
    line
    printf '%b%s%b\n' "$C_BOLD" '  [1] PTERODACTYL PANEL INSTALL / REPAIR' "$C_RESET"
    line
    ensure_docker
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
    ensure_docker

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
    printf '%b%s%b\n' "$C_BOLD" '  PANEL USER CREATOR' "$C_RESET"
    line
    require_panel
    local email username password admin_choice admin_flag
    prompt_required email 'User email'
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'User email is invalid.'
    prompt username 'Username' 'user'
    validate_username "$username"
    prompt_secret password 'User password (minimum 12 characters)'
    validate_password "$password"
    read -r -p 'Make this user a Panel administrator? [y/N]: ' admin_choice
    [[ "${admin_choice,,}" == 'y' || "${admin_choice,,}" == 'yes' ]] && admin_flag=1 || admin_flag=0
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
    while true; do
        line
        printf '%b%s%b\n' "$C_BOLD" '  [1] INSTALL | PANEL' "$C_RESET"
        line
        cat <<'EOF'
  [1] Install / Repair Panel
  [2] Update Panel — list official versions
  [3] Create Panel user / administrator
  [4] Change Panel domain
  [5] Panel status
  [0] Back
EOF
        local choice
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
    require_systemd
    line
    printf '%b%s%b\n' "$C_BOLD" '  [2] QDNA WINGS INSTALL / CONFIGURE' "$C_RESET"
    line
    ensure_docker
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
    require_systemd
    line
    printf '%b%s%b\n' "$C_BOLD" '  [3] CLOUDFLARE TUNNEL CONNECTOR' "$C_RESET"
    line
    load_state
    install_cloudflared_package

    prompt_required PANEL_DOMAIN 'Panel hostname routed through Cloudflare'
    prompt_required WINGS_DOMAIN 'Wings hostname routed through Cloudflare'
    PANEL_DOMAIN="${PANEL_DOMAIN,,}"; WINGS_DOMAIN="${WINGS_DOMAIN,,}"
    validate_domain "$PANEL_DOMAIN" 'Panel domain'
    validate_domain "$WINGS_DOMAIN" 'Wings domain'

    cat <<EOF

Configure these Public Hostnames in Cloudflare Zero Trust BEFORE continuing:
  ${PANEL_DOMAIN}  -> HTTP -> http://localhost:3000
  ${WINGS_DOMAIN}  -> HTTP -> http://localhost:8080

Paste only the long connector token, not the entire 'cloudflared service install ...' command.
EOF
    local CF_TUNNEL_TOKEN
    prompt_cloudflare_token_visible
    confirm 'Install this connector token as the cloudflared system service?' || { unset CF_TUNNEL_TOKEN; return 0; }

    if systemctl is-active --quiet cloudflared || systemctl is-enabled --quiet cloudflared 2>/dev/null; then
        warn 'An existing cloudflared service was found.'
        confirm 'Replace the existing cloudflared service on this VPS?' || { unset CF_TUNNEL_TOKEN; return 0; }
        cloudflared service uninstall || true
    fi

    # cloudflared performs the final online token validation and creates a
    # root-owned systemd service. A structurally-valid token can still be stale,
    # revoked, or from a deleted tunnel, so handle that cleanly and return to menu.
    if ! cloudflared service install "$CF_TUNNEL_TOKEN"; then
        unset CF_TUNNEL_TOKEN
        warn 'Cloudflare rejected this connector token. Generate a fresh token from the active tunnel and paste it again.'
        warn 'Do not reuse the token that was pasted into chat or exposed on screen.'
        return 0
    fi
    unset CF_TUNNEL_TOKEN
    systemctl daemon-reload
    systemctl enable --now cloudflared
    sleep 3
    systemctl is-active --quiet cloudflared || { journalctl -u cloudflared --no-pager -n 100; die 'cloudflared service did not start.'; }
    save_state
    ok 'Cloudflare Tunnel connector is active.'

    local panel_http wings_http
    panel_http=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "https://${PANEL_DOMAIN}/" || true)
    wings_http=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "https://${WINGS_DOMAIN}/" || true)
    [[ "$panel_http" == '200' ]] && ok 'Panel public endpoint: HTTP 200.' \
        || warn "Panel public endpoint: ${panel_http:-no response}. Check the Public Hostname mapping to localhost:3000."
    [[ "$wings_http" == '401' ]] && ok 'Wings public endpoint: HTTP 401 (healthy expected result).' \
        || warn "Wings public endpoint: ${wings_http:-no response}. Check the Public Hostname mapping to localhost:8080."
}

write_css_theme_dockerfile() {
    local css_source="$1"
    install -d -m 0750 "$INSTALL_ROOT/theme/public/themes/spacycloud"
    if [[ "$css_source" == 'builtin' ]]; then
        cat > "$INSTALL_ROOT/theme/public/themes/spacycloud/spacycloud.css" <<'EOF'
:root { --spacy-cyan:#38d8ff; --spacy-indigo:#6e7dff; --spacy-bg:#080d1b; --spacy-card:#101a32; }
html,body { background:var(--spacy-bg)!important; }
body { background-image:radial-gradient(circle at 8% -20%,rgba(56,216,255,.15),transparent 32rem),radial-gradient(circle at 95% 0,rgba(103,116,255,.12),transparent 28rem)!important; }
#NavigationBar { border-bottom:1px solid rgba(123,183,255,.16)!important; background:rgba(8,13,27,.9)!important; backdrop-filter:blur(16px); }
#NavigationBar #logo a { letter-spacing:.025em; background:linear-gradient(100deg,#fff,#8ce9ff); -webkit-background-clip:text; -webkit-text-fill-color:transparent; }
#NavigationBar #logo a::after { content:'SPACYCLOUD'; display:block; font:600 8px/1 sans-serif; letter-spacing:.22em; -webkit-text-fill-color:#38d8ff; margin-top:3px; }
.bg-neutral-700,.bg-neutral-800,.bg-neutral-900 { background-color:var(--spacy-card)!important; }
.rounded { border-color:rgba(145,193,255,.12)!important; }
button.bg-primary-500,.bg-primary-500 { background:linear-gradient(110deg,var(--spacy-cyan),var(--spacy-indigo))!important; color:#07101f!important; font-weight:700!important; }
input,select,textarea { border-color:rgba(111,178,255,.24)!important; background-color:#0c1428!important; }
::-webkit-scrollbar { width:10px;height:10px; } ::-webkit-scrollbar-thumb { background:#26385f;border-radius:999px; } ::-webkit-scrollbar-track { background:#0a1020; }
EOF
    else
        curl -fL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$css_source" \
            -o "$INSTALL_ROOT/theme/public/themes/spacycloud/spacycloud.css"
        [[ -s "$INSTALL_ROOT/theme/public/themes/spacycloud/spacycloud.css" ]] || die 'Downloaded CSS theme is empty.'
    fi

    # Fixed root-relative CSS URL avoids Blade quoting/escaping issues in Docker RUN.
    cat > "$INSTALL_ROOT/theme/Dockerfile" <<EOF
FROM ${STOCK_PANEL_IMAGE}
USER root
COPY public/themes/spacycloud /app/public/themes/spacycloud
EOF
    cat >> "$INSTALL_ROOT/theme/Dockerfile" <<'EOF'
RUN sed -i 's|</head>|<link rel="stylesheet" href="/themes/spacycloud/spacycloud.css?v=1"></head>|' /app/resources/views/templates/wrapper.blade.php
EOF
}

activate_local_panel_image() {
    local image="$1"
    docker image inspect "$image" >/dev/null 2>&1 || die "Local image does not exist: ${image}"
    set_panel_image "$image"
    # Do NOT call compose pull panel here: this image is intentionally local.
    docker compose -f "$COMPOSE_FILE" pull database cache
    docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate panel
    wait_http 'http://127.0.0.1:3000/' 'Themed Panel local origin' 60 \
        || { docker compose -f "$COMPOSE_FILE" logs --tail=120 panel; die 'Themed Panel did not become healthy.'; }
}

install_css_theme() {
    local source="$1"
    say 'Building the local SpacyCloud CSS theme image...'
    write_css_theme_dockerfile "$source"
    docker build -t "$SPACYCLOUD_PANEL_IMAGE" "$INSTALL_ROOT/theme"
    activate_local_panel_image "$SPACYCLOUD_PANEL_IMAGE"
    ok 'SpacyCloud CSS skin is active.'
}

install_overlay_theme() {
    local url tmp archive
    read -r -p 'Public HTTPS URL of your full theme overlay .tar.gz: ' url
    [[ "$url" =~ ^https:// ]] || die 'Use a public HTTPS URL to a .tar.gz theme overlay.'
    confirm 'Download, compile, and activate this full theme overlay?' || return 0

    install -d -m 0750 "$INSTALL_ROOT/theme"
    tmp=$(mktemp)
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 "$url" -o "$tmp"
    tar -tzf "$tmp" >/dev/null || die 'Theme download is not a valid gzip tar archive.'
    archive="$INSTALL_ROOT/theme/theme-overlay.tar.gz"
    mv "$tmp" "$archive"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 \
        "https://github.com/pterodactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz" \
        -o "$INSTALL_ROOT/theme/panel.tar.gz"

    cat > "$INSTALL_ROOT/theme/Dockerfile.overlay" <<EOF
FROM node:22-alpine AS builder
RUN apk add --no-cache tar python3 make g++
WORKDIR /app
COPY panel.tar.gz /tmp/panel.tar.gz
RUN tar -xzf /tmp/panel.tar.gz -C /app
COPY theme-overlay.tar.gz /tmp/theme-overlay.tar.gz
RUN tar -xzf /tmp/theme-overlay.tar.gz -C /app && mkdir -p /app/public/themes
RUN yarn install --frozen-lockfile
RUN NODE_OPTIONS='--max-old-space-size=1536 --openssl-legacy-provider' yarn build:production

FROM ${STOCK_PANEL_IMAGE}
COPY --from=builder /app/public/assets /app/public/assets
COPY --from=builder /app/public/themes /app/public/themes
COPY --from=builder /app/resources/views/templates/wrapper.blade.php /app/resources/views/templates/wrapper.blade.php
COPY --from=builder /app/resources/views/layouts/admin.blade.php /app/resources/views/layouts/admin.blade.php
EOF
    say 'Building full React theme image. This can use substantial CPU/RAM and take several minutes...'
    docker build -f "$INSTALL_ROOT/theme/Dockerfile.overlay" -t "$OVERLAY_PANEL_IMAGE" "$INSTALL_ROOT/theme"
    activate_local_panel_image "$OVERLAY_PANEL_IMAGE"
    ok 'Full custom overlay theme is active.'
}

theme_menu() {
    line
    printf '%b%s%b\n' "$C_BOLD" '  [4] THEME INSTALLER' "$C_RESET"
    line
    require_panel
    ensure_docker
    cat <<'EOF'
1) Built-in SpacyCloud premium CSS skin
2) Install a custom CSS theme from a public HTTPS URL
3) Install your full React/Pterodactyl overlay (.tar.gz URL)
0) Back
EOF
    local choice css_url
    read -r -p 'Select theme option: ' choice
    case "$choice" in
        1) confirm 'Build and activate the built-in SpacyCloud skin?' && install_css_theme builtin ;;
        2)
            read -r -p 'Public HTTPS URL of the CSS file: ' css_url
            [[ "$css_url" =~ ^https:// ]] || die 'Use a public HTTPS URL.'
            confirm 'Download, build, and activate this CSS theme?' && install_css_theme "$css_url"
            ;;
        3) install_overlay_theme ;;
        0|'') return 0 ;;
        *) warn 'Invalid theme selection.' ;;
    esac
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
    printf 'Pterodactyl Panel • Wings • Cloudflare Tunnel • Theme Manager\n\n'
    cat <<'EOF'
  [1] Install | Panel
  [2] Install | QDNA Wings
  [3] Install | Cloudflare Tunnel
  [4] Install | Theme
  [5] Health & Status
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
        *) usage; die "Unknown option: $1" ;;
    esac
}

main "$@"
