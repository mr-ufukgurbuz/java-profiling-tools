# `docs/` — ekran görüntüleri ve nasıl üretildiler

**[English](README.md) · [Türkçe](README.tr.md)**

[`images/`](images/) klasöründeki **ekran görüntülerinin** hepsi **gerçek
çalıştırmalardan** alındı. Hiçbiri elle düzenlenmedi, montajlanmadı veya
yeniden yazılmadı. Ana README'de anlatılan her şeyin gerçekten çalıştığını
göstermek için buradalar.

İki `.svg` dosyası istisna ve bunlar ekran görüntüsü değil: IntelliJ
eklentileriyle komut satırının ilişkisini anlatan **çizilmiş diyagramlar**.
Aşağıdaki tabloda öyle işaretliler. Bu klasörde çalıştırılmamış bir programın
taklidi hiçbir şey yok.

## Ölçülen uygulama

Görsellerdeki `com.acme.OrderService`, bilerek yavaş yazılmış bir örnek servis.
Her metodu bir ders kitabı anti-pattern'i içeriyor:

| Ne yapıyor | Hangi anti-pattern |
|---|---|
| `buildReport()` — 400 adımlık döngüde `line = line + …` | döngüde string concat |
| aynı döngüde her turda `Pattern.compile("[0-9]+")` | regex'i her çağrıda derlemek |
| `timestamp()` — her çağrıda `new SimpleDateFormat(…)` | pahalı ve thread-safe olmayan formatter |
| `priceIndex()` — 2.000 giriş, `new HashMap<>()` + `Integer.valueOf` | ön-boyutlandırılmamış koleksiyon + boxing |
| `updateStock()` — 4 thread, `sleep`'i de saran `synchronized` blok | lock contention |
| `fillCache()` — 200 ms'de bir 128 KB `byte[]` | yavaş büyüyen, sızıntıya benzeyen önbellek |
| hiçbir şey yapmayan 40 thread'lik havuz | gereğinden büyük thread havuzu |

JVM: `-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxMetaspaceSize=256m`.

Raporlardaki bütün sayılar (CPU örneklerinin %33,7'si `Pattern.compile` içinde,
243.252 ms kilit beklemesi, ~609 MB/s allocation…) bu uygulamanın gerçek
ölçümleri.

8 ve 12 numaralı görseller ayrıca **düzeltilmiş** sürümü gösteriyor: regex
`static final` yapıldı, formatter `ThreadLocal`'a taşındı, map ön-boyutlandırıldı
ve `sleep` `synchronized` bloğun dışına çıkarıldı.

## Görseller

| Dosya | Ne gösteriyor | Nasıl alındı |
|---|---|---|
| `01-setup-verification.png` | `00-setup.sh --verify` doğrulama tablosu | terminal |
| `02-diagnose-identity-os-memory.png` | `diagnose.sh` 1–3. bölüm | terminal |
| `03-diagnose-gc-threads-jit.png` | 4–7. bölüm (GC, thread, thread-CPU, JIT) | terminal |
| `04-diagnose-cpu-hotspots.png` | 9. bölüm — CPU sıcak noktaları, sebep ve çözümüyle | terminal |
| `05-diagnose-memory-hotspots.png` | 9. bölüm — çöpü üreten kod | terminal |
| `06-diagnose-locks-safepoints.png` | 9. bölüm — kilit ve safepoint | terminal |
| `07-diagnose-findings.png` | sıralanmış bulgular ve sonuç satırı | terminal |
| `08-diagnose-compare.png` | `--compare` — aynı servis, düzeltmelerden sonra | terminal |
| `09-cpu-flame-graph.png` | async-profiler CPU flame graph (`cpu.html`) | tarayıcı |
| `10-jmc-automated-analysis.png` | JMC, `recording.jfr` açık, Automated Analysis Results | Xvfb |
| `11-visualvm-plugins.png` | VisualVM: eklenti sekmeleri + Visual GC canlı veri çiziyor | Xvfb |
| `12-jmh-before-after.png` | `jmh-run.sh` — string concat vs ön-boyutlu `StringBuilder` | terminal |
| `13-ide-vs-cli.svg` | IDE ve `static-scan.sh` hangi kuralları çalıştırıyor | **çizim** |
| `14-ide-setup-steps.svg` | IDE'yi build ile hizalayan iki ayar adımı | **çizim** |

## Üretim yöntemi

- **Terminal görselleri** — komut `script -q -c "…" /dev/null` içinde
  çalıştırılıp ANSI renkleriyle yakalandı, terminal görünümlü bir HTML'e
  çevrildi ve headless Chromium ile 2× çözünürlükte ekran görüntüsü alındı.
  Görüntü sonrasında piksel piksel okunarak kırpıldı; tarayıcının pencere
  yüksekliği hesabına güvenilmedi.
- **GUI görselleri** — JMC ve VisualVM başsız bir X sunucusunda (`Xvfb`) açıldı,
  framebuffer doğrudan okunup PNG'ye çevrildi. VisualVM'de uygulama düğümüne ve
  *Visual GC* sekmesine `java.awt.Robot` ile tıklandı.

Üretim script'i bu klasörde tutulmuyor: tek seferlik bir dokümantasyon aracı,
paketin kendi işleyişinin parçası değil.

- **Diyagramlar** — elle yazılmış SVG; çizim programı da kullanılmadı, dışarıdan
  görsel de alınmadı. Kendi açık zeminlerini taşıyorlar, böylece GitHub'ın açık
  ve koyu temasında aynı okunuyorlar; içlerindeki sürüm numaraları da bu deponun
  gerçekten getirdiği sürümler.

## Neden özellikle bu ikisi

**10** ve **11** numaralı görseller en önemlileri, çünkü bu deponun çözmek için
var olduğu iki somut sorun tam olarak bunlar:

- **10** — Sistemdeki JDK 11 yüzünden JMC hiç açılmıyordu. Burada çalışıyor,
  kaydı okumuş ve kural motorunu tamamlamış durumda.
- **11** — VisualVM eklentisiz geliyor. Burada `MBeans`, `Buffer Pools`,
  `JConsole Plugins`, `Visual GC` ve `Tracer` ilk açılışta sekme sırasında
  duruyor, Visual GC de canlı veri çiziyor.
