# OpenE2EE — Bildirops Handoff Dokümanı

## 📌 Proje Özeti

OpenE2EE projesinin **Backend (Go/chi)** ve **Web Dashboard (Flutter Web)** bileşenleri, `bildirops` altyapı monorepo'su altında mikroservis/stack mimarisine uygun şekilde yapılandırılmış ve **Test (Staging)** ortamı başarıyla yayına alınmıştır. Production ortamı için gerekli altyapı konfigürasyonları hazırlanmış olup test aşamasından sonra yayına alınmaya hazırdır.

---

## 🚀 Canlıdaki Servisler (Test Ortamı)

| Servis | Domain | Container Adı | Image | Port (Internal) | Kong Route ID / Path |
|--------|--------|---------------|-------|-----------------|----------------------|
| **Backend API** | `api-test.opene2ee.com` | `opene2ee-backend-test` | `registry.izinonaysistemi.com/opene2ee/backend:1.0.0` | 8080 | `/api/v1/*`, `/healthz` |
| **Redis (Backend)** | — | `opene2ee-redis-test` | `redis:7-alpine` | 6379 | — |
| **Web Dashboard** | `app-test.opene2ee.com` | `opene2ee-web-test` | `registry.izinonaysistemi.com/opene2ee/web:1.0.0` | 80 | `/*` (SPA Fallback) |

---

## 📁 Dizin Yapısı & Altyapı Bileşenleri

### 1. `bildirops/e2ee-app/` (Backend Stack)
- `docker-compose.test.yml`: Test ortamı compose dosyası (`opene2ee-backend-test` + `opene2ee-redis-test`). `kong-net` ağını kullanır.
- `docker-compose.prod.yml`: Production compose dosyası.
- `.env.config.test`: Test ortamı non-secret konfigürasyonları (`DOMAIN=api-test.opene2ee.com`, portlar, vb.).
- `.env.config.prod`: Production ortamı non-secret konfigürasyonları (`DOMAIN=api.opene2ee.com`).
- `.env.secrets.example`: Vaultwarden'dan çekilecek secret şablonu (DB kullanıcı, şifre, JWT secret, server salt, Redis şifresi).
- `make-env.sh`: `.env.config.{test|prod}` ile `.env.secrets` dosyalarını birleştirerek `.env` oluşturur.
- `setup-infra.sh`: Patroni/pgpool üzerinde `opene2ee_user` kullanıcısını ve `opene2ee_test` veritabanını ilklendirir.
- `seed-test.sh`: Demo verilerini (3 cihaz, 4 oturum, 108 telemetri satırı) `opene2ee_test` veritabanına yükler.
- `setup-kong.sh`: Kong Admin API (`http://127.0.0.1:8001`) üzerinden backend servis ve route'larını tanımlar (Rate limit, CORS, JWT plugin'leri).

### 2. `bildirops/e2ee-web/` (Web Dashboard Stack)
- `docker-compose.test.yml`: Flutter web test container'ı (`opene2ee-web-test`, `nginx:alpine` tabanlı).
- `docker-compose.prod.yml`: Production web compose dosyası.
- `.env.config.test`: `DOMAIN=app-test.opene2ee.com`.
- `.env.config.prod`: `DOMAIN=app.opene2ee.com`.
- `make-env.sh`: Konfigürasyonu `.env` dosyasına aktarır.
- `setup-kong.sh`: Kong üzerinde `app-test.opene2ee.com` domain'i için rotayı tanımlar.

### 3. Git & Vaultwarden Entegrasyonu (`bildirops/pull-secrets.sh`)
- `pull-secrets.sh` betiğine E2EE secret'ları eklendi:
  - Vaultwarden Key (Test): `e2ee-api-test-env` → `./e2ee-app/.env.secrets`
  - Vaultwarden Key (Prod): `e2ee-api-prod-env` → `./e2ee-app/.env.secrets`

---

## 🛠️ İşlem Adımları & Komutlar (Cheat Sheet)

### Secret'ları Vaultwarden'dan Çekme ve Ortamı Güncelleme
```bash
cd /home/alibildir/repos/bildirops
./pull-secrets.sh test
```

### Test Ortamını Yeniden Başlatma / Güncelleme
```bash
# 1. Backend Stack
cd /home/alibildir/repos/bildirops/e2ee-app
./make-env.sh test
docker compose -f docker-compose.test.yml up -d
./setup-kong.sh test

# 2. Web Stack
cd /home/alibildir/repos/bildirops/e2ee-web
./make-env.sh test
docker compose -f docker-compose.test.yml up -d
./setup-kong.sh test
```

### Production Ortamına Alma (Test Sonrası)
```bash
# 1. Secret'ları Çek
cd /home/alibildir/repos/bildirops
./pull-secrets.sh prod

# 2. Backend Deploy
cd /home/alibildir/repos/bildirops/e2ee-app
./make-env.sh prod
./setup-infra.sh prod
docker compose -f docker-compose.prod.yml up -d
./setup-kong.sh prod

# 3. Web Deploy
cd /home/alibildir/repos/bildirops/e2ee-web
./make-env.sh prod
docker compose -f docker-compose.prod.yml up -d
./setup-kong.sh prod
```

### Yeni Image Build ve Push (Geliştirme Sonrası)
```bash
# Backend Image Build & Push
cd /home/alibildir/repos/e2ee-app
docker build -t registry.izinonaysistemi.com/opene2ee/backend:1.0.0 ./backend/
docker push registry.izinonaysistemi.com/opene2ee/backend:1.0.0

# Web Image Build & Push
cd /home/alibildir/repos/e2ee-app/mobile
flutter build web --target=lib/web/main.dart --release
docker build -f Dockerfile.web -t registry.izinonaysistemi.com/opene2ee/web:1.0.0 .
docker push registry.izinonaysistemi.com/opene2ee/web:1.0.0
```

---

## 🔍 Doğrulama ve Test Komutları

```bash
# 1. Backend Healthz Check (Kong üzerinden)
curl -s -H "Host: api-test.opene2ee.com" http://localhost/healthz | jq .

# 2. Public API Matrix Check
curl -s -H "Host: api-test.opene2ee.com" http://localhost/api/v1/matrix

# 3. JWT Koruma Testi (401 beklenir)
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: api-test.opene2ee.com" http://localhost/api/v1/sessions

# 4. Web Dashboard Check (Kong üzerinden)
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: app-test.opene2ee.com" http://localhost/
```

---

## ⚠️ Bilinen Notlar & Dikkat Edilmesi Gerekenler

1. **TimescaleDB Extension**: Patroni PostgreSQL cluster'ında `timescaledb` eklentisi `shared_preload_libraries` altında tanımlı olmadığı için `CREATE EXTENSION` atlanmaktadır. Backend uygulama katmanında bu durum best-effort olarak ele alındığından telemetri tabloları standart PostgreSQL tablosu olarak sorunsuz çalışmaktadır.
2. **JWT Authentication**: Protected route'lar (`/api/v1/sessions`, `/api/v1/webrtc`, `/api/v1/users`) JWT korumalıdır. `POST /api/v1/auth` endpoint'i üzerinden alınan Bearer token `Authorization: Bearer <token>` header'ı ile gönderilmelidir.
3. **Web Dashboard Image Boyutu**: Flutter web derlemesi `nginx:alpine` üzerinde sunulmakta olup toplam image boyutu oldukça hafiftir (~11MB).
