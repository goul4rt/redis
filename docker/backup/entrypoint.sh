#!/bin/bash
set -euo pipefail

# ============================================================================
# Entrypoint do container de backup do Redis.
# Configura crontab a partir de $BACKUP_SCHEDULE e sobe crond em foreground.
# ============================================================================

: "${REDIS_HOST:?REDIS_HOST is required}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
: "${BACKUP_SCHEDULE:=0 3 * * *}"
: "${BACKUP_RETENTION_DAYS:=7}"
: "${BACKUP_ON_START:=false}"

echo "[entrypoint] Redis backup scheduler starting"
echo "[entrypoint]   schedule:        ${BACKUP_SCHEDULE}"
echo "[entrypoint]   retention:       ${BACKUP_RETENTION_DAYS} days"
echo "[entrypoint]   backup on start: ${BACKUP_ON_START}"
echo "[entrypoint]   target:          ${REDIS_HOST}:${REDIS_PORT}"

# ---------------------------------------------------------------------------
# Cron não herda env do processo pai — precisa escrever num arquivo.
# Permissão 600 porque REDIS_PASSWORD tá dentro.
# ---------------------------------------------------------------------------
cat > /etc/backup.env <<EOF
export REDIS_HOST="${REDIS_HOST}"
export REDIS_PORT="${REDIS_PORT}"
export REDIS_PASSWORD="${REDIS_PASSWORD}"
export BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS}"
export PATH="/usr/local/bin:/usr/bin:/bin"
EOF
chmod 600 /etc/backup.env

# ---------------------------------------------------------------------------
# Crontab: dispara backup.sh, log redirecionado pro arquivo (que é tail-ed
# abaixo pro stdout do container)
# ---------------------------------------------------------------------------
CRON_CMD='source /etc/backup.env && /scripts/backup.sh >> /backups/backup.log 2>&1'
echo "${BACKUP_SCHEDULE} ${CRON_CMD}" > /var/spool/cron/crontabs/root
chmod 600 /var/spool/cron/crontabs/root

mkdir -p /backups
touch /backups/backup.log

# ---------------------------------------------------------------------------
# Backup inicial opcional
# ---------------------------------------------------------------------------
if [ "${BACKUP_ON_START}" = "true" ]; then
    echo "[entrypoint] Running initial backup..."
    # shellcheck disable=SC1091
    source /etc/backup.env
    /scripts/backup.sh >> /backups/backup.log 2>&1 || echo "[entrypoint] Initial backup failed (see /backups/backup.log)"
fi

# ---------------------------------------------------------------------------
# Tail em background + crond em foreground
# ---------------------------------------------------------------------------
tail -F /backups/backup.log &
exec crond -f -l 2
