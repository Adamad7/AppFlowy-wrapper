#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AppFlowy Cloud - Interactive Version Updater
# =============================================================================
# Fetches available official versions from Docker Hub, allows selection,
# performs pre-update safety backup, updates .env, and runs deployment.
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$1"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Prerequisites check
# -----------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || error "'curl' is required. Install it with: apt-get install -y curl"
command -v docker >/dev/null 2>&1 || error "Docker is not installed."
docker compose version >/dev/null 2>&1 || error "Docker Compose V2 is required."

if [ ! -f .env ]; then
    error ".env file not found. Run 'bash setup.sh' first to initialize your deployment."
fi

# Load current versions from .env
CURRENT_APPFLOWY_VER=$(grep -E '^[[:space:]]*APPFLOWY_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_WEB_VER=$(grep -E '^[[:space:]]*APPFLOWY_WEB_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_APPFLOWY_VER="${CURRENT_APPFLOWY_VER:-0.12.0}"
CURRENT_WEB_VER="${CURRENT_WEB_VER:-0.10.5}"

printf '\n\033[1m=== AppFlowy Cloud Version Updater ===\033[0m\n'
info "Current AppFlowy Core Version: \033[1m${CURRENT_APPFLOWY_VER}\033[0m"
info "Current AppFlowy Web Version:  \033[1m${CURRENT_WEB_VER}\033[0m\n"

# -----------------------------------------------------------------------------
# 2. Fetch available versions from Docker Hub API
# -----------------------------------------------------------------------------
info "Fetching available releases from official Docker Hub (appflowyinc/appflowy_cloud)..."

API_RESPONSE=$(curl -s --connect-timeout 8 "https://hub.docker.com/v2/repositories/appflowyinc/appflowy_cloud/tags?page_size=50" 2>/dev/null || true)

AVAILABLE_VERSIONS=()
if [ -n "$API_RESPONSE" ]; then
    if command -v jq >/dev/null 2>&1; then
        mapfile -t AVAILABLE_VERSIONS < <(echo "$API_RESPONSE" | jq -r '.results[].name' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V -r | head -n 15)
    else
        mapfile -t AVAILABLE_VERSIONS < <(echo "$API_RESPONSE" | grep -oP '"name":\s*"\K[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V -r | uniq | head -n 15)
    fi
fi

if [ ${#AVAILABLE_VERSIONS[@]} -eq 0 ]; then
    warn "Could not retrieve version list automatically (network or API rate limit)."
    AVAILABLE_VERSIONS=("0.12.0" "0.11.0" "0.10.0")
fi

# -----------------------------------------------------------------------------
# 3. Interactive Selection
# -----------------------------------------------------------------------------
echo "Available official AppFlowy versions:"
idx=1
for ver in "${AVAILABLE_VERSIONS[@]}"; do
    extra=""
    if [ "$idx" -eq 1 ]; then
        extra=" (LATEST)"
    fi
    if [ "$ver" = "$CURRENT_APPFLOWY_VER" ]; then
        extra="$extra [CURRENT]"
    fi
    printf "  %2d) %s%s\n" "$idx" "$ver" "$extra"
    idx=$((idx + 1))
done
printf "   m) Enter custom version manually\n"
printf "   q) Quit without changes\n\n"

printf "Select version to install [1]: "
read -r choice
choice="${choice:-1}"

case "$choice" in
    [Qq]*)
        info "Update aborted. No changes made."
        exit 0
        ;;
    [Mm]*)
        printf "Enter AppFlowy version (e.g. 0.13.0): "
        read -r SELECTED_VERSION
        ;;
    *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#AVAILABLE_VERSIONS[@]}" ]; then
            SELECTED_VERSION="${AVAILABLE_VERSIONS[$((choice - 1))]}"
        else
            warn "Invalid selection. Defaulting to latest (${AVAILABLE_VERSIONS[0]})."
            SELECTED_VERSION="${AVAILABLE_VERSIONS[0]}"
        fi
        ;;
esac

[ -z "$SELECTED_VERSION" ] && error "Version cannot be empty."

# Check companion web version
info "Checking AppFlowy Web companion image for version ${SELECTED_VERSION}..."
WEB_EXISTS=false
WEB_CHECK=$(curl -s --connect-timeout 5 "https://hub.docker.com/v2/repositories/appflowyinc/appflowy_web/tags/${SELECTED_VERSION}" 2>/dev/null || true)
if echo "$WEB_CHECK" | grep -q '"name"'; then
    WEB_EXISTS=true
fi

if [ "$WEB_EXISTS" = true ]; then
    SELECTED_WEB_VERSION="$SELECTED_VERSION"
    info "Found matching AppFlowy Web image: ${SELECTED_WEB_VERSION}"
else
    # Keep current or fetch latest web
    warn "Tag ${SELECTED_VERSION} not found for appflowy_web. Keeping current web version: ${CURRENT_WEB_VER}"
    printf "Use web version [%s]: " "$CURRENT_WEB_VER"
    read -r user_web
    SELECTED_WEB_VERSION="${user_web:-$CURRENT_WEB_VER}"
fi

printf '\n\033[1mSelected versions:\033[0m\n'
printf '  AppFlowy Core: %s (was: %s)\n' "$SELECTED_VERSION" "$CURRENT_APPFLOWY_VER"
printf '  AppFlowy Web:  %s (was: %s)\n\n' "$SELECTED_WEB_VERSION" "$CURRENT_WEB_VER"

printf 'Proceed with update? [Y/n]: '
read -r confirm
confirm="${confirm:-y}"
case "$confirm" in
    [Yy]*) ;;
    *) info "Update canceled."; exit 0 ;;
esac

# -----------------------------------------------------------------------------
# 4. Pre-update safety backup
# -----------------------------------------------------------------------------
info "Creating pre-update safety backup of PostgreSQL database..."
mkdir -p backups
BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PRE_BACKUP_FILE="backups/pre_update_db_${BACKUP_TIMESTAMP}.sql"

if docker compose ps postgres 2>/dev/null | grep -q "Up"; then
    if docker compose exec -T postgres pg_dump -U appflowy appflowy > "$PRE_BACKUP_FILE" 2>/dev/null; then
        success "Safety backup saved to: ${PRE_BACKUP_FILE}"
    else
        warn "Could not create safety dump (database might be initializing). Continuing..."
    fi
else
    info "Database container is not running. Skipping online dump."
fi

# -----------------------------------------------------------------------------
# 5. Update .env
# -----------------------------------------------------------------------------
info "Updating .env with new version tags..."

# Update APPFLOWY_VERSION
if grep -q '^[[:space:]]*APPFLOWY_VERSION=' .env; then
    sed -i "s/^[[:space:]]*APPFLOWY_VERSION=.*/APPFLOWY_VERSION=${SELECTED_VERSION}/" .env
else
    echo "APPFLOWY_VERSION=${SELECTED_VERSION}" >> .env
fi

# Update APPFLOWY_WEB_VERSION
if grep -q '^[[:space:]]*APPFLOWY_WEB_VERSION=' .env; then
    sed -i "s/^[[:space:]]*APPFLOWY_WEB_VERSION=.*/APPFLOWY_WEB_VERSION=${SELECTED_WEB_VERSION}/" .env
else
    echo "APPFLOWY_WEB_VERSION=${SELECTED_WEB_VERSION}" >> .env
fi

success ".env updated."

# -----------------------------------------------------------------------------
# 6. Run deployment & asset re-extraction via setup.sh
# -----------------------------------------------------------------------------
info "Running deployment procedure (pulling images & extracting assets)..."
bash setup.sh

info "Starting updated services with Docker Compose..."
docker compose up -d

# -----------------------------------------------------------------------------
# 7. Verification & cleanup
# -----------------------------------------------------------------------------
sleep 3
printf '\n'
info "Container status:"
docker compose ps

printf '\n'
success "Update to AppFlowy ${SELECTED_VERSION} complete!"

printf '\nWould you like to remove old unused container images? [y/N]: '
read -r prune_choice
case "$prune_choice" in
    [Yy]*)
        info "Cleaning up old images..."
        docker image prune -f
        success "Cleanup complete."
        ;;
    *) ;;
esac
