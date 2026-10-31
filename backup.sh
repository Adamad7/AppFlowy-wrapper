#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AppFlowy Cloud - Automated Encrypted Backup to Google Drive
# =============================================================================
# Performs a hot dump of PostgreSQL, packages minio-data and .env,
# encrypts the archive using GPG (AES-256), uploads to Google Drive via rclone,
# and enforces a retention policy.
# Suitable for cron execution.
# =============================================================================

# Ensure standard PATH for cron execution
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

log()   { printf '[%s] [INFO]  %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
warn()  { printf '[%s] [WARN]  %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$1"; }
error() { printf '[%s] [ERROR] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$1" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Configuration & Environment
# -----------------------------------------------------------------------------
ENV_FILE="$PROJECT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    error "Configuration file .env not found in $PROJECT_DIR"
fi

# Read necessary variables from .env
get_env() {
    local key="$1"
    local def="${2:-}"
    local val
    val=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"'\'' ' || true)
    echo "${val:-$def}"
}

POSTGRES_USER=$(get_env "POSTGRES_USER" "appflowy")
POSTGRES_DB=$(get_env "POSTGRES_DB" "appflowy")
BACKUP_DIR=$(get_env "BACKUP_DIR" "$PROJECT_DIR/backups")
BACKUP_RETENTION_DAYS=$(get_env "BACKUP_RETENTION_DAYS" "30")
GDRIVE_REMOTE=$(get_env "GDRIVE_REMOTE" "gdrive:AppFlowy-Backups")
BACKUP_ENCRYPTION_PASSPHRASE=$(get_env "BACKUP_ENCRYPTION_PASSPHRASE" "")

# Resolve relative backup path
if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# -----------------------------------------------------------------------------
# 2. Prerequisites
# -----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || error "Docker is required."
command -v gpg >/dev/null 2>&1 || error "'gpg' is required for encryption. Install with: apt-get install -y gnupg"
command -v tar >/dev/null 2>&1 || error "'tar' is required."

if [ -z "$BACKUP_ENCRYPTION_PASSPHRASE" ] || [ "$BACKUP_ENCRYPTION_PASSPHRASE" = "CHANGE_ME_backup_encryption_passphrase" ]; then
    error "BACKUP_ENCRYPTION_PASSPHRASE is not set or still default in .env. Generate a secure passphrase first."
fi

# -----------------------------------------------------------------------------
# 3. Create Backup
# -----------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TMP_DIR=$(mktemp -d /tmp/appflowy-backup.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_NAME="appflowy_backup_${TIMESTAMP}.tar.gz"
ENCRYPTED_FILE="$BACKUP_DIR/${ARCHIVE_NAME}.gpg"

log "Starting backup process for AppFlowy..."

# 3.1. Hot dump PostgreSQL
log "Dumping PostgreSQL database ($POSTGRES_DB)..."
if ! docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$TMP_DIR/database.sql"; then
    error "Failed to dump PostgreSQL database. Is the container running?"
fi

DB_SIZE=$(stat -c%s "$TMP_DIR/database.sql" 2>/dev/null || stat -f%z "$TMP_DIR/database.sql" 2>/dev/null || echo "0")
if [ "$DB_SIZE" -lt 50 ]; then
    error "Database dump appears empty or corrupted ($DB_SIZE bytes)."
fi
log "Database dump completed (${DB_SIZE} bytes)."

# 3.2. Package into tar.gz (database + minio-data + .env)
log "Archiving database, minio-data, and .env configuration..."
TAR_ARGS=("-czf" "$TMP_DIR/$ARCHIVE_NAME" "-C" "$TMP_DIR" "database.sql" "-C" "$PROJECT_DIR" ".env")
if [ -d "$PROJECT_DIR/minio-data" ]; then
    TAR_ARGS+=("-C" "$PROJECT_DIR" "minio-data")
fi

tar "${TAR_ARGS[@]}"

# 3.3. Encrypt archive with GPG (AES-256)
log "Encrypting archive with AES-256..."
gpg --batch --yes --passphrase "$BACKUP_ENCRYPTION_PASSPHRASE" \
    --symmetric --cipher-algo AES256 \
    -o "$ENCRYPTED_FILE" "$TMP_DIR/$ARCHIVE_NAME"

chmod 600 "$ENCRYPTED_FILE"
FINAL_SIZE=$(du -h "$ENCRYPTED_FILE" | cut -f1)
log "Encrypted backup created: $ENCRYPTED_FILE ($FINAL_SIZE)"

# -----------------------------------------------------------------------------
# 4. Upload to Google Drive via rclone
# -----------------------------------------------------------------------------
if command -v rclone >/dev/null 2>&1; then
    if [ -n "$GDRIVE_REMOTE" ]; then
        log "Uploading encrypted archive to Google Drive remote ($GDRIVE_REMOTE)..."
        if rclone copy "$ENCRYPTED_FILE" "$GDRIVE_REMOTE"; then
            log "Upload to Google Drive succeeded."
            
            # Prune old backups on Google Drive
            log "Purging backups older than ${BACKUP_RETENTION_DAYS} days on Google Drive..."
            rclone delete --min-age "${BACKUP_RETENTION_DAYS}d" "$GDRIVE_REMOTE" 2>/dev/null || true
        else
            warn "rclone upload failed. The backup remains safely stored locally at: $ENCRYPTED_FILE"
        fi
    fi
else
    warn "'rclone' is not installed or not in PATH. Encrypted backup saved locally only."
    warn "To enable Google Drive sync, install rclone ('apt install rclone' or https://rclone.org) and run 'rclone config'."
fi

# -----------------------------------------------------------------------------
# 5. Local Retention Cleanup
# -----------------------------------------------------------------------------
log "Purging local backups older than ${BACKUP_RETENTION_DAYS} days in $BACKUP_DIR..."
find "$BACKUP_DIR" -type f -name "appflowy_backup_*.tar.gz.gpg" -mtime +"$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true

log "Backup workflow finished successfully."
