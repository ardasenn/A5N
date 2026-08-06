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

Her sabah dünkü oturumları bulur, ham transkriptleri kalıcı bir yere kopyalar
ve bağlantılı bir markdown wiki'ye damıtır: oturum başına bir sayfa, artı
dokundukları kararlar, bug'lar, entity'ler ve kavramlar için sayfalar. Haftada
bir de o wiki'yi çelişki, ölü link ve şema sapması açısından denetler.

Çıktı bir git repo'sundaki düz markdown. Obsidian gezinmek için güzel bir yol
ve tamamen isteğe bağlı. Hiçbir şey senin diskinin dışına çıkmaz.

Sistemin asıl kazandıran parçası `patterns/`. Bir ders onu üreten projenin
ötesinde de geçerliyse kendi sayfasını alır ve bir sonraki proje onu bulur. Bir
not yığını ile zamanla biriken bir şey arasındaki fark budur.

Uydurma dört sayfalık örnek çıktı için [example/](example/) klasörüne, sistemin
asıl amacı için
[pattern sayfasına](example/patterns-example/retry-without-a-budget-amplifies-an-outage.md)
bakın.

## Kurulum

macOS veya Linux, Python 3.9 ya da üstü, git, ve gözetimsiz koşular için Claude
Code CLI gerekir.

```bash
git clone https://github.com/<sen>/a5n.git
cd a5n
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

## Neden bozulmuyor

Gözetimsiz görevler, aksi tasarlanmadıkça sessizce başarısız olur. Bu yüzden:

- Ajan çıktısını bir imza satırıyla bitirmek zorundadır. İmza yoksa ajan
  gerçekten çalışmamıştır, koşu başarısız sayılır, commit atılmaz ve bildirim
  düşer.
- Vault bir git repo'sudur ve koşu başlamadan önce ağaç her zaman temizdir. Bu
  noktadan sonraki her kirlilik ajan çıktısıdır, dolayısıyla başarısız koşu
  `reset --hard` ile geri alınır ve yarım iş asla commit'e ulaşmaz.
- Kilit dosyası çakışmayı engeller. İki saatten eski kilit ölü sayılır, çünkü
  çöken bir süreç temizlik trap'ini çalıştıramaz ve ölü kilit sonraki tüm
  koşuları sessizce yutar.
- Watchdog, duvar saatini aşan koşuyu keser. Bu bir iş sınırı değil, sadece
  sonsuza asılmaya karşı bir koruma.
- Atlama asla sessiz olmaz. İşlenemeyen oturum için proje log'una bir satır
  düşer.

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
