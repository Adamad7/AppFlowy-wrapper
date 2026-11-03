#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AppFlowy Cloud - Interactive Multi-Service Version Updater
# =============================================================================
# Fetches available official versions from Docker Hub for each component:
#   - AppFlowy Cloud & Worker (appflowyinc/appflowy_cloud)
#   - AppFlowy Web (appflowyinc/appflowy_web)
#   - GoTrue Auth (appflowyinc/gotrue)
#   - Admin Frontend (appflowyinc/admin_frontend)
# Allows selecting individual versions for each service, performs pre-update
# safety backup, updates .env, re-extracts assets, and deploys.
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
CURRENT_CLOUD_VER=$(grep -E '^[[:space:]]*APPFLOWY_CLOUD_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
[ -z "$CURRENT_CLOUD_VER" ] && CURRENT_CLOUD_VER=$(grep -E '^[[:space:]]*APPFLOWY_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_CLOUD_VER="${CURRENT_CLOUD_VER:-0.19.11}"

CURRENT_WEB_VER=$(grep -E '^[[:space:]]*APPFLOWY_WEB_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_WEB_VER="${CURRENT_WEB_VER:-0.19.11}"

CURRENT_GOTRUE_VER=$(grep -E '^[[:space:]]*GOTRUE_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
[ -z "$CURRENT_GOTRUE_VER" ] && CURRENT_GOTRUE_VER=$(grep -E '^[[:space:]]*APPFLOWY_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_GOTRUE_VER="${CURRENT_GOTRUE_VER:-0.18.11}"

CURRENT_ADMIN_VER=$(grep -E '^[[:space:]]*ADMIN_FRONTEND_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
[ -z "$CURRENT_ADMIN_VER" ] && CURRENT_ADMIN_VER=$(grep -E '^[[:space:]]*APPFLOWY_VERSION=' .env | cut -d'=' -f2- | tr -d '"'\'' ' || true)
CURRENT_ADMIN_VER="${CURRENT_ADMIN_VER:-latest}"

printf '\n\033[1m===================================================\033[0m\n'
printf '\033[1m   AppFlowy Cloud - Service Version Updater\033[0m\n'
printf '\033[1m===================================================\033[0m\n\n'
info "Current configured versions in .env:"
printf '  - AppFlowy Cloud & Worker: \033[1m%s\033[0m\n' "$CURRENT_CLOUD_VER"
printf '  - AppFlowy Web:            \033[1m%s\033[0m\n' "$CURRENT_WEB_VER"
printf '  - GoTrue Auth:             \033[1m%s\033[0m\n' "$CURRENT_GOTRUE_VER"
printf '  - Admin Frontend:          \033[1m%s\033[0m\n\n' "$CURRENT_ADMIN_VER"

# -----------------------------------------------------------------------------
# Helper: fetch tags from Docker Hub and prompt user for selection
# -----------------------------------------------------------------------------
select_version_for_service() {
    local repo_name="$1"
    local service_title="$2"
    local current_val="$3"
    shift 3
    local fallback_tags=("$@")

    printf '\n\033[1;36m---------------------------------------------------\033[0m\n'
    printf '\033[1mSelect version for: %s\033[0m\n' "$service_title"
    printf 'Docker image: appflowyinc/%s | Current: \033[1m%s\033[0m\n' "$repo_name" "$current_val"
    printf '\033[1;36m---------------------------------------------------\033[0m\n'

    info "Fetching official tags for appflowyinc/${repo_name} from Docker Hub..."
    local api_resp
    api_resp=$(curl -s --connect-timeout 8 "https://hub.docker.com/v2/repositories/appflowyinc/${repo_name}/tags?page_size=50" 2>/dev/null || true)

    local fetched_tags=()
    if [ -n "$api_resp" ]; then
        if command -v jq >/dev/null 2>&1; then
            mapfile -t fetched_tags < <(echo "$api_resp" | jq -r '.results[].name' 2>/dev/null \
                | grep -v -E -- '(-amd64|-arm64|backup|\.git)' \
                | grep -E '^(latest|[0-9]+(\.[0-9]+)*)' \
                | sort -V -r | uniq | head -n 15)
        else
            mapfile -t fetched_tags < <(echo "$api_resp" | grep -oP '"name":\s*"\K[^"]+' 2>/dev/null \
                | grep -v -E -- '(-amd64|-arm64|backup|\.git)' \
                | grep -E '^(latest|[0-9]+(\.[0-9]+)*)' \
                | sort -V -r | uniq | head -n 15)
        fi
    fi

    local available_tags=()
    if [ ${#fetched_tags[@]} -gt 0 ]; then
        available_tags=("${fetched_tags[@]}")
    else
        warn "Could not fetch tags automatically. Using standard stable fallbacks."
        available_tags=("${fallback_tags[@]}")
    fi

    # Display list
    local idx=1
    for tag in "${available_tags[@]}"; do
        local tag_info=""
        if [ "$idx" -eq 1 ]; then
            tag_info=" (NEWEST AVAILABLE)"
        fi
        if [ "$tag" = "$current_val" ]; then
            tag_info="$tag_info [CURRENT]"
        fi
        printf "  %2d) %s%s\n" "$idx" "$tag" "$tag_info"
        idx=$((idx + 1))
    done
    printf "   m) Enter custom version manually\n"
    printf "   k) Keep current [%s]\n" "$current_val"
    printf "   q) Quit updater\n\n"

    printf "Select version [1]: "
    local choice
    read -r choice
    choice="${choice:-1}"

    local selected_tag=""
    case "$choice" in
        [Qq]*)
            info "Update aborted by user."
            exit 0
            ;;
        [Kk]*)
            selected_tag="$current_val"
            ;;
        [Mm]*)
            printf "Enter custom tag for appflowyinc/%s: " "$repo_name"
            read -r selected_tag
            [ -z "$selected_tag" ] && selected_tag="$current_val"
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#available_tags[@]}" ]; then
                selected_tag="${available_tags[$((choice - 1))]}"
            else
                warn "Invalid selection. Keeping current version: ${current_val}"
                selected_tag="$current_val"
            fi
            ;;
    esac

    success "Selected $service_title version: \033[1m$selected_tag\033[0m"
    echo "$selected_tag"
}

# -----------------------------------------------------------------------------
# 2. Select versions for each component
# -----------------------------------------------------------------------------
# 1) AppFlowy Cloud (Backend & Worker)
SELECTED_CLOUD_VER=$(select_version_for_service "appflowy_cloud" "AppFlowy Cloud & Worker" "$CURRENT_CLOUD_VER" "0.19.11" "0.19.10" "0.19.9" "0.18.2" "latest")

# 2) AppFlowy Web
SELECTED_WEB_VER=$(select_version_for_service "appflowy_web" "AppFlowy Web UI" "$CURRENT_WEB_VER" "0.19.11" "0.19.10" "0.18.2" "0.10.5" "latest")

# 3) GoTrue Auth
SELECTED_GOTRUE_VER=$(select_version_for_service "gotrue" "GoTrue Authentication" "$CURRENT_GOTRUE_VER" "0.18.11" "0.18.5" "0.17.1" "0.12.0" "latest")

# 4) Admin Frontend
SELECTED_ADMIN_VER=$(select_version_for_service "admin_frontend" "Admin Console" "$CURRENT_ADMIN_VER" "latest" "0.18.2" "0.12.0")

# -----------------------------------------------------------------------------
# 3. Confirmation
# -----------------------------------------------------------------------------
printf '\n\033[1m===================================================\033[0m\n'
printf '\033[1mSummary of versions to be configured in .env:\033[0m\n'
printf '  - AppFlowy Cloud & Worker: \033[1;32m%s\033[0m (was: %s)\n' "$SELECTED_CLOUD_VER" "$CURRENT_CLOUD_VER"
printf '  - AppFlowy Web:            \033[1;32m%s\033[0m (was: %s)\n' "$SELECTED_WEB_VER" "$CURRENT_WEB_VER"
printf '  - GoTrue Auth:             \033[1;32m%s\033[0m (was: %s)\n' "$SELECTED_GOTRUE_VER" "$CURRENT_GOTRUE_VER"
printf '  - Admin Frontend:          \033[1;32m%s\033[0m (was: %s)\n' "$SELECTED_ADMIN_VER" "$CURRENT_ADMIN_VER"
printf '\033[1m===================================================\033[0m\n\n'

printf 'Proceed with update and deployment? [Y/n]: '
read -r confirm
confirm="${confirm:-y}"
case "$confirm" in
    [Yy]*) ;;
    *) info "Update canceled. No changes applied."; exit 0 ;;
esac

# -----------------------------------------------------------------------------
# 4. Pre-update safety backup (optional)
# -----------------------------------------------------------------------------
info "Creating pre-update safety backup of PostgreSQL database..."
mkdir -p backups
BACKUP_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PRE_BACKUP_FILE="backups/pre_update_db_${BACKUP_TIMESTAMP}.sql"

if docker compose ps postgres 2>/dev/null | grep -q "Up"; then
    if docker compose exec -T postgres pg_dump -U appflowy appflowy > "$PRE_BACKUP_FILE" 2>/dev/null; then
        success "Safety backup saved to: ${PRE_BACKUP_FILE}"
    else
        warn "Could not create database dump (container might be stopped or initializing). Continuing..."
    fi
else
    info "Database container is not running. Skipping online dump."
fi

# -----------------------------------------------------------------------------
# 5. Update .env
# -----------------------------------------------------------------------------
info "Updating .env with chosen versions..."

update_env_var() {
    local var="$1"
    local val="$2"
    if grep -q "^[[:space:]]*${var}=" .env; then
        sed -i "s|^[[:space:]]*${var}=.*|${var}=${val}|" .env
    else
        echo "${var}=${val}" >> .env
    fi
}

update_env_var "APPFLOWY_CLOUD_VERSION" "$SELECTED_CLOUD_VER"
update_env_var "APPFLOWY_WEB_VERSION" "$SELECTED_WEB_VER"
update_env_var "GOTRUE_VERSION" "$SELECTED_GOTRUE_VER"
update_env_var "ADMIN_FRONTEND_VERSION" "$SELECTED_ADMIN_VER"

success ".env updated successfully."

# -----------------------------------------------------------------------------
# 6. Run deployment procedure via setup.sh
# -----------------------------------------------------------------------------
info "Executing deployment (pulling images, extracting assets, setting permissions)..."
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
success "Update complete!"

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
