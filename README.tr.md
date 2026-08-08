# A5N

AI kodlama ajanı transkriptlerini, onlardan uzun ömürlü bir bilgi arşivine
çevirir.

[English](README.md)

## Sorun

Claude Code ve Codex her oturumu diske yazar, sonra siler. Claude Code
transkriptleri `cleanupPeriodDays` süresinden sonra temizler, varsayılanı otuz
gün. Yani altı hafta önce verdiğin bir kararın gerekçesi, bir kez çözdüğün
bug'ın kök nedeni, bariz görünen yaklaşımı neden reddettiğin, hepsi gitmiş
olur. Aynı problemi tekrar çözersin, ajan da zaten reddettiğin yaklaşımı
tekrar önerir, çünkü ikiniz de hatırlamıyorsunuz.

## A5N ne yapar

Her sabah deterministik bir script dünkü oturumları bulur ve ham
transkriptleri kalıcı bir yere kopyalar. Sonra oturum başına bir headless ajan
onu bağlantılı bir markdown wiki'ye damıtır: oturum başına bir sayfa, artı
dokunduğu kararlar, bug'lar, entity'ler ve kavramlar için sayfalar. Haftada
bir de aynı mekanizma o wiki'yi çelişki, ölü link ve şema sapması açısından
denetler.

Çıktı bir git repo'sundaki düz markdown. Obsidian gezinmek için güzel bir yol
ve tamamen isteğe bağlı. Hiçbir şey senin diskinin dışına çıkmaz.

![A5N nasıl çalışır](assets/architecture.svg)

Sistemin asıl kazandıran parçası `patterns/`. Bir ders onu üreten projenin
ötesinde de geçerliyse kendi sayfasını alır ve bir sonraki proje onu bulur. Bir
not yığını ile zamanla biriken bir şey arasındaki fark budur.

Uydurma dört sayfalık örnek çıktı için [example/](example/) klasörüne, sistemin
asıl amacı için
[pattern sayfasına](example/patterns-example/retry-without-a-budget-amplifies-an-outage.md)
bakın.

## Kurulum

macOS veya Linux, Python 3.9 ya da üstü, git, ve gözetimsiz koşular için Claude
Code CLI ile Codex CLI'dan biri gerekir. İşçileri hangisinin koşturacağı,
hangi modelle ve hangi reasoning effort'la koşacağı `config.ini` içindeki
`[runner]` bölümünden seçilir; örnek config kopyala yapıştır değer listeleri
taşır, böylece yazım hatası zamanlanmış koşuya ulaşamaz.

```bash
git clone https://github.com/ardasenn/A5N.git
cd A5N
cp config.example.ini config.ini
$EDITOR config.ini
zsh scripts/setup.sh
```

`setup.sh` vault'u oluşturur, şemayı içine yazar, config'teki her proje için
bir namespace açar, git'i başlatır ve zamanlanmış görevleri kurar. İstediğin
zaman tekrar çalıştırabilirsin: mevcut sayfaların üzerine asla yazmaz,
dolayısıyla yeni proje eklemenin ve zamanlamayı değiştirmenin yolu budur.

`config.ini` yoksa hiçbir şey çalışmaz. Taze bir klon yanlışlıkla bir vault'a
dokunamaz.

## Konfigürasyon

Tek dosya, `config.ini`. Proje eklemek tek bir bölüm:

```ini
[project:acme-shop]
repo = ~/work/acme-shop
match = acme-shop
watermark = 2026-01-01
```

`match` bir alt dizedir. Hem Claude Code proje klasörünün adına hem Codex
oturumunun çalışma dizinine bakılır, dolayısıyla tek değer genelde ikisini de
kapsar. Git worktree'leri de otomatik eşleşir, çünkü yolları aynı alt dizeyi
içerir.

`watermark` sabit bir tarihtir, kayan bir pencere değil. Ondan eski oturumlar
yok sayılır. Temiz başlamak için bugünü, geçmişi çekmek için daha eski bir
tarihi yaz. Sabit olduğu için, bir hafta kapalı kalan makine geri döndüğünde
hiçbir şey kaybetmez.

Tüm ayarlar için [config.example.ini](config.example.ini) dosyasına bakın.

## Çalıştırma

```bash
zsh scripts/daily-ingest.sh    # zamanlayıcının her sabah koştuğu
zsh scripts/weekly-lint.sh     # haftalık koştuğu
```

İkisi de istediğin an elle çalıştırılabilir. Kilit aldıkları için elle koşu ile
zamanlanmış koşu çakışamaz.

## Geri okumak

Vault ancak içinden okunan kadar değerlidir; bu yüzden A5N, MCP destekli her
ajana okuma erişimi veren bir MCP server ile gelir: sayfalarda sıralı arama,
vault genel görünümü ve tam sayfa okuma. Makine başına bir kez kaydet, her
ajan oturumu geçmişini tekrarlamadan önce vault'a danışabilsin:

```bash
claude mcp add --scope user a5n -- python3 "$(pwd)/scripts/a5n-mcp.py"
```

```toml
# Codex, ~/.codex/config.toml içine
[mcp_servers.a5n]
command = "python3"
args = ["/path/to/A5N/scripts/a5n-mcp.py"]
```

Server salt okunurdur, `raw/` altını asla açmaz ve sıralamayı kendi yapar;
yani bir sorgu, çağıran ajanın zaten harcadığının ötesinde hiçbir şeye mal
olmaz. `setup.sh` bu komutları gerçek yollarla doldurup basar.

## Birikeni görmek

Ayda bir, deterministik bir script, model yok, vault'un git geçmişini
`digests/` altında tek sayfaya çevirir: proje başına işlenen oturumlar,
açılan ve güncellenen sayfalar, yeni pattern'lar, en çok referans alan
sayfalar, ve hiçbir şey işlenmeden geçen ayı yüksek sesle söyleyen bir sağlık
satırı. O son madde önemli: sessizce bozulan bir boru hattı, biri farkı
görünür kılana kadar sakin bir aydan ayırt edilemez.

```bash
zsh scripts/digest.sh            # geçen ay
zsh scripts/digest.sh 2026-07    # herhangi bir ay
```

Kurulum anında bekleyen oturumlar varsa A5N, ilk değer anını yarınki
zamanlanmış koşuya bırakmak yerine birikimi hemen işlemeyi önerir.
`config.ini` içindeki `watermark` o geçmişin ne kadar geriye uzanacağını
belirler.

## Neden bozulmuyor

Gözetimsiz görevler, aksi tasarlanmadıkça sessizce başarısız olur. Mimarinin
buna cevabı tek ilke: orkestrasyon deterministik script'te, model sadece
yaprakta çalışır.

- **Keşfe model hiç karışmaz.** Bir Python script'i transkript klasörlerini
  tarar, adayları eler ve tekilleştirir, geçenleri vault'a kopyalar. Zaman
  baskısı olan tek iş budur, çünkü ajanlar transkriptleri bir süre sonra
  siler, ve bu işin hiçbir parçası halüsinasyon göremez.
- **Oturum başına bir işçi, eseriyle doğrulanır.** Kuyruktaki her oturum kendi
  headless ajan koşusunu alır. Koşu bitince bir script diske gerçekten ne
  yazıldığına bakar: değişen yollar şemanın içinde mi, bir sayfa ya da
  gerekçeli skip satırı oluşmuş mu, frontmatter tam mı. İşçinin kendi sözüne
  asla güvenilmez. Önceki tasarım çıktıda sonuç imzası grep'liyordu ve imzanın
  etrafındaki tek bir backtick bir keresinde işlenmiş on iki oturumu geçersiz
  kıldı.
- **Birimler bağımsız commit'lenir.** Doğrulamayı geçen birim anında
  commit'lenir. Kalan birim tek başına geri alınır, kuyrukta kalır ve yarın
  yeniden denenir; kardeşlerinin işi çoktan güvendedir. Kuyruğun ayrıca bir
  kayıt dosyasına ihtiyacı yoktur, çünkü vault'un kendisi state'tir:
  sayfalarda izi olmayan bir ham transkript tanım gereği hâlâ kuyruktadır.
- **Reddedilen birim bir şans daha alır.** Doğrulamanın red sebepleri prompt'a
  eklenir ve işçi bir kez daha koşar, böylece sıradan uyum değişkenliği koşu
  içinde kapanır, kuyruk günlerce aynı birimi çiğnemez.
- Vault bir git repo'sudur ve işçi başlamadan önce ağaç her zaman temizdir,
  dolayısıyla geri alma yalnızca o işçinin çıktısına dokunabilir.
- Tek kilit dosyasını bütün görevler paylaşır, ingest, lint ve digest,
  dolayısıyla hiçbiri diğeriyle çakışamaz. İki saatten eski kilit ölü
  sayılır, çünkü çöken bir süreç temizlik trap'ini çalıştıramaz ve ölü kilit
  sonraki tüm koşuları sessizce yutar.
- Watchdog, birim başına duvar saatini aşan işçiyi keser. Bu bir iş sınırı
  değil, sadece sonsuza asılmaya karşı bir koruma.
- Atlama asla sessiz olmaz. İçeriği yüzünden elenen her oturum, küçük ya da
  kopya, proje log'una deterministik bir satır düşürür; modelden rica
  edilmez, script yazar. İki istisna bilinçlidir: watermark elemesi zaten
  senin ayarındır, fazla taze oturum ise sadece yarını bekler.
- Yapılacak iş olmayan günde model hiç çağrılmaz. Sessizlik başarıdır,
  bildirim sadece hatada düşer.

Bunların her biri, eksik olduğu bir versiyonda gerçek bir arıza yaşandığı için
var.

## Transkript formatları

| | Claude Code | Codex |
|---|---|---|
| Konum | `~/.claude/projects/<klasör>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Proje eşleşmesi | klasör adı | oturumun kendi çalışma dizini |
| Kopyada süzülen | `attachment/hook_success`, yaklaşık %64 | `event_msg/token_count`, yaklaşık %1.4 |

İki süzme de yalnızca hiçbir bilgi taşımayan kayıtları atar. Geri kalan her şey
bayt bayt kopyalanır, görseller dahil. Süzme listesine yeni kayıt türü eklemek
şema değişikliğidir: önce hiçbir şey taşımadığını kanıtla.

Büyük transkriptler okunmadan önce yoğunlaştırılır. Boyut içerikten değil gömülü
ekran görüntülerinden gelir, dolayısıyla onları atmak 107 MB'lık bir oturumu
konuşma bütünlüğü bozulmadan 404 KB'a indirdi.

Cursor desteklenmiyor. Sohbet geçmişini, sürümler arasında değişen ve
belgelenmemiş bir şemayla SQLite dosyasında tutuyor, dolayısıyla yazılacak
adaptör sık sık kırılırdı. Aksini düşünüyorsanız pull request bekleriz.

## Lisans

MIT. Bkz. [LICENSE](LICENSE).
