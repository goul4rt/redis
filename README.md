# redis-stack

Setup production-ready de Redis/Valkey em Docker, com persistência AOF+RDB, segurança reforçada, backup automatizado e restore orquestrado. Segue a mesma filosofia do irmão `postgres-stack`.

## O que tem aqui

- **Valkey 8 Alpine** por default (BSD, fork open-source do Redis, mantido pela Linux Foundation). Drop-in replacement — qualquer cliente Redis funciona sem mudança.
- **Config opinativa em `config/redis.conf`**: AOF+RDB, slow log, lazy freeing, I/O threads, comandos perigosos desabilitados
- **Senha obrigatória** via `REQUIREPASS`
- **Backup automatizado**: BGSAVE + copy dump.rdb + gzip + rotação, em container separado com cron
- **Restore orquestrado**: `manage.sh` para/start redis automaticamente
- **Healthcheck** com `redis-cli PING` (autenticado)
- **`manage.sh`** pra lifecycle, cli, info, slowlog, monitor, backups

Sem UI web — uso via `redis-cli` nativo ou [RedisInsight](https://redis.io/insight/) no host.

## Valkey vs Redis — qual escolher?

| Critério | Valkey 8 (default) | Redis 8 (AGPL) |
|---|---|---|
| Licença | BSD (permissiva) | AGPLv3 (copyleft) |
| Protocolo/clientes | Compatível 100% | Original |
| Módulos built-in | Pacote padrão | + RedisJSON, Search, TimeSeries, Vector Sets |
| Managed services | AWS ElastiCache for Valkey, GCP | Redis Cloud |
| Fricção legal | Zero | Pode conflitar com policies anti-AGPL |

**Quer Redis 8 em vez de Valkey?** Troca no `.env`:
```bash
REDIS_IMAGE=redis:8-alpine
```
Tudo o mais (clients, config, scripts) funciona igual.

## Estrutura

```
redis-stack/
├── docker-compose.yml
├── .env.example
├── manage.sh
├── config/
│   └── redis.conf          # config principal (persistência, segurança, etc)
├── docker/
│   └── backup/
│       ├── Dockerfile       # herda da imagem do redis + cron
│       └── entrypoint.sh
├── scripts/
│   ├── backup.sh            # BGSAVE + copy + gzip + rotate
│   └── restore.sh           # descomprime + valida RDB header
└── backups/                 # .rdb.gz files (bind mount)
```

## Quick start

```bash
./manage.sh setup
# Edita .env — TROCA REDIS_PASSWORD!
# Gera senha: openssl rand -base64 32
vim .env

./manage.sh start
./manage.sh status
./manage.sh cli
```

## Conectando do app

### Node.js (ioredis)

```typescript
import Redis from "ioredis";

const redis = new Redis({
  host: "localhost",
  port: 6379,
  password: process.env.REDIS_PASSWORD,
  // Bom default pra reconexão em apps long-running:
  maxRetriesPerRequest: 3,
  enableReadyCheck: true,
});
```

Via URL:
```typescript
const redis = new Redis(process.env.REDIS_URL);
// REDIS_URL=redis://:senha@localhost:6379/0
```

### Go (go-redis)

```go
rdb := redis.NewClient(&redis.Options{
    Addr:     "localhost:6379",
    Password: os.Getenv("REDIS_PASSWORD"),
    DB:       0,
})
```

### Python (redis-py)

```python
import redis
r = redis.Redis(
    host="localhost", port=6379,
    password=os.environ["REDIS_PASSWORD"],
    decode_responses=True,
)
```

## Persistência: AOF + RDB

Redis/Valkey suporta dois modos de persistência, e este setup usa **os dois juntos** — prática recomendada:

**RDB** (snapshots binários):
- Dump completo periódico (`save 3600 1`, `save 300 100`, etc)
- Arquivo único `dump.rdb` — fácil de fazer backup
- Restore MUITO rápido
- Downside: pode perder minutos de dados em crash

**AOF** (log de commands):
- Cada write é appendado ao `appendonly.aof`
- `appendfsync everysec` → perde no máximo 1 segundo em crash
- Downside: arquivo cresce, rewrite compact periódico

Combinado: RDB serve de base (restore rápido), AOF adiciona as mudanças desde o último snapshot. Perda máxima em crash = 1 segundo.

## Backup

O container `backup-scheduler` roda em paralelo com cron. Por default, dispara **BGSAVE** no redis (não bloqueia), espera terminar, copia `dump.rdb` comprimido pra `./backups/`.

Configurações no `.env`:
```bash
BACKUP_SCHEDULE="0 3 * * *"      # todo dia às 03:00
BACKUP_RETENTION_DAYS=7           # mantém 7 dias
BACKUP_ON_START=false
```

Comandos:
```bash
./manage.sh backup                # dispara backup manual
./manage.sh backups               # lista arquivos
./manage.sh scheduler             # tail dos logs do cron
./manage.sh restore redis_20260423_030000.rdb.gz
```

### Restore é especial

Diferente do Postgres, Redis/Valkey **não aceita restore hot** — precisa parar o servidor, substituir o `dump.rdb`, remover o AOF antigo (senão ignora o RDB), e subir de novo. O `./manage.sh restore` faz tudo isso automaticamente:

1. Valida o arquivo (checa header `REDIS`)
2. Descomprime pra um staging
3. Para o container redis
4. Substitui o `dump.rdb` no volume, apaga AOF antigo
5. Sobe o redis

Durante o restore o Redis fica down por ~5-10 segundos.

## Observabilidade

```bash
./manage.sh cli              # redis-cli interativo
./manage.sh info             # output completo do INFO
./manage.sh info memory      # só seção de memória
./manage.sh info stats       # contadores de ops, hits, misses
./manage.sh info replication # master/slave status

./manage.sh slowlog          # últimas 20 queries acima do threshold (10ms)
./manage.sh monitor          # firehose de todos comandos — ALTO overhead
```

### Comandos úteis no `cli`

```
DBSIZE                       # quantas keys
INFO keyspace                # breakdown por DB
MEMORY STATS                 # uso detalhado de memória
MEMORY USAGE <key>           # quanto uma key específica custa
CLIENT LIST                  # conexões ativas
CONFIG GET maxmemory         # lê config atual (se CONFIG não foi renomeado)
LATENCY LATEST               # spikes de latência recentes
LATENCY HISTORY event        # histórico de um evento
```

## Segurança

Este setup já vem com:

- **Senha obrigatória** (`requirepass`)
- **Protected mode** ligado
- **Comandos perigosos desabilitados**: `FLUSHDB`, `FLUSHALL`, `DEBUG` estão renomeados pra string vazia (inutilizados). Mexa em `config/redis.conf` pra ajustar.

Pra produção em VPS exposta:

- **NÃO exponha a porta 6379 pra internet**. Conecta o app via rede interna do Docker ou SSH tunnel pra debug.
- Considera **TLS** (`tls-port 6380` em `redis.conf` + certificados) se tráfego cross-host.
- Gera senha **forte**: `openssl rand -base64 32`.
- Se múltiplos apps usam o mesmo Redis, considere **ACLs** (Redis 6+) em vez de senha única. No `cli`:
  ```
  ACL SETUSER appname on >senha ~appname:* +@read +@write -@dangerous
  ```

## Tuning

Os defaults são pra um container com **2GB alocados ao Redis**. Se você tem mais RAM:

| Parâmetro | Default | Quando aumentar |
|---|---|---|
| `REDIS_MAXMEMORY` | 2gb | Tamanho do dataset > 1gb |
| `io-threads` (redis.conf) | 4 | CPU cores > 4; workload network-bound |
| `maxclients` (redis.conf) | 10000 | Muitos clientes concorrentes |
| `save` (redis.conf) | 3600/300/60 | Dataset muito grande — relaxa pra evitar BGSAVE frequente |

### maxmemory-policy — qual escolher?

- **`allkeys-lru`** (default aqui) → Redis é cache puro, descarta menos recentes. Seguro.
- **`allkeys-lfu`** → Se seu workload tem keys "quentes" bem definidas (top artigos, usuários VIP), melhor que LRU.
- **`volatile-lru`** → Redis armazena cache **e** dados "permanentes". Keys com TTL são candidatas à eviction, as sem TTL são intocadas. **Atenção**: se esquecer de setar TTL numa key de cache, ela vira "permanente" e ocupa memória pra sempre.
- **`noeviction`** → NUNCA descarta. Write falha quando enche. Só use se Redis é DB primário (raro).

### Host tuning

Em produção no host:
```bash
# Evita warning de "Background save may fail under low memory"
sudo sysctl vm.overcommit_memory=1
echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf

# Desabilita transparent huge pages (latency spikes no Redis)
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

O `somaxconn` (backlog de conexões) já é ajustado via `sysctls` no compose.

## Troubleshooting

**`WRONGPASS invalid username-password pair`:**
`REDIS_PASSWORD` no `.env` diferente do que o cliente está usando. Confirma com:
```bash
./manage.sh cli              # se entrar, o .env tá certo
```

**Stack sobe mas healthcheck falha eternamente:**
Provavelmente senha com caractere especial que quebra o healthcheck shell. Gera uma senha sem `$`, backtick, `"`:
```bash
openssl rand -hex 32
```

**Backup falha com "Source file not found":**
Primeira subida do stack — o `dump.rdb` ainda não existe porque não houve nenhum BGSAVE anterior. Dá um `./manage.sh backup` manual que força o primeiro save.

**Dados sumiram após restart:**
Verifica se `appendonly yes` está ativo (`CONFIG GET appendonly` no cli). Se o volume não foi preservado (`./manage.sh reset` apaga tudo), os dados foram pro vinagre.
