#!/bin/bash
set -euo pipefail

# ============================================================================
# backup.sh
# Dispara BGSAVE no Redis, espera terminar, copia dump.rdb (comprimido) pro
# diretório de backup e rotaciona os antigos.
#
# Por que não usar `redis-cli --rdb`?
# Esse modo usa o protocolo de replicação (SYNC), que exige o Redis ter o
# cliente como "replica" — mais complicado em terms de ACL/network. BGSAVE
# + cópia direta via volume compartilhado é mais simples e idêntico em resultado.
# ============================================================================

: "${REDIS_HOST:?REDIS_HOST is required}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
: "${BACKUP_RETENTION_DAYS:=7}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/redis-data}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/redis_${TIMESTAMP}.rdb.gz"

mkdir -p "${BACKUP_DIR}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

redis_cmd() {
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning "$@"
}

log "=== Starting Redis backup ==="

# ---------------------------------------------------------------------------
# 1. Captura timestamp do último save pra poder detectar o fim do BGSAVE
# ---------------------------------------------------------------------------
LAST_SAVE_BEFORE=$(redis_cmd LASTSAVE)
log "Last save before: ${LAST_SAVE_BEFORE}"

# ---------------------------------------------------------------------------
# 2. Dispara BGSAVE (async, não bloqueia)
# ---------------------------------------------------------------------------
log "Triggering BGSAVE..."
BGSAVE_RESULT=$(redis_cmd BGSAVE)
log "BGSAVE response: ${BGSAVE_RESULT}"

# ---------------------------------------------------------------------------
# 3. Poll LASTSAVE até mudar (indica que BGSAVE terminou)
# ---------------------------------------------------------------------------
log "Waiting for BGSAVE to complete..."
MAX_WAIT=600  # 10 minutos
WAITED=0
while true; do
    sleep 2
    WAITED=$((WAITED + 2))
    CURRENT=$(redis_cmd LASTSAVE)
    if [ "${CURRENT}" != "${LAST_SAVE_BEFORE}" ]; then
        log "BGSAVE completed after ${WAITED}s (LASTSAVE=${CURRENT})"
        break
    fi
    if [ "${WAITED}" -ge "${MAX_WAIT}" ]; then
        log "✗ BGSAVE timeout after ${MAX_WAIT}s"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 4. Copia dump.rdb (do volume read-only mountado) e comprime
# ---------------------------------------------------------------------------
SRC="${REDIS_DATA_DIR}/dump.rdb"
if [ ! -f "${SRC}" ]; then
    log "✗ Source file not found: ${SRC}"
    log "   (BGSAVE ran but dump.rdb não apareceu — verifique a config 'dir' do redis)"
    exit 1
fi

SRC_SIZE=$(du -h "${SRC}" | cut -f1)
log "Copying ${SRC} (${SRC_SIZE}) → ${BACKUP_FILE}"

if gzip -9 -c "${SRC}" > "${BACKUP_FILE}"; then
    DST_SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    log "✔ Backup OK: ${BACKUP_FILE} (${DST_SIZE} comprimido)"
else
    log "✗ Backup FAILED"
    rm -f "${BACKUP_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Rotação — remove backups mais antigos que BACKUP_RETENTION_DAYS
# ---------------------------------------------------------------------------
log "Rotating backups older than ${BACKUP_RETENTION_DAYS} days..."
REMOVED=$(find "${BACKUP_DIR}" \
    -maxdepth 1 \
    -name "redis_*.rdb.gz" \
    -type f \
    -mtime "+${BACKUP_RETENTION_DAYS}" \
    -print -delete | wc -l)
log "Removed ${REMOVED} old backup(s)"

# ---------------------------------------------------------------------------
# 6. Sumário
# ---------------------------------------------------------------------------
TOTAL=$(find "${BACKUP_DIR}" -maxdepth 1 -name "redis_*.rdb.gz" -type f | wc -l)
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
log "Backup directory: ${TOTAL} file(s), ${TOTAL_SIZE} total"
log "=== Backup complete ==="
