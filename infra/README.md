# OpenE2EE — Infrastructure (Sprint 1)

Bu dizin OpenE2EE Faz 1 MVP'nin tüm altyapı dosyalarını içerir.

## Dizin Yapısı

```
infra/
├── docker-compose.yml          # Tüm servisler (dev ortamı)
├── .env.example                # Tüm env değişkenleri (örnek; gerçek .env değil)
├── README.md                   # Bu dosya — operasyon rehberi
├── kong/
│   ├── kong.yml                # Kong declarative config
│   └── README.md
├── nginx/
│   ├── nginx.conf              # Nginx reverse proxy (alternatif)
│   └── README.md
├── coturn/
│   └── turnserver.conf         # Coturn TURN/STUN
├── seed.sql                    # Postgres initial seed (3 TR operatörü)
└── scripts/
    ├── validate_compose.py     # YAML parse + structure check
    └── validate_env.py         # Env-var expansion simulation
```

## Servisler

| Servis       | Image                                | Ağ            | Host Port (dev)    | Profile |
|--------------|--------------------------------------|---------------|--------------------|---------|
| postgres     | timescale/timescaledb-ha:pg16        | internal      | 5432               | (default)|
| redis        | redis:7-alpine                       | internal      | 6379               | (default)|
| backend      | (build ../backend)                   | internal+ext. | (expose 8080)      | (default)|
| kong         | kong:3.8-alpine                      | external      | 8000, 8443, 8001   | (default)|
| coturn       | coturn/coturn:4.6                    | external      | 3478 (UDP+TCP)     | (default)|
| nginx        | nginx:alpine                         | external      | 80, 443            | `nginx` |

### Ağlar (HANDOFF §4.3)

- **`internal`** — Postgres + Redis. Backend de bu ağda (DB erişimi için).
- **`external`** — Kong + Backend + Coturn + (Nginx). Public trafik bu ağdan akar.

### Volume'lar

- `postgres_data` — Postgres + TimescaleDB data persistence
- `redis_data` — Redis AOF persistence
- `certbot_data` / `certbot_www` — Let's Encrypt (prod only)
- `coturn_data` — Coturn runtime state
- `backend_logs` — Backend logları host'tan da erişilebilir

## Hızlı Başlangıç

```bash
# 1. Secret'ları ayarla
cp infra/.env.example infra/.env
nano infra/.env   # __SET_ME__ placeholder'ları doldur

# 2. Compose syntax doğrula (Docker olmadan — Sprint 1 varsayımı)
python infra/scripts/validate_compose.py
python infra/scripts/validate_env.py

# 3. Servisleri başlat (Docker varsa)
docker compose -f infra/docker-compose.yml --env-file infra/.env up -d

# 4. Logları izle
docker compose -f infra/docker-compose.yml logs -f

# 5. Smoke test
curl -f http://localhost:8000/api/v1/healthz

# 6. Durdur
docker compose -f infra/docker-compose.yml down
```

### Nginx Profili (alternatif)

Kong yerine Nginx kullanmak için:

```bash
docker compose -f infra/docker-compose.yml --profile nginx --env-file infra/.env up -d
```

**NOT:** Kong + Nginx aynı anda çalıştırma — port 80/443 çakışır.

## Konfigürasyon

### Environment Variables

Tüm env değişkenleri `infra/.env.example`'da dokümante edilmiştir. Üretimde `.env` git'e commit edilmez (`.gitignore` tarafından korunur).

**Gerekli (`:?` ile zorunlu kılınır):**
- `POSTGRES_PASSWORD`
- `SERVER_SALT` (32+ hex char önerilir)
- `JWT_SECRET` (Sprint 5 PR-32 — HS256, Kong + backend ortak)
- `REDIS_PASSWORD` (Sprint 7 PR-43 — SEC-6/7 fail-closed; redis
  server `--requirepass` + Go client auth ile birebir aynı değer)
- `COTURN_STATIC_SECRET`
- `COTURN_PUBLIC_IP` (NAT arkasında zorunlu)

### Gizli Değer Üretme (Secret Generation)

OpenSSL ile 32-byte hex secret üretmek için:

```bash
# Her secret için ayrı ayrı çalıştır:
openssl rand -hex 32
```

Örnek komutlar (Sprint 7 PR-43 prosedürü):

```bash
# Yeni bir REDIS_PASSWORD üretmek için (mevcut değeri ezmeden önce tüm
# servisleri restart etmen gerekecek):
openssl rand -hex 32 > /tmp/new_redis_password.txt

# Aynı kalıp diğer secret'lar için de geçerli:
openssl rand -hex 32 > /tmp/new_jwt_secret.txt
openssl rand -hex 32 > /tmp/new_server_salt.txt
openssl rand -hex 32 > /tmp/new_postgres_password.txt
openssl rand -hex 32 > /tmp/new_coturn_static_secret.txt
```

Secret'ları `.env` dosyasına yapıştır (`infra/.env.example` placeholder'larından
farklı) veya docker secrets (file provider) kullan. Üretim için Vault/sops+age
önerilir (Sprint 8+ backlog).

### REDIS_PASSWORD Rotation (SEC-6/7, Sprint 7 PR-43)

`REDIS_PASSWORD` Quarterly rotation önerilir (Sprint 5 PR-32 JWT_SECRET
ile aynı kalıp). Rotation adımları:

1. **Yeni secret üret:**
   ```bash
   openssl rand -hex 32
   ```
2. **`infra/.env` dosyasında** `REDIS_PASSWORD` satırını yeni değerle değiştir
   (veya `infra/.secrets/redis_password.txt` dosyasını rotate et).
3. **Stack'i restart et** — önce redis, sonra backend:
   ```bash
   docker compose -f infra/docker-compose.yml restart redis
   docker compose -f infra/docker-compose.yml restart backend
   ```
4. **Smoke test:**
   ```bash
   # Backend → redis bağlantısı:
   curl -fsS http://localhost:8000/api/v1/healthz
   # Redis'e doğrudan:
   docker compose -f infra/docker-compose.yml exec redis \
     redis-cli -a "$REDIS_PASSWORD" ping
   ```
5. **Eski secret'ı imha et** (log + secret manager'dan).

**Neden iki restart?** Redis `--requirepass` sadece container başlangıcında
okunur; runtime'da değiştirilemez. Backend client ise config reload (`SIGHUP`)
yapmaz (Sprint 7+ takip işi) — restart en güvenli yol.

### Network İzolasyonu

Dev ortamında DB portları host'a açıktır (psql/redis-cli debug için). Production'da `ports:` satırları kaldırılmalı.

Sprint 7 PR-43 (SEC-6/7) ile redis servisi artık host'a port map etmiyor
(default), böylece container `internal` docker ağı üzerinden yalnızca backend
tarafından erişilebilir. Debug için:
```bash
docker compose -f infra/docker-compose.yml exec redis \
  redis-cli -a "$REDIS_PASSWORD" ping
```

### Coturn Konfig

`infra/coturn/turnserver.conf` — RFC 5766/8656 TURN + RFC 5389 STUN.
Static-auth-secret modu (REST API credentials) kullanılır. Mobile client
Sprint 2'de ephemeral credential üretecek.

## Doğrulama

PR-13 kapsamında runtime test yapılmadı (Docker kurulu değil). Bunun yerine:

```bash
# YAML parse + service shape check
python infra/scripts/validate_compose.py

# Env-var expansion simulation (Compose davranışı)
python infra/scripts/validate_env.py
```

Her iki script de hatasız çalışmalı. CI (PR-14) Postgres+Redis+TimescaleDB
servisleri ile `docker compose up` doğrulamasını yapacak.

## Seed Verisi

`infra/seed.sql` container'ın `/docker-entrypoint-initdb.d/` dizinine mount
edilir. İlk başlatmada (DB boşken) otomatik çalıştırılır:

- 3 demo device (turkcell, vodafone_tr, turk_telekom)
- 4 demo session (p2p, echobot, single)
- 108 telemetry satırı (90 gün × 3 operatör × 3 app)

PRIVACY (ADR-0006): Sadece hashed ID'ler, fingerprint'ler ve /24 maskelenmiş
IP'ler. Raw UUID, public key, IP veya telefon numarası YOK.

DB zaten initialize edilmişse seed dosyası atlanır (Postgres initdb idempotent
değil). Yeniden yüklemek için: `docker compose down -v` (volume'ları siler).

## Faz 2 Eklenecekler

- Prometheus + Grafana (monitoring stack)
- Loki + Promtail (log aggregation)
- HashiCorp Vault (secret management)
- Cloudflare proxy (DDoS koruması)
- Multi-region replication

## Referanslar

- [docs/DEPLOYMENT.md](../../docs/DEPLOYMENT.md) — Topoloji + runbook
- [docs/ADR-0007-deployment.md](../../docs/ADR-0007-deployment.md) — Deployment kararı
- [docs/HANDOFF.md §4.3](../../docs/HANDOFF.md) — PR-13 spec
- [infra/kong/README.md](./kong/README.md) — Kong operasyonları
- [infra/nginx/README.md](./nginx/README.md) — Nginx operasyonları