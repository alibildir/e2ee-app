# OpenE2EE — Multiplatform Contributor Guide

**Sürüm:** Sprint 2 / ADR-0008 — 6 Temmuz 2026
**Kapsam:** Windows · macOS · Linux geliştirici katılım rehberi
**Referans:** `docs/ADR-0008-multiplatform-tooling.md`

Bu rehber OpenE2EE monoreposuna katkıda bulunmak isteyen geliştiriciler için tek giriş noktasıdır. Üç işletim sistemi için de aynı komutlar (`make setup`, `make test`, `make lint`, `make build`) çalışır; fark yalnızca **shell seçimi** ve **bağımlılık kurulum adımları**dır.

---

## 1. Önkoşullar (tüm OS)

| Bileşen | Sürüm | Not |
|---|---|---|
| Git | ≥ 2.40 | `git config core.autocrlf false` (aşağıda) |
| Go | ≥ 1.26 | Backend + tooling |
| Flutter | ≥ 3.24 (Dart ≥ 3.5) | Mobile + web |
| Make | herhangi (GNU Make ≥ 3.81) | Cross-platform entry point |
| Docker Desktop / Engine | ≥ 24 | Sadece `make dev` için |

Repo'nun eklediği **platform-normalizasyon katmanı** şunları garanti eder:

- **`.editorconfig`** — editör/IDE bağımsız stil (Go=tab, geri kalan=2 boşluk, UTF-8 LF).
- **`.gitattributes`** — tüm metin LF, binary dosyalar diff edilmez, `.ps1`/`.bat` CRLF.
- **`.gitignore`** — OS + IDE + build artifact'ları otomatik dışlanır.
- **`scripts/*.sh` + `scripts/*.ps1` + `Makefile`** — aynı logic, farklı shell.

Bu yüzden PR açarken platform farkı diff gürültüsü yaratmaz.

---

## 2. Windows (Git Bash veya WSL)

Windows'ta iki eşdeğer yol vardır; **birini** seç ve ona sadık kal.

### 2.1 Git Bash (önerilen — hızlı)

1. **Git for Windows** kur: <https://git-scm.com/download/win> (Git Bash dahil).
2. **Visual Studio Code** kur + Önerilen eklentiler `.vscode/extensions.json`'dan otomatik yüklenecek.
3. **Go for Windows**: <https://go.dev/dl/> (`.msi`). `go version` PATH'e düşer.
4. **Flutter**: <https://docs.flutter.dev/get-started/install/windows/mobile>. PATH'e `C:\src\flutter\bin` ekle.
5. **PowerShell 7 (pwsh)** kur: `winget install Microsoft.PowerShell` — `.ps1` scriptler için (native fallback).
6. Repo'yu klonla:
   ```bash
   git clone https://github.com/opene2ee-com/e2ee-app.git
   cd e2ee-app
   git config core.autocrlf false    # ADR-0008 §2.2 — LF zorla
   ```
7. Kurulumu doğrula:
   ```bash
   make setup      # bash scripts/setup.sh — Go + Flutter versiyon kontrol
   make test       # go test + flutter test
   ```

### 2.2 WSL 2 (Linux alt-sistem)

1. `wsl --install -d Ubuntu` (PowerShell admin).
2. Ubuntu içinde: `sudo apt update && sudo apt install -y build-essential git make`.
3. Go / Flutter'ı Linux binary olarak kur (Windows kurulumunu değil — WSL kendi PATH'i).
4. Repo'yu WSL home'unda klonla (`\\wsl$\Ubuntu\home\<user>\e2ee-app`).
5. Aynı `make setup` → `make test` döngüsü.

**WSL avantajı:** Tüm scriptler doğal bash olarak çalışır, dosya modu (chmod) doğru yönetilir.

> PowerShell-7-native kullanmak istersen `pwsh scripts/setup.ps1` (Git Bash kurmadan). Ancak resmi CI Linux runner'dır; PR'lar Linux'ta geçmeli.

---

## 3. macOS (native)

1. **Xcode Command Line Tools**: `xcode-select --install` (git + make gelir).
2. **Homebrew**: <https://brew.sh>.
3. Go + Flutter kur:
   ```bash
   brew install go
   brew install --cask flutter   # veya doğrudan https://docs.flutter.dev/get-started/install/macos/mobile
   ```
4. Repo'yu klonla:
   ```bash
   git clone https://github.com/opene2ee-com/e2ee-app.git
   cd e2ee-app
   git config core.autocrlf false
   ```
5. `make setup && make test`.

iOS build için Xcode (App Store) ve CocoaPods (`sudo gem install cocoapods`) gerekir — bunlar sadece mobile release workflow'unda zorunlu, normal PR'da değil.

---

## 4. Linux (native)

Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y build-essential git make curl
# Go — official tarball
wget https://go.dev/dl/go1.26.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.26.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
# Flutter
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH=$PATH:$HOME/flutter/bin' >> ~/.bashrc
source ~/.bashrc
```

Fedora/RHEL karşılığı: `dnf install -y @development-tools make git curl`.

Ardından:

```bash
git clone https://github.com/opene2ee-com/e2ee-app.git
cd e2ee-app
git config core.autocrlf false
make setup && make test
```

---

## 5. Editör ayarları

`.editorconfig` repo kökündedir — VSCode, IntelliJ, GoLand, Vim (vim-editorconfig eklentisiyle), Sublime hepsi otomatik okur. Manuel ayar yapma.

VSCode kullanıyorsan ilk açılışta sağ-alt köşede önerilen eklentileri kur (Go, Flutter, Dart, YAML, EditorConfig). `.vscode/settings.json` zaten `formatOnSave=true`, `files.eol="\n"`, `tabSize=2`, Go için `tabSize=4 + insertSpaces=false` ayarlıdır.

---

## 6. PR workflow (cross-platform)

```bash
# 1. Feature branch — main'den ayrıl
git checkout -b feat/<scope>

# 2. Değişiklik yap, commit'le
git add <files>
git commit -m "feat(<scope>): <message>"

# 3. Yerel gate — CI ile aynı komutlar
make lint       # go vet + flutter analyze
make test       # go test + flutter test
make build      # go build + flutter build web (opsiyonel)

# 4. CRLF/LF drift kontrolü
git ls-files --eol | grep -E 'i/.+w/.*crlf'   # text dosyada CRLF var mı?
git status --ignored                          # .DS_Store / Thumbs.db / build/ ignore ediliyor mu?

# 5. Push + PR
git push -u origin feat/<scope>
gh pr create --fill --base main
```

**Commit mesajı Conventional Commits** kullanır: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. Gövde 72 sütun, Türkçe veya İngilizce serbest.

PR açmadan önce:

- [ ] `make lint` PASS
- [ ] `make test` PASS (Go + Flutter)
- [ ] Diff'te `CRLF`/`LF` karışımı yok (yukarıdaki grep boş dönmeli)
- [ ] `.gitignore`'a eklenmesi gereken yeni bir OS artifact varsa commit'e dahil

---

## 7. Sık karşılaşılan tuzaklar

| Sorun | Çözüm |
|---|---|
| `git status`'ta `.DS_Store` görünüyor | `.gitignore` PR-MP-3 tarafından karşılanıyor; `git rm --cached .DS_Store` + commit |
| Windows'ta CRLF diff çıkıyor | `git config core.autocrlf false` + `git add --renormalize .` |
| `make` komutu yok (Windows native cmd) | Git Bash veya WSL kullan; cmd.exe desteklenmiyor |
| PowerShell BOM Go derleyiciyi kırıyor | `scripts/*.ps1` UTF-8 *no BOM* yaz; PS 5.1'de `[IO.File]::WriteAllText` kullan |
| `flutter` PATH'te yok (WSL) | WSL'in kendi PATH'ine ekle, Windows PATH'i geçerli değil |
| `make test` mobile'da çok yavaş | `cd mobile && flutter test --concurrency=4` veya test etiketi (`--tags=unit`) |

---

## 8. Daha fazla bilgi

- ADR: `docs/ADR-0008-multiplatform-tooling.md` (tüm kararlar + trade-offs)
- Mimari: `docs/ARCHITECTURE_DECISIONS.md`
- Sprint 2 plan: `docs/SPRINT-2-MULTIPLATFORM-PLAN.md`
- CI: GitHub Actions Linux runner (PR-MP-CI ile genişletilecek: `ubuntu-latest`, `macos-latest`, `windows-latest`)

Sorular: GitHub Discussions veya Architect (mvs_25a7a987f73243899e35a1485c6ba224).