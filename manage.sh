#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# manage.sh — wrapper de docker compose pra operações comuns do Redis stack
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# cores
if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GRN=$(printf '\033[32m')
    YLW=$(printf '\033[33m')
    BLU=$(printf '\033[34m')
    DIM=$(printf '\033[2m')
    RST=$(printf '\033[0m')
else
    RED="" GRN="" YLW="" BLU="" DIM="" RST=""
fi

info()    { echo "${BLU}▸${RST} $*"; }
success() { echo "${GRN}✔${RST} $*"; }
warn()    { echo "${YLW}⚠${RST} $*"; }
error()   { echo "${RED}✗${RST} $*" >&2; }

# ---------------------------------------------------------------------------
# env_get KEY [DEFAULT]
# Lê .env sem `source` (seguro pra valores com espaços, $, etc)
# ---------------------------------------------------------------------------
env_get() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(grep -E "^${key}=" .env 2>/dev/null | tail -n 1 | cut -d= -f2-) || true
    if [ -z "${val}" ]; then
        echo "${default}"
        return
    fi
    case "${val}" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    echo "${val}"
}

# ---------------------------------------------------------------------------
# Detecta docker compose (v2) vs docker-compose (v1). Lazy.
# ---------------------------------------------------------------------------
DC=""
ensure_docker() {
    [ -n "${DC}" ] && return 0
    if docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DC="docker-compose"
    else
        error "docker compose não encontrado. Instale Docker Desktop ou docker-compose-plugin."
        exit 1
    fi
}

require_env() {
    if [ ! -f .env ]; then
        error ".env não encontrado. Rode: ./manage.sh setup"
        exit 1
    fi
    ensure_docker
}

# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------

cmd_setup() {
    info "Configuração inicial..."

    if [ -f .env ]; then
        warn ".env já existe — não sobrescrevendo."
    else
        cp .env.example .env
        success ".env criado a partir de .env.example"
        warn "Edite .env e troque REDIS_PASSWORD antes de subir em produção!"
        warn "Gere uma senha forte: openssl rand -base64 32"
    fi

    chmod +x manage.sh scripts/*.sh docker/backup/entrypoint.sh 2>/dev/null || true
    mkdir -p backups

    success "Pronto. Próximos passos:"
    echo "  1. Edite .env (troque REDIS_PASSWORD)"
    echo "  2. ./manage.sh start"
}

cmd_start() {
    require_env
    info "Subindo stack..."
    $DC up -d --build
    success "Stack no ar"
    cmd_status
}

cmd_stop() {
    require_env
    info "Parando stack..."
    $DC stop
    success "Stack parada"
}

cmd_restart() {
    require_env
    info "Reiniciando stack..."
    $DC restart
    success "Stack reiniciada"
}

cmd_down() {
    require_env
    info "Removendo containers (volumes preservados)..."
    $DC down
    success "Containers removidos"
}

cmd_status() {
    require_env
    echo ""
    $DC ps
    echo ""

    local redis_user redis_port
    redis_port=$(env_get REDIS_PORT 6379)

    echo "${DIM}Conexão:${RST}"
    echo "  Host:        localhost"
    echo "  Port:        ${redis_port}"
    echo "  Password:    (valor de REDIS_PASSWORD no .env)"
    echo "  URL:         redis://:***@localhost:${redis_port}/0"
    echo "  redis-cli:   redis-cli -h localhost -p ${redis_port} -a \$REDIS_PASSWORD"
    echo ""
}

cmd_logs() {
    require_env
    local service="${1:-redis}"
    $DC logs -f --tail=100 "${service}"
}

cmd_cli() {
    require_env
    local password
    password=$(env_get REDIS_PASSWORD)
    info "Conectando no redis-cli..."
    $DC exec redis redis-cli -a "${password}" --no-auth-warning
}

cmd_info() {
    require_env
    local password section
    password=$(env_get REDIS_PASSWORD)
    section="${1:-}"
    if [ -n "${section}" ]; then
        $DC exec redis redis-cli -a "${password}" --no-auth-warning INFO "${section}"
    else
        $DC exec redis redis-cli -a "${password}" --no-auth-warning INFO
    fi
}

cmd_monitor() {
    require_env
    local password
    password=$(env_get REDIS_PASSWORD)
    warn "MONITOR printa TODOS os comandos recebidos — overhead considerável."
    warn "Use só em dev ou brief debug. Ctrl+C pra sair."
    sleep 2
    $DC exec redis redis-cli -a "${password}" --no-auth-warning MONITOR
}

cmd_slowlog() {
    require_env
    local password
    password=$(env_get REDIS_PASSWORD)
    info "Slow log (queries que passaram do threshold em redis.conf):"
    $DC exec redis redis-cli -a "${password}" --no-auth-warning SLOWLOG GET 20
}

cmd_backup() {
    require_env
    info "Disparando backup manual..."
    $DC exec -T backup-scheduler bash -c 'source /etc/backup.env && /scripts/backup.sh'
    success "Backup concluído"
    cmd_backups
}

cmd_backups() {
    echo ""
    echo "${DIM}Backups em ./backups/:${RST}"
    if ls -lh backups/redis_*.rdb.gz 2>/dev/null; then :; else
        warn "Nenhum backup encontrado ainda."
    fi
    echo ""
}

cmd_restore() {
    require_env
    if [ $# -lt 1 ]; then
        error "Uso: ./manage.sh restore <arquivo.rdb.gz>"
        cmd_backups
        exit 1
    fi
    local file="$1"

    warn "Restore do Redis requer PARAR o serviço temporariamente."
    warn "Isso vai sobrescrever TODOS os dados atuais com ${file}."
    read -r -p "Continuar? (yes/no): " confirm
    if [ "${confirm}" != "yes" ]; then
        info "Cancelado."
        exit 0
    fi

    # 1. Stage o arquivo descomprimido via container de backup
    info "1/4 — Validando e descomprimindo backup..."
    $DC exec -T backup-scheduler bash -c \
        "BACKUP_DIR=/backups RESTORE_TARGET=/tmp/restore-dump.rdb /scripts/restore.sh '${file}'"

    # 2. Para o redis
    info "2/4 — Parando redis..."
    $DC stop redis

    # 3. Copia o dump pro volume. Usamos um container efêmero com o mesmo
    #    volume montado (read-write). Não dá pra usar o backup-scheduler
    #    porque ele monta o volume read-only.
    info "3/4 — Substituindo dump.rdb e removendo AOF antigo..."
    local image
    image=$(env_get REDIS_IMAGE valkey/valkey:8-alpine)
    local project
    project=$(env_get COMPOSE_PROJECT_NAME redisstack)

    # Copia o dump preparado pra dentro do volume, e apaga appendonly.aof
    # (senão o redis ignora o RDB na hora de carregar)
    docker run --rm \
        -v "${project}_redisdata:/data" \
        --volumes-from "$($DC ps -q backup-scheduler)" \
        "${image}" \
        sh -c 'cp /tmp/restore-dump.rdb /data/dump.rdb && \
               chown 999:999 /data/dump.rdb 2>/dev/null || true && \
               rm -f /data/appendonly.aof /data/appendonlydir/* 2>/dev/null || true'

    # 4. Sobe o redis
    info "4/4 — Subindo redis..."
    $DC start redis

    # Aguarda healthcheck
    sleep 3
    success "Restore concluído. Verifique com: ./manage.sh cli → INFO keyspace"
}

cmd_scheduler_logs() {
    require_env
    info "Logs do scheduler (Ctrl+C pra sair)..."
    $DC logs -f --tail=100 backup-scheduler
}

cmd_reset() {
    require_env
    warn "Isso vai APAGAR todos os dados (volume redisdata)."
    read -r -p "Digite 'APAGAR TUDO' para confirmar: " confirm
    if [ "${confirm}" != "APAGAR TUDO" ]; then
        info "Cancelado."
        exit 0
    fi

    $DC down -v
    success "Stack destruída e volumes removidos"
}

cmd_help() {
    cat <<EOF
${BLU}redis-stack${RST} — docker-compose wrapper

${DIM}Lifecycle:${RST}
  setup                 Copia .env.example → .env e dá permissões
  start                 Sobe redis + backup-scheduler
  stop                  Para containers (preserva dados)
  restart               Reinicia containers
  down                  Remove containers (preserva volumes)
  reset                 DESTRÓI tudo incluindo volumes

${DIM}Observabilidade:${RST}
  status                Mostra containers + info de conexão
  logs [serviço]        Tail de logs (default: redis)
  scheduler             Logs do backup-scheduler
  info [section]        Output do comando INFO (server/clients/memory/etc)
  slowlog               Últimas 20 queries lentas
  monitor               Firehose de todos comandos (overhead, só dev)

${DIM}Operações:${RST}
  cli                   Abre redis-cli interativo
  backup                Dispara backup manual (BGSAVE + gzip)
  backups               Lista backups disponíveis
  restore <arquivo>     Restaura backup (requer stop do redis)

Exemplos:
  ./manage.sh setup
  ./manage.sh start
  ./manage.sh cli
  ./manage.sh info memory
  ./manage.sh backup
  ./manage.sh restore redis_20260423_030000.rdb.gz
EOF
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
case "${1:-help}" in
    setup)         cmd_setup ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    down)          cmd_down ;;
    status)        cmd_status ;;
    logs)          shift; cmd_logs "$@" ;;
    cli)           cmd_cli ;;
    info)          shift; cmd_info "$@" ;;
    slowlog)       cmd_slowlog ;;
    monitor)       cmd_monitor ;;
    backup)        cmd_backup ;;
    backups)       cmd_backups ;;
    restore)       shift; cmd_restore "$@" ;;
    scheduler)     cmd_scheduler_logs ;;
    reset)         cmd_reset ;;
    help|-h|--help) cmd_help ;;
    *)
        error "Comando desconhecido: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
