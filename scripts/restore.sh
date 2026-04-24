#!/bin/bash
set -euo pipefail

# ============================================================================
# restore.sh
# Restaura um dump.rdb.gz no volume do Redis.
#
# IMPORTANTE: o restore de RDB exige parar o Redis, substituir o dump.rdb
# e re-iniciar. Não dá pra "hot-restore". Este script é chamado pelo
# manage.sh do host, que orquestra o stop/start dos containers.
#
# Este script, quando rodado DENTRO do container de backup, só faz:
#   1. Descomprimir o arquivo selecionado
#   2. Validar o header RDB
#   3. Escrever em /redis-data-restore/dump.rdb
#
# O manage.sh no host cuida do ciclo de vida.
# ============================================================================

: "${BACKUP_DIR:=/backups}"
: "${RESTORE_TARGET:=/redis-data-restore/dump.rdb}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup_file.rdb.gz>"
    echo ""
    echo "Available backups:"
    ls -lh "${BACKUP_DIR}"/redis_*.rdb.gz 2>/dev/null || echo "  (none)"
    exit 1
fi

BACKUP_FILE="$1"

# Aceita path completo ou nome do arquivo
if [ ! -f "${BACKUP_FILE}" ]; then
    BACKUP_FILE="${BACKUP_DIR}/${BACKUP_FILE}"
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    log "✗ Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

log "=== Restoring from ${BACKUP_FILE} ==="

# ---------------------------------------------------------------------------
# Descomprime e valida o header
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "${RESTORE_TARGET}")"

log "Decompressing..."
if ! gunzip -c "${BACKUP_FILE}" > "${RESTORE_TARGET}"; then
    log "✗ Decompression failed"
    rm -f "${RESTORE_TARGET}"
    exit 1
fi

# Header do RDB começa com "REDIS" (5 bytes) + versão (4 dígitos ASCII)
HEADER=$(head -c 9 "${RESTORE_TARGET}" | od -c | head -1 | awk '{print $2$3$4$5$6}')
if [ "${HEADER%%[0-9]*}" != "REDIS" ]; then
    # od -c output pode variar; checa os primeiros 5 chars brutos
    FIRST5=$(dd if="${RESTORE_TARGET}" bs=1 count=5 2>/dev/null)
    if [ "${FIRST5}" != "REDIS" ]; then
        log "✗ Invalid RDB header (got: '${FIRST5}')"
        log "   Arquivo corrompido ou não é um dump RDB válido"
        rm -f "${RESTORE_TARGET}"
        exit 1
    fi
fi

SIZE=$(du -h "${RESTORE_TARGET}" | cut -f1)
log "✔ Valid RDB written: ${RESTORE_TARGET} (${SIZE})"
log "=== Restore staging complete ==="
log "O manage.sh do host vai agora parar o redis, substituir o dump e reiniciar."
