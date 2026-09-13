# `spotbugs-rule-packs/` — ek SpotBugs dedektörleri

**[English](README.md) · [Türkçe](README.tr.md)**

Pakete dahil SpotBugs 4.10.4, 196 dedektör içinde 518 hata deseniyle geliyor.
Buradaki iki jar 463 desen daha ekliyor. Bunlar IntelliJ eklentisi **değil** ve
`00-setup.sh` bunları açmıyor — düz SpotBugs *plugin jar*'ları; iki şekilde
yükleniyorlar:

- **Komut satırından** — [`scripts/static-scan.sh`](../scripts/static-scan.sh)
  bu klasördeki her `.jar`'ı bulup SpotBugs'a `-pluginList` ile veriyor.
  Yapılandırma gerekmiyor.
- **IntelliJ IDEA'dan** — `Settings → Tools → SpotBugs → Plugins → +` ile bu
  jar'ları diskten seçiyorsunuz. Bkz. [`plugins/idea/`](../plugins/idea/).

## İçerik

| Jar | Plugin id | Desen | Dedektör |
|---|---|---|---|
| `sb-contrib-7.6.9.jar` | `com.mebigfatguy.fbcontrib` | 319 | 153 |
| `findsecbugs-plugin-1.14.0.jar` | `com.h3xstream.findsecbugs` | 144 | 121 |

Bir desenin hangi kategoriye düştüğü, onu hiç görüp görmeyeceğinizi belirliyor:

| | CORRECTNESS | STYLE | PERFORMANCE | MT_CORRECTNESS | SECURITY |
|---|---|---|---|---|---|
| SpotBugs çekirdek | 159 | 94 | 37 | 54 | 23 |
| **sb-contrib** | 187 | 80 | **43** | 8 | — |
| **findsecbugs** | — | — | — | — | **144** |

Profilleme işi için asıl önemli olan **sb-contrib**: kullanılabilir PERFORMANCE
desen sayısını iki katından fazlasına çıkarıyor ve çekirdek SpotBugs'ın
bakmadığı yerlere bakıyor — sınırsız büyüyen alanlar
(`PMB_POSSIBLE_MEMORY_BLOAT`), doldurulup hiç okunmayan koleksiyonlar
(`WOC_WRITE_ONLY_COLLECTION`), döngü içinde boxing, `keySet()` üzerinden dönüp
her anahtar için `get()` çağıran `Map` iterasyonu.

**findsecbugs** bir güvenlik paketi — deserialization, path traversal, zayıf
kripto, XXE, komut enjeksiyonu. 144 deseninin tamamı `SECURITY` kategorisinde.

## `--security` neden var

`static-scan.sh` SpotBugs'tan `PERFORMANCE,CORRECTNESS,MT_CORRECTNESS`
istiyor. Burası bir profilleme paketi ve her XXE riskini de sıralayan bir
performans raporunu kimse sonuna kadar okumuyor. `SECURITY` bu listede
olmadığı için **findsecbugs varsayılanda yükleniyor ama sessiz kalıyor.**
Açıkça açmak gerekiyor:

```bash
./scripts/static-scan.sh --security build/classes src/main/java
```

Ya da kategorileri kendiniz seçin:

```bash
./scripts/static-scan.sh --categories SECURITY build/classes
```

## Exclude filtresi

`spotbugs-exclude.xml` varsayılan olarak uygulanıyor. Üç şeyi eliyor:

| Elenen | Neden |
|---|---|
| `EI_EXPOSE_REP`, `EI_EXPOSE_REP2`, `MS_EXPOSE_REP` | Neredeyse her getter'da tetikleniyor. Açık kalırsa rapor bunlardan ibaret oluyor, ekip raporu okumayı bırakıyor. |
| `*Test`, `*Tests`, `*TestCase`, `Test*`, `*.test.*` sınıfları | Sıcak yolda değiller ve testler bu dedektörlerin işaretlediği şeyleri meşru sebeple yapıyor. |
| Sentetik ve üretilmiş sınıflar | `Foo$1`, `Foo$$Bar`, `generated/` altındaki her şey. |

Sonuncusu kozmetik değil: enum üzerinde `switch`, javac'ın `$SwitchMap` tutan
bir sınıf üretmesine yol açıyor ve dedektörler kimsenin yazmadığı bu kodda
tetikleniyor.

Yine de hepsini görmek için:

```bash
./scripts/static-scan.sh --no-exclude build/classes
```

Projenizin kendi filtresini kullanmak için:

```bash
SPOTBUGS_EXCLUDE=quality/my-exclude.xml ./scripts/static-scan.sh build/classes
```

Bunu CI'da çalıştıracaksanız
[filtre söz dizimi](https://spotbugs.readthedocs.io/en/latest/filter.html)
on dakikanıza değer.

## Yeni paket ekleme

Jar'ı bu klasöre bırakın. `static-scan.sh` buradaki her `.jar`'ı alıyor,
`00-setup.sh --verify` de sayıyor.

Tek kural: **SpotBugs aynı plugin id'sine sahip iki eklentiyi yüklemeyi
reddediyor.** Id'ler yukarıdaki tabloda. sb-contrib'in ikinci bir kopyasını
farklı bir dosya adıyla koymak işe yaramıyor — SpotBugs id'yi jar'ın içinden
okuyor ve birini seçmek yerine hata veriyor.

## Build içinde kullanım

IDE eklentisi ve `static-scan.sh` çalışırken döndüğünüz döngü için. Asıl
otorite **build** olmalı ve aynı iki jar'ı kullanmalı. SpotBugs bunları
`static-scan.sh` ile aynı şekilde alıyor:

```bash
spotbugs -textui -effort:max -low \
    -pluginList spotbugs-rule-packs/sb-contrib-7.6.9.jar:spotbugs-rule-packs/findsecbugs-plugin-1.14.0.jar \
    -exclude spotbugs-rule-packs/spotbugs-exclude.xml \
    -auxclasspath "$(cat compile.classpath)" \
    -xml:withMessages -output build/reports/spotbugs.xml \
    build/classes
```

Maven kullanıyorsanız `spotbugs-maven-plugin`'i indirmesi gereken
koordinatlara değil, diskteki jar'lara yönlendirin:

```xml
<plugin>
    <groupId>com.github.spotbugs</groupId>
    <artifactId>spotbugs-maven-plugin</artifactId>
    <configuration>
        <effort>Max</effort>
        <threshold>Low</threshold>
        <failOnError>true</failOnError>
        <excludeFilterFile>spotbugs-rule-packs/spotbugs-exclude.xml</excludeFilterFile>
        <pluginList>
            spotbugs-rule-packs/sb-contrib-7.6.9.jar,spotbugs-rule-packs/findsecbugs-plugin-1.14.0.jar
        </pluginList>
    </configuration>
</plugin>
```

Bastırmalar (`@SuppressFBWarnings`) yazılı bir gerekçe taşımalı ve kod
incelemede sorgulanmalı — gerekçesiz bir bastırma, gerçek bir bulgunun
gömülme yoludur.

## Lisanslar

`sb-contrib` LGPL 2.1 (jar'ın içindeki `license.txt`). `findsecbugs` LGPL 3.0.
İkisi de kendi şartlarını koruyor; hiçbiri bu deponun
[`LICENSE`](../LICENSE) dosyası kapsamında değil.

## Bu bulgular ne değil

Bunlar **aday**. Statik çözümleyici, 12 girişlik bir önbellekteki
`PMB_POSSIBLE_MEMORY_BLOAT`'ın önemsiz olduğunu ya da bulduğu boxing'in günde
iki kez çalışan bir yolda olduğunu size söyleyemez. Bir şeyi değiştirmeden önce
[`diagnose.sh`](../scripts/diagnose.sh) ile doğrulayın — bu deponun bütün
amacı, önce ölçmeniz.
