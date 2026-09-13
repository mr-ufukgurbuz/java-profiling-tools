# `docs/` — the screenshots, and how they were made

**[English](README.md) · [Türkçe](README.tr.md)**

Every **screenshot** in [`images/`](images/) comes from a **real run**. None of
them was edited, composited or retouched. They are here to show that what the
main README describes actually works.

The two `.svg` files are the exception, and they are not screenshots: they are
**drawn diagrams** of how the IntelliJ plugins and the command line relate.
They are labelled as such in the table below. Nothing in this directory is a
mock-up of a program that was not run.

## The application being measured

`com.acme.OrderService` in the screenshots is a deliberately slow example
service. Each method contains one textbook anti-pattern:

| What it does | The anti-pattern |
|---|---|
| `buildReport()` — 400-step loop doing `line = line + …` | string concatenation in a loop |
| the same loop calling `Pattern.compile("[0-9]+")` every iteration | recompiling a regex on every call |
| `timestamp()` — `new SimpleDateFormat(…)` per call | an expensive, non-thread-safe formatter |
| `priceIndex()` — 2,000 entries into `new HashMap<>()` with `Integer.valueOf` | un-presized collection + boxing |
| `updateStock()` — 4 threads, a `synchronized` block wrapping a `sleep` | lock contention |
| `fillCache()` — a 128 KB `byte[]` every 200 ms | a slowly growing cache that looks like a leak |
| a 40-thread pool that never does anything | an oversized thread pool |

JVM: `-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxMetaspaceSize=256m`.

Every number in the reports (33.7% of CPU samples in `Pattern.compile`,
243,252 ms of lock waiting, ~609 MB/s of allocation…) is a real measurement of
that application.

Images 8 and 12 additionally show the **fixed** version: the regex hoisted to a
`static final`, the formatter made a `ThreadLocal`, the map pre-sized, and the
`sleep` moved out of the `synchronized` block.

## The images

| File | What it shows | How it was captured |
|---|---|---|
| `01-setup-verification.png` | `00-setup.sh --verify` verification table | terminal |
| `02-diagnose-identity-os-memory.png` | `diagnose.sh` sections 1–3 | terminal |
| `03-diagnose-gc-threads-jit.png` | sections 4–7 (GC, threads, per-thread CPU, JIT) | terminal |
| `04-diagnose-cpu-hotspots.png` | section 9 — CPU hot paths with causes and fixes | terminal |
| `05-diagnose-memory-hotspots.png` | section 9 — the code producing the garbage | terminal |
| `06-diagnose-locks-safepoints.png` | section 9 — locks and safepoints | terminal |
| `07-diagnose-findings.png` | the ranked findings and the result line | terminal |
| `08-diagnose-compare.png` | `--compare` — the same service after the fixes | terminal |
| `09-cpu-flame-graph.png` | async-profiler CPU flame graph (`cpu.html`) | browser |
| `10-jmc-automated-analysis.png` | JMC with `recording.jfr` open, Automated Analysis Results | Xvfb |
| `11-visualvm-plugins.png` | VisualVM: plugin tabs + Visual GC drawing live data | Xvfb |
| `12-jmh-before-after.png` | `jmh-run.sh` — string concat vs a pre-sized `StringBuilder` | terminal |
| `13-ide-vs-cli.svg` | Which rules the IDE and `static-scan.sh` each run | **drawn diagram** |
| `14-ide-setup-steps.svg` | The two settings steps that align the IDE with the build | **drawn diagram** |

## How they were produced

- **Terminal images** — the command was run inside `script -q -c "…" /dev/null`
  so the ANSI colours were captured, converted to a terminal-styled HTML page,
  and screenshotted with headless Chromium at 2× scale. The image is then
  cropped by reading the pixels back, rather than trusting the browser's idea of
  window height.
- **GUI images** — JMC and VisualVM were opened on a headless X server (`Xvfb`),
  and the framebuffer was read directly and converted to PNG. In VisualVM, the
  application node and the *Visual GC* tab were clicked with `java.awt.Robot`.

The generator itself is not kept in this directory: it is a one-off
documentation tool, not part of how the toolkit works.

- **Diagrams** — hand-written SVG, no drawing tool and no imported artwork. They
  carry their own light background so they read the same in GitHub's light and
  dark themes, and the version numbers in them are the ones this repository
  actually ships.

## Why these two in particular

Images **10** and **11** matter most, because they are the two concrete problems
this repository was built to solve:

- **10** — JMC would not open at all on a system whose JDK is 11. Here it is
  running, with a recording parsed and its rule engine finished.
- **11** — VisualVM ships with no plugins. Here `MBeans`, `Buffer Pools`,
  `JConsole Plugins`, `Visual GC` and `Tracer` are all in the tab row on first
  launch, and Visual GC is drawing live data.
