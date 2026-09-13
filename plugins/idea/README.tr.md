# `plugins/idea/` — IntelliJ IDEA için SpotBugs eklentisi

**[English](README.md) · [Türkçe](README.tr.md)**

`spotbugs-idea-1.2.8.zip`, IntelliJ IDEA için [SpotBugs eklentisi][mp]; internet
erişimi olmayan bir makinede kurulabilsin diye burada paketli. Bu,
[`scripts/static-scan.sh`](../../scripts/static-scan.sh)'in çalıştırdığı
analizin editöre taşınmış hâli: bir sınıfa sağ tıklıyorsunuz, bulgular kodun
içinde çıkıyor.

[mp]: https://plugins.jetbrains.com/plugin/14014-spotbugs

| | |
|---|---|
| Plugin id | `org.jetbrains.plugins.spotbugs` |
| Sürüm | 1.2.8 |
| Gereksinim | IDEA build `222.1` ve sonrası — yani 2022.2'den itibaren, 2025.2.x dahil |
| Sürümler | Community veya Ultimate (`com.intellij.modules.java` gerekiyor) |
| İçindeki çözümleyici | SpotBugs **4.8.6** |

## Kurulum

`Settings → Plugins → ⚙ → Install Plugin from Disk…`, zip'i seçin, IDE'yi
yeniden başlatın. Marketplace'e hiçbir bağlantı denenmiyor.

Ekip için, zip'i iç ağdaki bir web sunucusundan `updatePlugins.xml` ile
sunmak, yirmi kişinin tek tek diskten kurmasından iyidir — eklentiler o zaman
IDEA'nın normal arama ve güncelleme akışında görünür. Geliştiriciler
`Settings → Plugins → ⚙ → Manage Plugin Repositories → +` ile ekler.

## Bytecode okuyor, o yüzden önce derleyin

İnsanları en çok şaşırtan nokta bu. IDEA'nın kendi inspection'ları siz
yazarken **kaynak** koda bakıyor. SpotBugs ise **derlenmiş bytecode**'a bakıyor
— metot sınırlarını aşarak veri akışını izliyor; kaynak seviyesindeki
inspection'ların kaçırdığı null yollarını ve kapanmayan stream'leri bu yüzden
bulabiliyor.

Pratik sonucu: **önce `Build → Build Project`.** Düzenleyip yeniden
derlemediğiniz bir sınıfı analiz etmek, eski bytecode üzerinden ve artık
tutmayan satır numaralarıyla bulgu üretir.

Sonra: sınıfa veya pakete sağ tık → `SpotBugs → Analyze …`; modülün tamamı için
SpotBugs araç penceresi.

## İlk ayarlar

`Settings → Tools → SpotBugs`

| Ayar | Değer | Neden |
|---|---|---|
| Effort | `Max` | Daha düşük değerler, SpotBugs'ı değerli kılan metotlar arası analizi atlıyor. |
| Minimum confidence | `Medium` | `Low`, bulgu sayısını kabaca üçe katlıyor. `Medium` ile başlayın, rapor temizlendikçe `Low`'a inin. |
| Analysis effort on the fly | kapalı | Her tuş vuruşunda max efor, büyük bir modülde IDE'yi süründürür. |

## Daha yeni kural paketlerini ekleme

Eklenti kendi kural paketleriyle geliyor ve bunlar
[`spotbugs-rule-packs/`](../../spotbugs-rule-packs/) içindekilerden **eski**:

| Eklentinin içindeki | Bu depodaki |
|---|---|
| `fb-contrib-7.6.0` (ve `6.2.1`) | `sb-contrib-7.6.9` |
| `findsecbugs-plugin-1.12.0` | `findsecbugs-plugin-1.14.0` |
| `AndroidFindbugs_0.5` | — |

Yenilerini kullanmak için: `Settings → Tools → SpotBugs → Plugins → +` ile
`spotbugs-rule-packs/sb-contrib-7.6.9.jar` ve
`spotbugs-rule-packs/findsecbugs-plugin-1.14.0.jar` dosyalarını diskten ekleyin.

> **Önce her birinin gömülü kopyasını devre dışı bırakın.** SpotBugs aynı
> plugin id'sine sahip iki eklentiyi yüklemeyi reddediyor ve bu çiftler aynı
> id'yi paylaşıyor — `com.mebigfatguy.fbcontrib` ve
> `com.h3xstream.findsecbugs`. İkisi birden açıkken analiz, yenisini seçmek
> yerine tamamen başarısız oluyor.

## Bir exclude filtresi tanımlayın

`Settings → Tools → SpotBugs → Filter → Exclude filter files → +` ile
[`spotbugs-rule-packs/spotbugs-exclude.xml`](../../spotbugs-rule-packs/spotbugs-exclude.xml)
dosyasını gösterin.

Filtre olmadan `EI_EXPOSE_REP` ve `EI_EXPOSE_REP2` neredeyse her getter ve
setter'da tetikleniyor. Rapor binlerce bulguyla doluyor ve ekip raporu okumayı
bırakıyor — bunun maliyeti, içinde gömülü kalan iki gerçek hatadan yüksek.

## IDE konfor, build otorite

SpotBugs'ı build'inizde çalıştırın ve yeni bulgularda build'i kırın. IDE
eklentisi kod yazarken döndüğünüz döngü için; bir kalite kapısı değil, çünkü
yalnızca birinin sağ tıklamayı hatırladığı yeri kapsıyor. CLI ve Maven
bağlantısı için bkz.
[`spotbugs-rule-packs/README.tr.md`](../../spotbugs-rule-packs/README.tr.md#build-içinde-kullanım).

İkisini karşılaştıracaksanız bir uyarı: bu eklenti SpotBugs **4.8.6**
içeriyor, `static-scan.sh`'in kullandığı
[`compile-time/spotbugs-4.10.4.tgz`](../../compile-time/) ise **4.10.4**.
Bulgular yakın ama birebir aynı değil. Çeliştiklerinde daha yeni çözümleyici
CLI'dakidir.

## Bu ne değil

SpotBugs hata *desenlerini* buluyor. Hangisinin sıcak yolda olduğunu bilmiyor;
başlangıçta bir kez çalışan bir `String` birleştirmesini, 400 turluk bir
döngünün içindekiyle aynı vurguyla işaretliyor. Zamanın gerçekte nereye
gittiğini [`diagnose.sh`](../../scripts/diagnose.sh) ile bulun, sonra buraya
dönüp SpotBugs'ın o metot hakkında zaten söyleyecek bir şeyi var mıymış diye
bakın.

## Lisans

SpotBugs IDEA eklentisi, SpotBugs'ın kendisi gibi LGPL 2.1. Bu deponun
[`LICENSE`](../../LICENSE) dosyası kapsamında değil.
