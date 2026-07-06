# OpenE2EE — Sprint 2 Hotfix: PR-13 Infra Config Follow-up

**Tarih:** 6 Temmuz 2026 12:00
**Yazan:** Architect (mvs_25a7a987f73243899e35a1485c6ba224)
**Referans:** ADR-0007-deployment.md, infra/docker-compose.yml, infra/README.md
**Durum:** Proposed (Owner ack bekleniyor, Sprint 3+ template)

---

## 1. Neden Bu Hotfix?

**PR-13 (`e582bda feat(infra): PR-13 docker-compose dev ortami`) eksik:**

PR-13 commit mesajında *"kong: kong:3.8-alpine DB-less declarative mode mounting kong.yml"* ve *"nginx: profile-based alternative, kong.conf mount, certbot volumes"* deniyor. Ancak:

- `infra/kong/kong.yml` — **hiç commit edilmemiş**
- `infra/kong/README.md` — **hiç commit edilmemiş**
- `infra/nginx/nginx.conf` — **hiç commit edilmemiş**
- `infra/nginx/README.md` — **hiç commit edilmemiş**

`infra/docker-compose.yml` bu dosyalara volume mount referansı veriyor:
- Kong servisi: `./kong:/etc/kong` (DB-less declarative mode)
- Nginx servisi (profile-based): `./nginx/nginx.conf:/etc/nginx/nginx.conf`

`infra/README.md` 4 dosyaya referans veriyor (yanıltıcı — dosyalar yok).

**Sonuç:** `docker compose up` çalışmaz — mount edilecek dosya yok, Kong/Nginx container crash. README.md yanıltıcı.

**Engellenen milestone:** Sprint 1 release (`docker compose up` + smoke test) çalışmaz durumda.

---

## 2. Scope — 4 Dosya

### 2.1 `infra/kong/kong.yml` (Kong 3.8 declarative config)

```yaml
_format_version: "3.0"
services:
  - name: e2ee-backend
    url: http://backend:8080
    routes:
      - name: api-v1
        paths:
          - /api/v1
        methods:
          - GET
          - POST
          - DELETE
    plugins:
      - name: rate-limiting
        config:
          minute: 60
          hour: 1000
          policy: local
      - name: cors
        config:
          origins:
            - "*"
          methods:
            - GET
            - POST
            - DELETE
          headers:
            - Content-Type
            - Authorization
            - X-Request-ID
      - name: bot-detection
        config:
          allow:
            - "curl"
            - "wget"
            - "OpenE2EE/*"
```

**Açıklama:**
- `_format_version: "3.0"` — Kong 3.x declarative format
- `services[0]` — backend service (container DNS: backend:8080)
- `routes[0]` — `/api/v1` prefix matching
- `plugins`: rate-limit (DDoS), CORS (mobile client), bot-detection (good botlar allow)
- DB-less mode — `KONG_DATABASE=off` zaten docker-compose'da

### 2.2 `infra/kong/README.md` (Kong operasyonları)

İçerik:
- Kong DB-less mode açıklaması (declarative config reload)
- Restart komutu (config değişikliğinde)
- Log paths (`/var/log/kong/`)
- Plugin listesi (rate-limit, CORS, bot-detection) — nasıl enable/disable
- Health check endpointi (`http://localhost:8001/status`)
- Production'da certbot + Let's Encrypt (SSL termination)

### 2.3 `infra/nginx/nginx.conf` (Reverse proxy + SSL)

```nginx
events {
    worker_connections 1024;
}

http {
    upstream e2ee_backend {
        server backend:8080;
    }

    # HTTP -> HTTPS redirect (prod only)
    server {
        listen 80;
        server_name _;

        location /api/ {
            proxy_pass http://e2ee_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

    # HTTPS server (prod with Let's Encrypt)
    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate /etc/ssl/certs/fullchain.pem;
        ssl_certificate_key /etc/ssl/private/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        location /api/ {
            proxy_pass http://e2ee_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
```

**Açıklama:**
- `upstream e2ee_backend` — backend container'a round-robin
- Port 80 (HTTP) — dev profile'da doğrudan backend'e proxy
- Port 443 (HTTPS) — prod profile'da SSL termination + backend proxy
- `X-Forwarded-Proto` — backend HTTPS algılasın

### 2.4 `infra/nginx/README.md` (Nginx operasyonları)

İçerik:
- Profile-based activation (`--profile nginx`)
- Certbot (Let's Encrypt) integration (prod only)
- Log paths (`/var/log/nginx/`)
- nginx -t syntax check komutu
- Reload komutu (graceful)
- Kong ile çakışmaması (port 80/443 — sadece biri aktif)

---

## 3. Branch Stratejisi

- **Source branch:** `feat/pr-13-docker @ e582bda`
- **New branch:** `fix/pr-13-infra-config-followup`
- **Commit mesajı:** `fix(infra): PR-13 follow-up — Kong/Nginx config (PR-13 missing 4 files)`
- **Files:** 4 (kong.yml, kong/README.md, nginx.conf, nginx/README.md)
- **Diff size:** ~150-200 LoC

---

## 4. Coder Task

**Single PR:** `fix/pr-13-infra-config-followup`

```bash
cd C:\repos\e2ee-app
git fetch origin
git checkout feat/pr-13-docker
git checkout -b fix/pr-13-infra-config-followup

# 4 dosyayı yaz (yukarıdaki scope'a göre)
mkdir -p infra/kong infra/nginx
# infra/kong/kong.yml (yukarıdaki içerik)
# infra/kong/README.md (yukarıdaki içerik)
# infra/nginx/nginx.conf (yukarıdaki içerik)
# infra/nginx/README.md (yukarıdaki içerik)

git add infra/kong infra/nginx
git commit -m "fix(infra): PR-13 follow-up — Kong/Nginx config (4 missing files)

PR-13 docker-compose.yml'de kong.yml + nginx.conf volume mount referansları var
ama dosyalar hiç commit edilmedi. infra/README.md yanıltıcı referanslar
gösteriyordu. Bu fix 4 dosyayı yazar:

- infra/kong/kong.yml: Kong 3.8 declarative config (services, routes,
  rate-limit + CORS + bot-detection plugins)
- infra/kong/README.md: Kong operasyonları (DB-less mode, restart, log)
- infra/nginx/nginx.conf: Reverse proxy + SSL termination
- infra/nginx/README.md: Nginx operasyonları

Refs: ADR-0007-deployment.md, infra/docker-compose.yml"

git push origin fix/pr-13-infra-config-followup
```

**Tahmini süre:** ~20-30dk (dosyalar kısa, copy-paste ağırlıklı)

---

## 5. Verifier §6 Review (PR-13-followup)

### Check A — Diff Scope
- `git diff --stat feat/pr-13-docker..fix/pr-13-infra-config-followup`
- 4 dosya, ~150-200 LoC

### Check B — YAML/Config Syntax
- `kong.yml`: Kong 3.x declarative format valid (`_format_version: "3.0"`)
- `nginx.conf`: `nginx -t` veya python yaml/json validator

### Check C — Plugin/Route Correctness
- Kong services + routes valid
- Rate-limit policy (local — DB-less mode uyumlu)
- CORS origins + methods doğru
- Bot-detection allowlist (curl/wget/OpenE2EE)

### Check D — Nginx Reverse Proxy
- Upstream backend:8080
- Port 80 (HTTP) + 443 (HTTPS) configured
- SSL paths (`/etc/ssl/certs/fullchain.pem`) — certbot volume mount'a uyumlu
- X-Forwarded-* header'lar

### Check E — README İçerik
- Kong README: DB-less mode, restart, log, plugin, health check
- Nginx README: profile-based, certbot, log, syntax check, Kong çakışma

### Check F — Integration Gate
- `docker compose config` (Docker varsa) — Kong/Nginx services valid
- `python infra/scripts/validate_compose.py` — volume mount'lar valid

### Check G — Privacy/ADR-0006
- ADR-0006 §Veri Minimizasyonu enforce (reverse proxy IP masking not required — backend handles)
- Rate-limit 60/min, 1000/hour — DDoS protection makul

**Verdict:** PASS = integration'a hazır, FAIL = Coder fix-up

---

## 6. Integration Plan (Sprint 1+2 + Hotfix)

```
feat/pr-13-docker @ e582bda
  ↓
fix/pr-13-infra-config-followup (4 dosya)
  ↓
merge into feat/pr-mp-6-vscode (Sprint 1+2 entegre)
  ↓
integration gate (Sprint 1+2 + Kong/Nginx)
  ↓
PASS = main'e merge + push (release anı)
```

**Notlar:**
- `feat/pr-mp-6-vscode @ c85ad6c` Sprint 1+2 entegre (PR-MP-1..7 + Sprint 1)
- Hotfix branch (PR-13 follow-up) `feat/pr-mp-6-vscode`'a merge edilecek
- Veya direkt `feat/pr-mp-6-vscode`'da dosyaları yaz (daha hızlı, ama branch hygiene kötü)

**Önerim:** Ayrı branch (`fix/pr-13-infra-config-followup`) → cherry-pick veya merge to `feat/pr-mp-6-vscode`. Branch hygiene iyi.

---

## 7. Maliyet / Süre Tahmini

- **Coder:** ~20-30dk (dosya yazma + commit + push)
- **Verifier §6 review:** ~10dk (PR başına + integration gate)
- **Integration merge:** ~5dk
- **Toplam:** ~35-45dk, ~$0.05-0.10

---

## 8. Kabul Kriterleri

- [ ] 4 dosya commit edildi (kong.yml, kong/README.md, nginx.conf, nginx/README.md)
- [ ] Kong declarative config syntax valid
- [ ] Nginx config syntax valid
- [ ] Kong/Nginx README içerik yeterli (operasyon rehberi)
- [ ] Verifier §6 review PASS
- [ ] Integration gate PASS
- [ ] feat/pr-mp-6-vscode'ya merge edildi

---

## 9. Karar

**Karar verildi:** Hotfix (4 dosya) — kullanıcı onayı 6 Temmuz 2026 11:59

**Sırada:**
1. Owner mini plan kuracak (plan_<id>, 1-2 task)
2. Coder yeni session — implement
3. Verifier §6 review + integration gate
4. Sprint 1+2'ye merge → main → push (release anı)

**Bu plan mimari olarak Sprint 3+ template'e uygun (5-adım + integration gate).**