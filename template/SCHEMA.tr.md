# {{VAULT_TITLE}}

Bu dosya şemadır. Bu vault'a dokunan her ajan önce burayı okur ve harfiyen uyar.

## Amaç

Tek vault, proje başına bir namespace. Her namespace o projenin kalıcı bilgi
arşividir: sohbet oturumları, kararlar, bug'lar, mimari notlar zamanla birikip
aranabilir bir wiki'ye dönüşür.

Dil: tüm sayfalar {{LANGUAGE}} yazılır. Teknik terimler özgün halinde kalabilir.

Not: frontmatter alan adları ve enum değerleri (`status`, `state` ve
değerleri) sayfa dilinden bağımsız olarak İngilizce kalır. Sebep basit,
lint ve script'ler bu değerleri denetliyor, dile göre değişseler her dil
için ayrı bir kontrol listesi gerekirdi.

## Namespace kuralı

Her proje kendi üst klasöründe izole yaşar. Bir projenin sayfası diğer
projenin klasörüne asla yazılmaz. Kod seviyesinde kesişim olmaması normaldir,
stack'ler farklıdır, zorlanmaz.

Projeler arasında ortak olan şey kod değil yöntemdir. Nasıl release alırım,
bir bug'a nasıl yaklaşırım, hangi hata sınıfından kaçınırım. Bunlar kök
`patterns/` klasörüne gider, aşağıdaki cross project kuralına bakın.

## Kök dosyalar

```
vault/
├── CLAUDE.md    bu dosya, tüm projeler için tek şema
├── AGENTS.md    CLAUDE.md'ye işaret eder, Claude dışı ajanlar da aynı kuralı okusun
├── index.md     İNCE, sadece proje listesi ve ortak desenler
├── log.md       İNCE, sadece vault seviyesi olaylar (yeni proje, şema değişikliği)
├── GOALS.md     hedeflerin hep güncel tek dosya fotoğrafı, aşağıya bakın
├── patterns/    projeler arası yöntem sayfaları, stack'ten bağımsız
├── chess-moves/ ileriye dönük strateji oturumları, tarihli, aşağıya bakın
├── digests/     aylık özet sayfaları, zamanlanmış digest görevi yazar
└── <proje>/     proje başına bir namespace, her biri kendi index ve log'uyla
```

## Chess moves kuralı

`chess-moves/YYYY-MM-DD-<slug>.md` stratejik düşünme oturumlarının çıktısını
tutar: hedefler, hamle planları, öncelik tartışmaları. Vault'un geri kalanının
aynadaki tersidir. Wiki geriye bakar ve kanıt kaydeder, chess moves ileriye
bakar ve niyet kaydeder.

* Sadece kullanıcıyla birlikte, açık istek üzerine yazılır. Zamanlanmış ingest
  buraya asla yazmaz.
* Eski oturum dosyaları güncellenmez, yenisi yazılır. Tarihli snapshot'lar
  düşüncenin evrimini görünür kılar.
* Sorgu sırasında okunabilir. "Bu iş hedefe hizmet ediyor mu" tarzı sorularda
  en güncel chess moves dosyası bağlam olur.

## GOALS.md kuralı

`GOALS.md` hedeflerin ve mevcut durumun hep güncel tek dosya özetidir. Chess
moves müzakere, GOALS.md sonuçtur, dolayısıyla bir chess moves oturumunun
sonunda güncellenmesi doğal akıştır. Sadece kullanıcı beyanıyla yazılır.
Zamanlanmış görevler asla dokunmaz.

Kök `index.md` ve `log.md` proje sayısı büyüse de kısa kalır. Detay
`<proje>/index.md` ve `<proje>/log.md` içinde yaşar.

## Cross project pattern kuralı

Ingest sırasında yazılan her decision ve bug için sor: bu ders başka bir
projede de geçerli olur mu, stack'ten bağımsız bir yöntem ya da prensip mi?

* Evetse `patterns/<slug>.md` yaz veya mevcut sayfayı güncelle. İçerik: dersin
  ne olduğu, hangi projede hangi somut olayda yaşandığı, genel kural. Her iki
  projenin sayfasından bu pattern sayfasına link ver, kök `index.md`'nin ortak
  desenler bölümüne ekle.
* Hayırsa, yani koda veya stack'e özgüyse, proje lokal sayfa yeterlidir.

Sorgu sırasında: soru metodoloji veya süreç hakkındaysa önce kök `patterns/`'a
bak, sonra ilgili projenin sayfalarına in. Soru bir projeye özgüyse doğrudan o
projenin `index.md`'sinden başla.

## Klasör yapısı, her proje için aynı

```
<proje>/
├── raw/
│   ├── sessions/   ajan transkriptleri (JSONL), DOKUNULMAZ
│   └── docs/       statik dökümanlar, PDF, tasarım notu, DOKUNULMAZ
├── sources/
│   └── sessions/   her ham kaynak için bir özet sayfası
├── entities/       dosyalar, fonksiyonlar, servisler, ekranlar, özellikler, kişiler
├── concepts/       soyut kavramlar ("eşleştirme algoritması", "onboarding akışı")
├── decisions/      atomik kararlar, her karar bir sayfa
├── bugs/           düzeltilen sorunlar: kök neden ve fix
├── syntheses/      üst düzey genel bakış sayfaları (mimari, roadmap özeti)
└── archive/        eskimiş sayfalar, asla silinmez
```

## Sayfa formatı

YAML frontmatter, H1 başlık, içerik, ardından `## Sources` ve `## Related`.

```yaml
---
title: <başlık>
tags: [<proje>, <kategori>, ...]
source: <raw/... yolu veya "manual">
date: YYYY-MM-DD
status: active | stale | archived
state: open | pending | fixed | closed   # SADECE bugs/ sayfalarında
---
```

Bu biçim her sayfa türü için aynıdır, `patterns/` ve `chess-moves/` dahil.
Başka bir frontmatter şeması vault sayfasında kullanılmaz. Özellikle
`name` / `description` / `metadata` biçimi ajanın kendi hafıza dosyalarına
aittir, buraya sızmamalıdır.

### Enum kuralı, listeler kapalı

`status` ve `state` alanlarının değer listeleri kapalıdır. Yeni değer icat
etmek yasaktır, eş anlamlı bile olsa (`resolved`, `done`, `pr-open`,
`in review` gibi). Bir durum listedeki değerlerden birine tam oturmuyorsa en
yakın değeri seç, nüansı gövdedeki `## Durum` bölümüne düz metin yaz.
Frontmatter'ı asla zorlama.

* `status` SAYFANIN güncelliğidir, her sayfa türünde:
  * `active`, sayfa güncel ve doğru
  * `stale`, içeriği eskimiş, güncellenmeli
  * `archived`, `archive/` altına taşınmış
* `state` BUG'ın gerçek durumudur, sadece `bugs/` sayfalarında:
  * `open`, sorun duruyor, fix yok (belirsizse varsayılan budur)
  * `pending`, fix yazıldı ama canlıda değil (PR açık, review'da, merge oldu
    deploy olmadı, veri backfill'i bekliyor)
  * `fixed`, fix canlıda ve doğrulandı
  * `closed`, fix'siz kapandı (duplicate, wontfix, geçersiz)

Bir bug çözülse bile sayfası `status: active` kalır, çünkü sayfa hâlâ
doğrudur. İki alan ortogonaldir, birbirinin yerine geçmez.

Kural neden yazılı: bir vault'ta ilk toplu ingest, 88 bug sayfasında 8 farklı
`status` değeri üretti, `fixed` ve `resolved` aynı anda vardı, çünkü şema
hiçbir yere yazılmamıştı ve her koşu kendi sözlüğünü uydurdu.

### Link kuralı

Link (`[[wikilink]]` veya `[metin](yol)`) sadece vault içindeki sayfalara
verilir. Kod dosyası yolları ve sınıf ya da metot adları backtick'le düz metin
yazılır, link değil:

* doğru: `` `apps/backend/.../ListingRepository.cs:142` ``
* yanlış: `[ListingRepository.cs:142](apps/backend/.../ListingRepository.cs:142)`
* yanlış: `[[apps/backend/.../ListingRepository.cs:142]]`

Harici URL'ler normal markdown link olabilir. Kural sadece repo içi kod
yolları içindir.

Sebep: hedefi vault'ta olmayan her link ölü linktir ve haftalık lint bunların
hepsini raporlar.

## Adlandırma

kebab-case dosya adları. `sources/sessions/YYYY-MM-DD-<slug>.md`.

## INGEST akışı, iki katman

Günlük ve gözetimsiz: `scripts/daily-ingest.sh`. İlke: ORKESTRASYON
DETERMİNİSTİK SCRIPT'TE, MODEL SADECE YAPRAKTA ÇALIŞIR ("oku ve yaz");
başarı beyanla değil ESERLE ölçülür; birimler bağımsız commit'lenir. (Önceki
tasarım, keşif, kopyalama, sayfa ve sonuç imzasını tek model koşusuna verip
hatada toptan geri alıyordu; her hafta yeni bir koreografi hatası üretti ve
bir keresinde bitmiş bir günün işini sildi.)

**Katman 1, yakalama (saf script, LLM yok).** `ingest-discover.py capture`
`config.ini`'deki iki transkript kaynağını tarar (keşfin tek otoritesi),
watermark, tazelik, boyut ve içerik kopyası elemelerini uygular, geçenleri
`import-transcript.py` süzgeciyle `<proje>/raw/sessions/` içine kopyalar.
Symlink değil: ajanlar eski transkriptleri bir süre sonra siler, Claude Code
varsayılan olarak yaklaşık otuz gün sonra, vault kendi kalıcı kopyasını
tutar. Zaman baskısı olan tek iş budur. Sayfaların `source:` frontmatter'ı bu
vault içi yolu gösterir.

İki ajan formatı desteklenir ve ilk satırdan tanınır:
* **Claude Code**, `<claude_projects>/<klasör>/<uuid>.jsonl`, hedef ad
  `<uuid>.jsonl`, eşleme klasör adıyla. Süzgeç `attachment/hook_success`
  kayıtlarını atar, dosyanın yaklaşık yüzde 64'ü ve sıfır bilgi, aynı veri
  `tool_result`/`tool_use` olarak zaten durur.
* **Codex**, `<codex_sessions>/YYYY/MM/DD/rollout-*.jsonl`, hedef ad
  `codex-<session_id>.jsonl`, eşleme oturumun kendi çalışma diziniyle.
  Süzgeç yalnızca `event_msg/token_count` telemetrisini atar.

Kopya ölçütü dosya adı değil İÇERİKTİR (süzülmüş ilk satır): aday mevcut bir
raw'ın içindeyse kopyalanmaz; aday daha genişse yeni kimliğiyle kopyalanır,
eskisi silinmez. Küçük ve kopya elemeleri `<proje>/log.md`'ye DETERMİNİSTİK
skip satırı düşer, "sessizce atlama yasak" artık script garantisidir. Sonuç
tek commit: `chore: raw capture`.

State ayrı dosyada tutulmaz, VAULT'UN KENDİSİ STATE'TİR:
- yakalandı = `<proje>/raw/sessions/<id>.jsonl` mevcut
- işlendi = İZ var demektir ve yalnızca iki biçim iz sayılır: tam ham yolu
  (`raw/sessions/<id>.jsonl`) içeren bir kaynak sayfası, ya da
  `<proje>/log.md` içinde `skip | <id>` satırı. Düz metinde geçen çıplak
  bir kimlik iz DEĞİLDİR, yani bir not hiçbir oturumu sessizce kuyruktan
  düşüremez. Ham dosyası olup izi olmayan oturum kuyruktadır.

**Katman 2, işleme (oturum başına bir model işçisi).** `ingest-discover.py
queue` işlenmemişleri listeler (eski önce, koşu başına tavan config'de);
sürücü her biri için AYRI, senkron headless işçi koşturur
(`scripts/prompts/ingest-unit.md`; subagent, zamanlama ve arka plan işi
kapalı, birim başına duvar saati; eşiği aşan transkript önce iskelete
indirilir). Birim bitince `ingest-verify.py` ESERİ mekanik doğrular:
değişiklikler şema içi yolda mı, kimlik izi (sayfa ya da skip satırı) var
mı, frontmatter tam mı. Geçerse birim ANINDA commit'lenir
(`chore: ingest(<proje>) <id>`); kalırsa SADECE o birim geri alınır,
kuyrukta kalır, yarın kendiliğinden yeniden denenir. Boş günde model hiç
çağrılmaz. Sessizlik başarıdır, bildirim sadece hatada.

**İşçi adımları** (birim prompt'u buraya işaret eder; elle "şu oturumu işle"
dendiğinde de aynı akış geçerlidir):

1. Oturumu oku, ana konuyu çıkar.
2. `<proje>/sources/sessions/YYYY-MM-DD-<slug>.md` yaz (tarih = oturumun
   kendi tarihi): amaç, ne yapıldı, değişen dosyalar, kararlar, sorunlar,
   açık konular.
3. Bahsedilen her entity, concept, decision ve bug sayfasını oluştur veya
   çapraz güncelle, çift yönlü link ver; oturum mevcut bir sayfanın
   DURUMUNU değiştiriyorsa (bug çözüldü, karar aşıldı) o sayfayı da güncelle.
4. Yukarıdaki cross project pattern kuralını uygula.
5. `<proje>/index.md`'yi güncelle.
6. `<proje>/log.md`'ye `## [YYYY-MM-DD] ingest | <slug>` satırı ekle.

## QUERY akışı

1. Soru bir projeye özgüyse `<proje>/index.md`'den başla. Metodoloji veya
   süreç sorusuysa önce kök `patterns/`'a bak.
2. `sources/`, `entities/`, `concepts/`, `decisions/` ve `syntheses/` altında
   ilgili sayfalara in.
3. Cevap her iddia için kaynak referansı verir.
4. Değerli bir sentez veya karşılaştırma üretildiyse `<proje>/syntheses/`
   altına atomik sayfa olarak geri dosyala. Birden fazla projeyi
   ilgilendiriyorsa `patterns/` altına.
5. `<proje>/log.md`'ye `## [YYYY-MM-DD] query | <soru özeti>` satırı ekle.

## LINT akışı

Haftalık ve gözetimsiz, `scripts/weekly-lint.sh`, iki katman.

1. **Mekanik, deterministik.** `scripts/fix-links.py` yanlış yol linklerini
   otomatik düzeltir, sistemdeki tek otomatik düzenleme budur.
   `scripts/lint-mech.py` ölü link ve orphan taraması yapar. Namespace
   listesi dinamiktir, kökte `sources/` klasörü olan her dizin, yani yeni
   proje kendiliğinden kapsanır.
2. **Semantik, sadece rapor, proje başına bir işçi.** Çelişkiler, eksik
   cross reference, sayfası olmayan kavramlar, frontmatter sapmaları, yanlış
   link hedefleri. `<proje>/lint-report.md` üzerine yazılır (eski rapor git
   geçmişinde), `<proje>/log.md`'ye tek satır düşer. Doğrulama mekaniktir,
   sadece bu iki dosya değişebilir, dolayısıyla başarısız bir proje
   diğerlerini düşüremez. Semantik bulgular otomatik düzeltilmez, neyin
   değişeceğine kullanıcı karar verir.

## Yeni proje ekleme

1. `config.ini` dosyasına bir `[project:<ad>]` bölümü ekle.
2. `scripts/setup.sh`'yi tekrar çalıştır. Namespace iskeleti, `index.md` ve
   `log.md` senin için oluşturulur.
3. Kök `index.md`'deki proje listesine tek satır ekle.
4. Proje repo'suna iki dokunuş: `CLAUDE.md` veya `AGENTS.md` dosyasına
   namespace'i gösteren bir "A5N bilgi arşivi" bölümü, ve
   `.claude/settings.local.json` dosyasındaki
   `permissions.additionalDirectories` alanına vault yolu, böylece orada
   çalışan ajan arşivi okuyabilir.
5. Kök `log.md`'ye `## [YYYY-MM-DD] setup | <proje> namespace'i açıldı` satırı
   ekle.

## Değişmez kurallar

1. `raw/` asla değiştirilmez, sadece okunur. Tek istisna INGEST yakalama
   katmanıdır, o da yeni dosya ekler, mevcuda asla dokunmaz; katman 2
   işçisinin `raw/` altına yazması doğrulamadan döner. Süzme sadece sıfır
   bilgi taşıyan kayıtları atar, dolayısıyla ham sadakat korunur. Süzme
   listesine yeni bir kayıt türü eklemek şema değişikliğidir: önce kaydın
   hiçbir bilgi taşımadığı kanıtlanır, sonra o satır güncellenir. Fazlalık ham
   dosya silmek, yani aynı konuşmanın ikinci nüshasını atmak kullanıcı
   kararıdır. Zamanlanmış görevler kendi başına raw dosyası silmez.
2. Kaynaksız iddia yasaktır. Her önemli cümle hangi raw veya source dosyasına
   dayandığını belirtir.
3. Sayfa silinmez, `archive/` altına taşınır.
4. Çelişkiler `## ÇELİŞKİ` başlığıyla işaretlenir, silinmez.
5. Bir proje diğerinin klasörüne asla yazmaz.
6. Şema zamanla evrilir. Bir kural çalışmıyorsa bu dosya güncellenir.
