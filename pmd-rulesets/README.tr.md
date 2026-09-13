# `pmd-rulesets/` — paylaşılan PMD ruleset'i

**[English](README.md) · [Türkçe](README.tr.md)**

`pmd-performance.xml` iki yerde kullanılan tek bir ruleset:

- **Komut satırı** — [`scripts/static-scan.sh`](../scripts/static-scan.sh)
  dosyayı PMD'ye `-R` ile veriyor. Yapılandırma gerekmiyor.
- **IntelliJ IDEA** — `Settings → Tools → PMD`, dosyayı özel ruleset'ler
  altına ekleyin. Sağ tık → `Run PMD → Custom → java-profiling-tools`.

İki yerde tek dosya olması, IDE ile build'in aynı şeyleri raporlaması demek.
Bu kulağa geldiğinden önemli: alışıldık başarısızlık biçimi, geliştiricinin
IDE'si sessizken CI'ın kırmızı yanması — ya da tam tersi.

## Neden sürümden bağımsız

IDEA PMD eklentisi **PMD 7.21.0** içeriyor; bu depo
[`compile-time/`](../compile-time/) altında **PMD 7.27.0** getiriyor. Ruleset,
motor sürümü fark etmeyecek şekilde yazıldı:

| | PMD 7.21.0 (IDE) | PMD 7.27.0 (CLI) |
|---|---|---|
| Yüklenen kural | 68 | 69 |
| Yapılandırma hatası | 0 | 0 |
| Aynı girdide bulgu | 3 | 3 |

Bunu iki şey sağlıyor. Tek tek kurallar yerine **bütün kategorilere** referans
veriyor; böylece sonraki bir PMD'de eklenen kuralı burada adlandırmak
gerekmiyor, eski bir sürümde olmayan kural da yüklemeyi bozamıyor. Ve
*dışladığı* her kural iki sürümde de var, yani hiçbir exclude boşa düşmüyor.

Bu paketin asıl konusu olan `performance` kategorisi **ikisinde de birebir
aynı**: aynı 25 kural.

Tek kuralllık fark `OverridingThreadRun`; 7.21'den sonra `multithreading`
kategorisine eklenmiş.

## İçeriği

| Kategori | Kural | Neden |
|---|---|---|
| `performance` | 25'inin hepsi | Dosyanın asıl sebebi. Gerçek profillerde çıkanlar: `InefficientStringBuffering`, `ConsecutiveLiteralAppends`, `AvoidInstantiatingObjectsInLoops`, `InsufficientStringBufferDeclaration`, `UseArraysAsList`. |
| `multithreading` | hepsi | Thread hataları kilit çekişmesi olarak yüzeye çıkıyor; `diagnose.sh --full` de tam bunu ölçüyor. |
| `design` | 9 eksiğiyle | Ağırlıklı karmaşıklık metrikleri — profil sıcak sınıfı söyledikten sonra "nereden refactor'a başlayayım?" sorusunun sayısal cevabı. |

`design` içinden çıkarılanlar ve nedenleri:

| Çıkarılan | Sebep |
|---|---|
| `LawOfDemeter` | Sıradan Java'nın neredeyse her satırında tetikleniyor. |
| `LoosePackageCoupling` | Projeye özel yapılandırma olmadan hiçbir anlam ifade etmiyor. |
| `ExcessiveImports`, `TooManyMethods`, `TooManyFields`, `ExcessivePublicCount` | Sayı saymak tek başına az şey söylüyor; bu dördü filtresiz bir design raporunun çoğunu üretiyor. |
| `DataClass` | Her DTO ve value object'i işaretliyor. |
| `SignatureDeclareThrowsException`, `AvoidCatchingGenericException` | Performans değil, biçem tartışması. |

## Değiştirmek

```bash
PMD_RULESET=quality/my-pmd.xml ./scripts/static-scan.sh build/classes src/main/java
PMD_RULESET= ./scripts/static-scan.sh build/classes    # PMD'nin kendi kategorileri
```

Dosyayı düzenlerseniz tek tek kurallar yerine kategorilere referans vermeyi
sürdürün — PMD sürümleri arasında çalışmasını sağlayan şey bu.
[Ruleset söz dizimi](https://docs.pmd-code.org/latest/pmd_userdocs_making_rulesets.html)
gerisini anlatıyor.

## CPD

`static-scan.sh` ayrıca PMD'nin kopyala-yapıştır dedektörü CPD'yi 100 token ile
çalıştırıyor. Ruleset almıyor, dolayısıyla burada yapılandırılacak bir şey yok.
Tekrarlanan bloklar iyi bir refactor hedefi, ama tek başına bir performans
sorunu değil.

## Lisans

PMD Apache 2.0 (bazı bileşenleri BSD tarzı); lisansı
[`compile-time/`](../compile-time/) içindeki dağıtımın içinde geliyor. Bu
ruleset deponun parçası ve [`LICENSE`](../LICENSE) kapsamında.

## Bu bulgular ne

**Aday.** PMD kaynağa bakıyor ve neyin sık çalıştığını bilmiyor — başlangıç
kodundaki bir `String` birleştirmesini sıcak döngüdekiyle aynı sesle
işaretliyor. Bir şeyi değiştirmeden önce
[`diagnose.sh`](../scripts/diagnose.sh) ile doğrulayın.
