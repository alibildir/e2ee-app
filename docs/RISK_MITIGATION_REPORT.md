# OpenE2EE - Riskler ve Cozum Onerileri Raporu

Tarih: 4 Temmuz 2026

Bu rapor, mevcut mimari kararlar ve gorev odakli test akis dokumanlari uzerinden tespit edilen teknik, urun, gizlilik ve magaza politikasi risklerini; her risk icin uygulanabilir cozum onerileriyle birlikte listeler.

## 1. Yonetici Ozeti

OpenE2EE fikri; kullanici tetiklemeli test, cihaz ici veri isleme, anonim telemetri, P2P gonullu alici modeli ve guven skoru uretimi acisindan uygulanabilir bir yonde ilerlemektedir. Ancak mevcut dokumanlarda bazi iddialar teknik olarak fazla gucludur.

En kritik duzeltme, urunun "E2EE'yi %100 ispatlayan" bir sistem olarak degil, "gozlenen trafik sinyallerinden E2EE ve sifreleme guven skoru ureten" bir olcum araci olarak konumlandirilmasidir.

Oncelikli uc aksiyon:

1. "E2EE ispat" dilini "confidence score / guven skoru" diline cevirmek.
2. Cihaz ve backend veri sorumluluklarini kesin olarak ayirmak.
3. MVP kapsaminda Android-only, manuel P2P ve tek test tipiyle baslamak.

## 2. Kritik Riskler ve Cozumler

### 2.1. E2EE'nin %100 Ispatlanmasi Iddiasi

**Risk:** Mevcut dokumanlarda iki ucta ag paketleri gozlemlenerek E2EE'nin %100 ispatlanabilecegi ifade edilmektedir. Entropi, TLS handshake, paket boyutu ve iki uctaki trafik zamanlamasi; sifreli trafik davranisina dair guclu sinyaller saglayabilir. Ancak bunlar uygulama katmaninda gercek uctan uca sifrelemenin dogru kuruldugunu tek basina kanitlamaz.

**Neden onemli:** TLS sifrelemesi ile uygulama katmani E2EE ayni sey degildir. Bir mesajlasma uygulamasi transport katmaninda sifreli trafik uretirken uygulama katmani E2EE garantisi vermeyebilir. Bu nedenle "ispat" dili hem teknik hem urun hem de hukuki acik yaratir.

**Cozum:**

- "E2EE ispat" yerine "E2EE guven gostergesi" veya "traffic encryption confidence score" kullanilmalidir.
- Sonuc ekrani "Basarili / Basarisiz" yerine "Yuksek Guven / Orta Guven / Dusuk Guven / Dogrulanamadi" seklinde modellenmelidir.
- Skor modeli acikca "gozlenen sinyallere dayali olasiliksal degerlendirme" olarak tanimlanmalidir.
- Backend, kesin hukum vermek yerine confidence score ve risk aciklamasi donmelidir.

**Onerilen urun dili:**

- Yanlis: "WhatsApp E2EE %100 dogrulandi."
- Dogru: "Bu test oturumunda gozlenen trafik, beklenen sifreli iletisim davranisiyla yuksek uyum gosterdi."

### 2.2. Backend'in Ham Paket Gormesi Riski

**Risk:** Mimari dokumanda Go backend'in `gopacket` ile paket/TLS/payload analizi yapacagi belirtilirken, gizlilik bolumunde ham payload ve hedef IP'nin backend'e gonderilmeyecegi soylenmektedir. Bu iki karar netlestirilmezse mimari celiski olusur.

**Cozum:**

- Ham paket, payload, tam hedef IP, telefon numarasi, mesaj icerigi ve pcap dosyasi backend'e hic gonderilmemelidir.
- Paket ornekleme, metadata cikarimi ve entropi hesaplama cihaz icinde yapilmalidir.
- Backend yalnizca anonimlestirilmis ve bucket'lanmis telemetriyi kabul etmelidir.
- API sozlesmesi izin verilen alanlari sinirlamali; fazladan alanlar reddedilmeli veya loglanmadan atilmalidir.

**Onerilen sorumluluk ayrimi:**

| Sorumluluk | Cihaz | Backend |
| --- | --- | --- |
| Ham paket yakalama | Evet | Hayir |
| Payload okuma/ornekleme | Evet, gecici | Hayir |
| Entropi hesaplama | Evet | Hayir |
| Tam hedef IP saklama | Hayir | Hayir |
| TLS/QUIC sinyal ozeti | Evet | Sadece ozet |
| Session eslestirme | Kismen | Evet |
| Confidence score | Kismen | Evet |
| Global agregasyon | Hayir | Evet |

**Onerilen telemetri ornegi:**

```json
{
  "session_id": "ephemeral-random-id",
  "test_type": "whatsapp_manual",
  "platform": "android",
  "network_type": "cellular",
  "carrier_bucket": "TR-carrier-A",
  "sample_window_ms": 120000,
  "packet_count_bucket": "20-50",
  "entropy_bucket": "high",
  "tls_observed": true,
  "confidence_inputs_version": "v1"
}
```

### 2.3. `gopacket` Rolu ve Mimari Cakisma

**Risk:** `gopacket`, ham paketler uzerinden calisan guclu bir analiz kutuphanesidir. Uretim backend'i ham paket almayacaksa `gopacket` ana backend gereksinimi olarak konumlandirilmamalidir.

**Cozum:**

- Uretim backend'i "packet analyzer" degil, "telemetry correlation service" olarak tasarlanmalidir.
- `gopacket` sadece laboratuvar, test fixture, pcap analizi ve algoritma validasyonu icin kullanilmalidir.
- Cihazdaki native katman, uretim olcumlerinin ana kaynagi olmalidir.

**Karar onerisi:** MVP dokumaninda `gopacket` rolu "backend production dependency" yerine "analiz/validasyon araci" olarak guncellenmelidir.

### 2.4. Rust/Native Teknoloji Karari Belirsizligi

**Risk:** Flowchart'ta Local VPN katmani "Rust/Native" olarak gecmektedir. Mimari kararlar dokumaninda ise Rust teknoloji yigini olarak tanimlanmamistir. Flutter tek basina Android `VpnService` ve iOS `NetworkExtension` ihtiyacini karsilamaz.

**Cozum:**

- Android icin Kotlin/Java `VpnService` + Flutter platform channel karari yazilmalidir.
- iOS icin Swift `NetworkExtension` + Flutter platform channel karari yazilmalidir.
- Rust kullanilacaksa, hangi algoritmalarin ortak Rust cekirdeginde yer alacagi ve FFI maliyeti ayrica degerlendirilmelidir.

**MVP onerisi:** Ilk MVP'de Rust eklenmeden Kotlin tabanli Android prototip gelistirilmelidir. Rust ortak cekirdek, algoritma olgunlastiktan sonra Faz 2 olarak degerlendirilebilir.

### 2.5. iOS ve App Store Onay Riski

**Risk:** iOS tarafinda `NetworkExtension` kullanimi entitlement, privacy review ve App Store incelemesi acisindan yuksek risklidir. Open source olmak guven artirir ancak onay garantisi vermez.

**Cozum:**

- iOS ilk MVP kapsamindan cikarilmali veya sadece TestFlight teknik prototip olarak ele alinmalidir.
- Uygulama 7/24 calisan bir izleme araci degil, kullanici tarafindan baslatilan kisa sureli test araci olarak tasarlanmalidir.
- App Store review notlarinda VPN'in ne zaman basladigi, ne zaman kapandigi, hangi verilerin cihazda kaldigi ve hangi telemetrinin gonderildigi acikca anlatilmalidir.
- Ucuncu taraf reklam SDK'si, trafik monetizasyonu ve gereksiz analytics kullanilmamalidir.

**Politika uyum checklist'i:**

- Acik onam ekrani.
- Test baslat/durdur kontrolu kullanicida.
- Ham paket ve mesaj icerigi cihaz disina cikmaz.
- Privacy policy veri alanlarini tek tek listeler.
- Kullanici veri silme akisi vardir.
- VPN kullanim amaci uygulama icinde ve magaza aciklamasinda aynidir.

### 2.6. Google Play `VpnService` Riski

**Risk:** Google Play, `VpnService` kullanan uygulamalari siki inceler. VPN API'sinin amaci, veri kullanimi ve kullanici kontrolu net degilse uygulama reddedilebilir.

**Cozum:**

- Uygulama acikca "network security / encryption transparency tool" olarak konumlandirilmalidir.
- VPN'in test suresince etkinlestigi ve test bitince kapandigi kullaniciya gosterilmelidir.
- Arka planda surekli izleme yapilmamalidir.
- Trafik manipule edilmemeli, reklam veya takip amaciyla kullanilmamalidir.
- Play Console veri guvenligi beyanlari, gercek teknik davranisla birebir uyumlu olmalidir.

### 2.7. Uygulama Bazli Trafik Tespiti Riski

**Risk:** "Uygulama: WhatsApp" gibi uygulama bazli trafik atfi ozellikle iOS'ta zor olabilir. Android'de daha fazla olanak olsa bile CDN, QUIC, TLS 1.3, ECH, DoH ve arka plan trafigi nedeniyle kesin tespit zorlasir.

**Cozum:**

- MVP'de otomatik uygulama tespiti yerine kullanici tarafindan secilen test turu esas alinmalidir.
- Kisa ve kontrollu olcum penceresi kullanilmalidir.
- Sonuc dili "WhatsApp trafigi kesin tespit edildi" yerine "WhatsApp manuel test penceresinde gozlenen sinyal" olmalidir.
- Android'de ilerleyen fazda per-app VPN/routing kabiliyetleri degerlendirilebilir.

### 2.8. P2P Gonullu Alici Guvenilirligi

**Risk:** Gonullu alici havuzu dogru modellenmezse kullanici eslesmeleri bosta kalabilir, testler timeout'a dusebilir veya ayni alici birden fazla test icin rezerve edilebilir.

**Cozum:**

Active Pool bir state machine olarak tasarlanmalidir:

- `available`
- `reserved`
- `waiting_for_message`
- `measuring`
- `submitted`
- `timeout`
- `cancelled`
- `failed`

Ek gereksinimler:

- Her alici icin TTL.
- Periyodik heartbeat.
- Eslesme sonrasi aliciyi havuzdan gecici cikarma.
- Test sonunda otomatik release.
- Timeout durumunda session kapatma.
- Kotuye kullanim icin rate limit.

### 2.9. Hash / Paket Karsilastirma Riski

**Risk:** Flowchart'ta alicinin "gelen paketin entropi ve hash degerini" backend'e gonderecegi belirtilmektedir. Ag paketleri iki ucta ayni sekilde gorulmeyebilir; relay, TLS, QUIC, retransmission, farkli paketleme ve sunucu fan-out nedeniyle paket hash'i guvenilir bir karsilastirma temeli degildir.

**Cozum:**

- Paket hash'i yerine session nonce dogrulamasi kullanilmalidir.
- Backend tek kullanimlik test metni veya nonce uretmelidir.
- Gonderen bu nonce'u mesajlasma uygulamasindan gondermelidir.
- Alici uygulamada nonce'u manuel veya lokal olarak dogrulamalidir.
- Backend'e mesaj icerigi degil, "nonce dogrulandi" sinyali gitmelidir.

**Onerilen dogrulama modeli:**

1. Backend session icin tek kullanimlik nonce uretir.
2. Gonderen kullanici nonce iceren mesaji hedef aliciya yollar.
3. Alici nonce'u gordugunu uygulamada onaylar.
4. Iki cihaz ayni session icin olcum ozeti yollar.
5. Backend olcumleri zaman penceresi ve session ID ile eslestirir.

### 2.10. Gizlilik ve Anonimlik Riski

**Risk:** Payload ve hedef IP gondermemek yeterli degildir. Operator, zaman, cihaz modeli, ag turu, test turu, paket boyutu ve oturum suresi gibi alanlar birlikte kullanildiginda yeniden tanimlama riski olusabilir.

**Cozum:**

- "Anonim veri" yerine "veri minimizasyonu, bucket'lama ve kisa saklama" dili kullanilmalidir.
- Detay telemetri kisa sure saklanmali; uzun vadede sadece agregalar tutulmalidir.
- Telefon numarasi backend'de saklanmamalidir.
- IP adresleri uygulama loglarinda maskelenmeli veya kisa surede silinmelidir.
- Operator ve konum bilgisi kaba bucket'lara indirgenmelidir.
- Kullanici veri silme talebi icin isleyen bir mekanizma olmalidir.

**Onerilen retention modeli:**

| Veri tipi | Saklama suresi | Not |
| --- | --- | --- |
| Ham paket | Saklanmaz | Cihazda gecici islenir |
| Detay telemetri | 7-30 gun | Debug ve kalite icin |
| Session state | 24 saat | Timeout ve retry icin |
| Agregalar | 6-12 ay | Dashboard ve trend analizi |
| Telefon numarasi | Saklanmaz | Manuel/P2P akista dahi kacinilmali |

### 2.11. MVP Kapsaminin Fazla Genis Olmasi

**Risk:** Mevcut MVP; Flutter mobil, Flutter web dashboard, Android VPN, iOS NetworkExtension, Go backend, TimescaleDB, Redis, P2P havuz, WhatsApp/RCS testleri ve global matrix gibi cok fazla parcayi ayni anda hedeflemektedir.

**Cozum:** MVP daraltilmalidir.

**Onerilen MVP:**

- Flutter Android uygulama.
- Kotlin tabanli `VpnService`.
- Tek test tipi: manuel WhatsApp testi.
- P2P gonullu alici modeli.
- Go backend.
- Redis active receiver pool.
- PostgreSQL session ve telemetri kaydi.
- Minimal admin/API gorunumu.
- Cihaz ici entropi ve metadata ozeti.

**MVP disina alinmasi onerilenler:**

- iOS App Store surumu.
- Flutter web dashboard.
- TimescaleDB optimizasyonlari.
- Echo-bot.
- RCS entegrasyonlari.
- Global transparency matrix.
- Rust ortak cekirdek.

## 3. Onerilen Faz Plani

### Faz 0 - Laboratuvar Validasyonu

Amac: Olcum modelinin anlamli sinyal uretip uretmedigini dogrulamak.

- Kontrollu test cihazlari.
- Manuel mesajlasma senaryolari.
- Entropi ve paket boyutu olcumleri.
- False positive / false negative analizi.
- `gopacket` ile pcap uzerinden algoritma validasyonu.

### Faz 1 - Android MVP

Amac: Gercek kullanici akisini ve backend korelasyonunu test etmek.

- Flutter Android uygulama.
- Kotlin `VpnService`.
- Kullanici tetiklemeli 2 dakikalik test penceresi.
- P2P active receiver pool.
- Go telemetry backend.
- Confidence score v1.

### Faz 2 - Gizlilik ve Politika Sertlestirme

Amac: Magaza ve kullanici guveni icin veri sinirlarini kesinlestirmek.

- Privacy policy.
- Veri silme akisi.
- Telemetri schema enforcement.
- Retention job'lari.
- Audit log politikalari.
- Google Play closed testing hazirligi.

### Faz 3 - iOS Teknik Prototip

Amac: NetworkExtension ile teknik mumkunlugu dogrulamak.

- Swift `NetworkExtension`.
- Flutter platform channel.
- TestFlight dagitimi.
- Entitlement ve review hazirligi.

### Faz 4 - Dashboard ve Agregasyon

Amac: B2B/SaaS ve global gorunurluk katmanini kurmak.

- TimescaleDB hypertable tasarimi.
- Continuous aggregate sorgulari.
- Flutter Web veya alternatif dashboard.
- Operator/test tipi/zaman bazli trendler.

## 4. Revize Edilmesi Gereken Dokuman Bolumleri

### `ARCHITECTURE_DECISIONS.md`

- Backend bolumunde `gopacket` rolu yeniden yazilmali.
- MVP kapsami yeniden numaralandirilmali ve daraltilmali.
- "E2EE %100 ispat" dili kaldirilmali.
- Cihaz/backend veri sorumluluklari tablo olarak eklenmeli.
- Native katman teknoloji karari netlestirilmeli.
- iOS ve Android fazlari ayrilmali.

### `FLOWCHART.md`

- "Local VPN (Rust/Native)" ifadesi net teknoloji kararina gore guncellenmeli.
- Paket hash'i yerine nonce/session dogrulamasi eklenmeli.
- Timeout, receiver unavailable, user cancel, telemetry upload failed gibi hata akislari eklenmeli.
- Sonuc adimi "Confidence Score" olarak kalmali, ancak ornek metin kesin dogrulama iddiasindan uzaklastirilmali.

## 5. Nihai Tavsiye

OpenE2EE'nin ilk surumu, E2EE'yi kanitlayan bir otorite gibi degil, kullanici kontrollu ve gizlilik odakli bir ag sifreleme olcum araci gibi konumlandirilmalidir.

Basari kriteri su olmalidir:

"Bu test oturumunda, iki uctan gelen cihaz ici olcumler ve session dogrulamasi, beklenen sifreli iletisim davranisiyla ne kadar uyumlu?"

Bu yaklasim teknik olarak daha savunulabilir, magaza politikalarina daha uyumlu ve MVP icin daha uygulanabilirdir.
