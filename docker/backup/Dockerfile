# Herda da mesma imagem do servidor pra garantir que redis-cli seja a mesma
# versão. Assim evita qualquer incompatibilidade de protocolo.
ARG REDIS_IMAGE=valkey/valkey:8-alpine
FROM ${REDIS_IMAGE}

# Valkey/Redis alpine — precisamos de dcron (busybox cron), bash, gzip
RUN apk add --no-cache \
    bash \
    dcron \
    tzdata \
    coreutils \
    findutils \
    gzip

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/spool/cron/crontabs /var/log

ENTRYPOINT ["/entrypoint.sh"]
