# Java Profiling Tools — an offline toolkit

**[English](README.md) · [Türkçe](README.tr.md)**

Everything you need to find out why a Java application is slow, on a machine
with **no internet access**. Every tool is in this repository; nothing is
downloaded, nothing is installed system-wide, and nothing outside `$HOME` is
written.

The centrepiece is one command:

```bash
./scripts/diagnose.sh <pid>
```

It attaches to a running JVM, collects everything worth collecting, and prints
a report that names the **actual class and method** that is costing you, why it
is costing you, and what to do about it.

![diagnose.sh findings](docs/images/07-diagnose-findings.png)

> Every number and every screenshot in this README comes from a real run
> against a real JVM. Nothing is mocked up. See [`docs/`](docs/) for how the
> images were produced.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Requirements](#requirements)
- [Setup (5 minutes)](#setup-5-minutes)
- [The 60-second workflow](#the-60-second-workflow)
- [What `diagnose.sh` gives you](#what-diagnosesh-gives-you)
- [Did the fix work? `--compare`](#did-the-fix-work---compare)
- [Proving it with JMH](#proving-it-with-jmh)
- [The GUI tools](#the-gui-tools)
  - [Why JMC would not open, and how that is fixed](#why-jmc-would-not-open-and-how-that-is-fixed)
  - [VisualVM, with its plugins already installed](#visualvm-with-its-plugins-already-installed)
- [Script reference](#script-reference)
- [Tool reference](#tool-reference)
- [Reading the output](#reading-the-output)
- [Split archives](#split-archives)
- [Writing policy: `$HOME` only](#writing-policy-home-only)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)
- [Verifying the downloads](#verifying-the-downloads)
- [Licence](#licence)

---

## Why this exists

On an air-gapped or tightly firewalled machine, the normal answer to "the app is
slow" — install a profiler, open a browser, download a plugin — is not
available. This repository packages the whole chain so it works offline:

| Problem on an offline box | What this repository does about it |
|---|---|
| No profiler installed, nothing to `dnf install` | async-profiler, JFR, JMC, VisualVM, MAT are all bundled |
| JMC refuses to start on a JDK 11 system | A wrapper passes the bundled JDK 21 to Eclipse explicitly |
| VisualVM ships without Visual GC, MBeans, Tracer… | 21 plugin modules are bundled and installed offline |
| GitHub will not take a 200 MB file | Large archives are split, and a joiner is included |
| You need root to write to `/opt` | Everything unpacks into `tools/`, output goes to `$HOME` |
| A flame graph needs a browser you may not have | `diagnose.sh` prints the same conclusions as text |

---

## Requirements

- Linux x86-64 (developed and tested on RHEL 9; nothing is RHEL-specific)
- `bash`, `tar`, and one of `unzip` / `python3` / `jar` / `bsdtar`
- A JDK on the machine for the application you are measuring — **any version
  from 8 up**. The bundled JDK 21 is only used to *run* the tools.
- **No root.** Not for setup, not for profiling.
- To attach to a JVM you must be **the same user that runs it** (or root).

---

## Setup (5 minutes)

```bash
git clone <this-repo> ~/java-profiling-tools
cd ~/java-profiling-tools
./scripts/00-setup.sh
```

That single script unpacks every archive into `tools/`, joins the split ones,
points JMC and MAT at the bundled JDK 21, raises MAT's heap to half of machine
RAM, installs the 21 VisualVM plugins, and finishes with a verification table:

![00-setup.sh --verify](docs/images/01-setup-verification.png)

Re-run the check at any time with `./scripts/00-setup.sh --verify`.

Then, once per shell:

```bash
source scripts/env.sh
```

This exports `PROFILING_HOME`, `TOOLS` and `PERF_OUT`, puts `asprof`, `pmd` and
`spotbugs` on `PATH`, and defines the `diagnose`, `jmc`, `visualvm` and `mat`
aliases.

---

## The 60-second workflow

```bash
# 1. Which JVMs are running?
./scripts/diagnose.sh --list

# 2. Diagnose one, matching hot spots against YOUR package
./scripts/diagnose.sh 12345 --package com.acme

# 3. Fix the top finding, then prove it helped
./scripts/diagnose.sh 12345 --compare ~/perf-out/diag-12345-20260913-113803
```

That is the whole loop: **measure → fix one thing → measure again**. If the
number did not move, revert the change.

---

## What `diagnose.sh` gives you

One command produces eleven sections. Here is what a real run looks like
against a deliberately slow order service.

### Sections 1–3 — identity, operating system, memory

Who the process is, which JVM and GC, every startup flag, RSS vs the heap
ceiling, thread and file-descriptor counts, container (cgroup) limits and
throttling, and the heap breakdown.

![diagnose.sh sections 1-3](docs/images/02-diagnose-identity-os-memory.png)

### Sections 4–7 — GC, threads, per-thread CPU, JIT

GC load as a share of wall-clock time, allocation and promotion rates, the
thread-state distribution, which threads are stuck in the same method across
three dumps, the top CPU-consuming threads **with the method each one is in**,
and code-cache and class-loading numbers.

![diagnose.sh sections 4-7](docs/images/03-diagnose-gc-threads-jit.png)

### Section 9 — hot code paths, with causes and fixes

This is the part that makes the report worth reading. For each hot frame it
prints the frame, the first method in *your* package underneath it, a likely
cause drawn from a dictionary of ~50 Java anti-patterns, and a concrete fix.

![CPU hot paths](docs/images/04-diagnose-cpu-hotspots.png)

The same treatment for allocation — which type the garbage is, who allocates
it, and what to do:

![Memory hot paths](docs/images/05-diagnose-memory-hotspots.png)

And for locks and safepoints — sorted by **time lost**, not by event count:

![Locks and safepoints](docs/images/06-diagnose-locks-safepoints.png)

### Findings

Everything above is then boiled down to a ranked list. Each finding says what
is wrong, why it matters, and exactly what to change:

![Findings](docs/images/07-diagnose-findings.png)

The exit code is usable from cron or CI: `0` clean, `1` warnings, `2` critical,
`3` could not run. Add `--json` to also write a machine-readable `summary.json`.

### Flame graph

If async-profiler is available (it is, after setup) you also get real flame
graphs. Read the **width**, not the height:

![CPU flame graph](docs/images/09-cpu-flame-graph.png)

`java/util/regex/Pattern.compile` under `com/acme/OrderService.buildReport` is
the widest block — the regex is being recompiled on every iteration.

### Options

| Option | What it does |
|---|---|
| `--quick` | No profiling; instant metrics only (~20 s) |
| `--full` | Also take wall-clock and lock profiles (where threads **wait**) |
| `--duration N` | Profiling window in seconds (default 60) |
| `--deep` | Also take a heap dump and run MAT headless (heavy, STW pause) |
| `--package com.acme` | Match hot spots against your code |
| `--output DIR` | Output directory (default `$PERF_OUT/diag-<pid>-<time>`) |
| `--threshold strict\|normal\|loose` | How eager the findings are (default `normal`) |
| `--compare DIR` | Compare against an earlier run |
| `--json` | Also write `summary.json` |
| `--no-color` | Do not emit ANSI colour codes |
| `--list` | List the running Java processes and exit |

---

## Did the fix work? `--compare`

Measure, fix, measure again. `--compare` takes the output directory of the
earlier run and prints the deltas, colouring each one by whether it moved in
the right direction.

Here is the same service after four fixes the profile pointed at — hoisting the
regex, reusing the date formatter, pre-sizing the map, and narrowing the
synchronized block:

![diagnose.sh --compare](docs/images/08-diagnose-compare.png)

Allocation is down 34%, promotion into old gen down 33%, old-gen occupancy down
86%, and BLOCKED threads are gone entirely. CPU went **up** 137% — which is the
right outcome: with the lock contention removed, the same threads now spend
their time doing work instead of waiting for each other.

> **Rule:** if a change did not move the number you were trying to move, revert
> it. An unmeasured "improvement" is just technical debt.

---

## Proving it with JMH

A profile tells you where the time goes. A **benchmark** tells you whether your
fix actually made it faster. JMH is bundled and runs without Maven:

```bash
./jmh/jmh-run.sh jmh/example/SpeedBenchmark.java
```

The example benchmark compares string concatenation in a loop against a
pre-sized `StringBuilder` — the single most common Java performance bug:

![JMH before/after](docs/images/12-jmh-before-after.png)

140,549 µs/op versus 125 µs/op, and 590 MB allocated per operation versus
239 KB. That is **1,120× faster** with **2,470× less garbage**, from one change.

`-prof gc` is on by default, because `gc.alloc.rate.norm` (bytes allocated per
operation) usually tells you more than the timing does.

To benchmark your own code, point the script at your classes:

```bash
./jmh/jmh-run.sh MyBenchmark.java $HOME/myapp/lib/app.jar -f 1 -wi 5 -i 10
```

> The benchmark class **must declare a package** — JMH rejects the default
> package. And always consume your result with a `Blackhole`, or the JIT will
> delete the loop you are trying to measure.

---

## The GUI tools

### Why JMC would not open, and how that is fixed

JDK Mission Control is an Eclipse RCP application and needs **Java 17+**. On a
machine whose system JDK is 11, running the launcher directly fails with:

```
Version 11.0.x of the JVM is not suitable for this product.
Version: 17 or greater is required.
```

The Eclipse launcher decides which JVM to use from the `-vm` line in `jmc.ini`.
Without one it falls back to whatever `java` is on `PATH` — JDK 11. Two things
fix it, and this repository does both:

1. `00-setup.sh` writes a `-vm` block into `jmc.ini` (and `MemoryAnalyzer.ini`)
   pointing at the bundled JDK 21. The block **must** sit above `-vmargs`, and
   the path must be on its own line, or Eclipse ignores it.
2. `scripts/jmc-open.sh` passes `-vm <bundled-java>` on the **command line**,
   which overrides the ini file. That keeps working even if the package is
   moved somewhere else, or the ini is overwritten by an update.

Either way, only *JMC itself* runs on JDK 21. The application you are analysing
stays on its own JDK, and JMC reads JDK 8/11/17 recordings without trouble.

```bash
./scripts/jmc-open.sh                                   # just open JMC
./scripts/jmc-open.sh ~/perf-out/diag-*/recording.jfr   # open with a recording
./scripts/jmc-open.sh --where                           # print the choices, open nothing
```

Here it is, running on JDK 21 with a recording loaded and its rule engine
finished — the Automated Analysis Results are JMC's own verdict on the same JVM
`diagnose.sh` measured:

![JMC automated analysis](docs/images/10-jmc-automated-analysis.png)

### VisualVM, with its plugins already installed

VisualVM does **not** ship Visual GC, MBeans, Buffer Monitor, Threads
Inspector, Startup Profiler, Tracer or BTrace. Each is a separate plugin,
normally fetched through *Tools → Plugins* — which needs internet.

So all 21 `.nbm` modules live in [`plugins/visualvm/`](plugins/visualvm/).
`00-setup.sh` unpacks the `netbeans/` tree inside each one into a **cluster**
directory, and `visualvm-open.sh` hands that cluster to VisualVM through
`visualvm_extraclusters`. The plugins are therefore enabled **on first launch**
— no wizard, no restart, no internet.

```bash
./scripts/visualvm-open.sh                       # open VisualVM
./scripts/visualvm-open.sh ~/perf-out/heap.hprof # open with a heap dump loaded
./scripts/visualvm-open.sh --jdk21               # run it on the bundled JDK 21
./scripts/visualvm-open.sh --clean               # reset the userdir
```

![VisualVM with plugins](docs/images/11-visualvm-plugins.png)

`MBeans`, `Buffer Pools`, `JConsole Plugins`, `Visual GC` and `Tracer` are all
in the tab row, and Visual GC is drawing live eden/survivor/old data.

> One of those 21 modules exists purely to make the others load:
> `org-openjdk-btrace-visualvm-tracer-deployer`. The Tracer probe modules
> declare a `OpenIDE-Module-Requires` dependency on the BTrace deployer
> capability, and without it VisualVM stalls at startup with *"could not install
> some modules"*.

Unlike JMC, VisualVM runs on the **system** JDK by default, deliberately: its
Sampler and Profiler load an agent into the target JVM, and matching the
application's Java version is the safest choice. Use `--jdk21` to override.

| Plugin | Where it shows up | Use it for |
|---|---|---|
| Visual GC | *Visual GC* tab | Watching eden/survivor/old live; tenuring distribution |
| Buffer Monitor | *Buffer Pools* tab | **Look here first when RSS ≫ heap** — direct and mapped `ByteBuffer` |
| MBeans | *MBeans* tab | Reading and changing settings over JMX |
| Threads Inspector | *Threads* tab | Current stack of the selected thread |
| Tracer | *Tracer* tab | JVM / IO / collection probes as time series |
| BTrace | Right-click → *Trace application…* | Dynamic tracing of a live JVM |
| Startup Profiler | *Applications* → right-click | Measuring startup cost |
| OQL syntax | Heap dump → *OQL Console* | Highlighting and completion when querying a dump |
| JConsole Plugins | *JConsole Plugins* tab | Reusing existing JConsole plugins |

### MAT (Memory Analyzer)

MAT is pinned to JDK 21 the same way JMC is, and its `-Xmx` is raised at setup
to half of machine RAM (min 2 GB, max 8 GB) — the shipped 1 GB is not enough to
open even a small dump.

```bash
mat &                                         # the GUI (needs a display)
./scripts/heap-summary.sh <pid> --dump        # or headless: dump + Leak Suspects
```

**Rule of thumb:** MAT's `-Xmx` should be at least half the dump size. Opening
an 8 GB dump? Raise the line in `tools/mat/MemoryAnalyzer.ini` by hand.

### No display?

You do not need one. `diagnose.sh` and `jfr-summary.sh` print the same
conclusions as text, and `heap-summary.sh` runs MAT headless. If you do want
the GUI, either `ssh -X`, or copy the `.jfr` / `.hprof` to your workstation.

---

## Script reference

Every script is self-documenting: run it with `-h` for the same text.

### `scripts/00-setup.sh` — unpack the toolkit

Unpacks every archive into `tools/`, joins split archives, pins JMC/MAT to the
bundled JDK 21, raises MAT's heap, installs the VisualVM plugins, verifies.

| Option | Meaning |
|---|---|
| *(none)* | Unpack what is missing, configure the GUI tools |
| `--reset` | Delete `tools/` and unpack from scratch |
| `--no-plugins` | Do not install the VisualVM plugins |
| `--verify` | Unpack nothing; only check the current install |

Safe to re-run: anything already unpacked is skipped.

### `scripts/env.sh` — environment and shortcuts

`source` it. Exports `PROFILING_HOME`, `TOOLS`, `PERF_OUT`, `ASPROF`, `JFRCLI`,
`JAVA21`, `JOL`, `GCVIEWER`, `JFRCONV`; adds `pmd`, `spotbugs` and `asprof` to
`PATH`; defines the aliases `diagnose`, `jmc`, `mat`, `visualvm`.

### `scripts/diagnose.sh` — full diagnosis in one command

The main event. See [What `diagnose.sh` gives you](#what-diagnosesh-gives-you)
for the option table.

```bash
./scripts/diagnose.sh --list                          # which JVMs are running
./scripts/diagnose.sh 12345                           # full diagnosis, ~90 s
./scripts/diagnose.sh 12345 --quick                   # metrics only, ~20 s
./scripts/diagnose.sh myapp --full --package com.acme # by name, + wait/lock analysis
./scripts/diagnose.sh 12345 --deep                    # + heap dump + MAT headless
```

It accepts a **pid or a process name**. Name matching verifies every candidate
really is a JVM, so it will not pick up your own shell or a `tail | grep`.

Interrupting it with Ctrl-C is safe: the JFR recording it started on the target
is stopped and async-profiler is detached before it exits.

### `scripts/jmc-open.sh` — JMC with the right JDK

| Option | Meaning |
|---|---|
| `<file.jfr>` | Open with that recording loaded |
| `--jdk PATH` | Use a specific JDK instead of the bundled one |
| `--memory 4g` | JMC's own heap (large recordings need more) |
| `--clean` | Reset the JMC workspace |
| `--foreground` | Do not detach from the terminal |
| `--where` | Print which JDK/workspace would be used, open nothing |

### `scripts/visualvm-open.sh` — VisualVM with its plugins

| Option | Meaning |
|---|---|
| `<file.hprof\|file.jfr>` | Open with that dump or recording loaded |
| `--jdk21` | Run VisualVM on the bundled JDK 21 |
| `--jdk PATH` | Run it on a specific JDK |
| `--clean` | Reset the userdir (when settings break) |
| `--no-plugins` | Open without wiring in the plugin cluster |
| `--accept-license` | Pre-accept the first-run licence prompt |
| `--foreground` | Do not detach from the terminal |
| `--where` | Print the choices, open nothing |

### `scripts/heap-summary.sh` — memory analysis without a GUI

```bash
./scripts/heap-summary.sh <pid>           # RSS vs heap, thread count, class histogram
./scripts/heap-summary.sh <pid> --dump    # + heap dump + MAT headless Leak Suspects
./scripts/heap-summary.sh dump.hprof      # analyse an existing dump headless
```

Starts by making the distinction that matters: **is the problem even in the
heap?** If RSS ≫ heap, lowering `-Xmx` will not help and it tells you what to
check instead.

### `scripts/jfr-record.sh` — a JFR recording from a running process

```bash
./scripts/jfr-record.sh <pid>                  # 180 s at settings=profile
./scripts/jfr-record.sh <pid> --duration 600
```

### `scripts/jfr-summary.sh` — decode a recording in the terminal

```bash
./scripts/jfr-summary.sh recording.jfr [rows]
```

Event counts, the hottest methods by self time, the most-allocated types, the
code that allocates them, the longest GC pauses with their causes, and the most
contended monitors. No GUI needed.

### `scripts/cpu-profile.sh` / `scripts/memory-profile.sh` — flame graphs

```bash
./scripts/cpu-profile.sh <pid> 60
./scripts/memory-profile.sh <pid> --duration 60 --heap-dump
```

Both accept the duration positionally or as `--duration N`, and reject anything
that is not a number rather than silently profiling for zero seconds.
`cpu-profile.sh` falls back from `cpu` to `ctimer` automatically when
`perf_event_paranoid > 1`, so it needs no privileges.

### `scripts/static-scan.sh` — analysis without running the code

```bash
./scripts/static-scan.sh build/classes src/main/java
```

SpotBugs over the bytecode (PERFORMANCE, CORRECTNESS, MT_CORRECTNESS), PMD over
the source (performance + design), plus copy-paste detection. Drop extra rule
packs (`sb-contrib`, `findsecbugs`) into `spotbugs-rule-packs/` and they are
picked up automatically.

These find **candidates**, not proof. Confirm with a profile before changing
anything.

### `scripts/zip-join.py` — split-archive joiner

```bash
python3 scripts/zip-join.py big.zip joined.zip
```

Called automatically by `00-setup.sh`. See [Split archives](#split-archives).

### `scripts/common.sh` — shared helpers

Sourced by the other scripts, not run directly: finding a JDK of at least a
given version, reading a Java version, resolving a pid or process name to a real
JVM, validating durations, consistent messages.

### `jmh/jmh-run.sh` — JMH without Maven

```bash
./jmh/jmh-run.sh <Benchmark.java> [extra-classpath] [jmh-args...]
```

Compiles with the JMH annotation processor and runs it, `-prof gc` on, JSON
result written to `$PERF_OUT/jmh/result-<timestamp>.json`.

---

## Tool reference

| Tool | Version | What it is for |
|---|---|---|
| **JDK 21** (Temurin) | 21.0.12.1 | Runs JMC and MAT; provides the `jfr` CLI. Not for your app. |
| **async-profiler** | 4.5 | Low-overhead CPU / alloc / lock / wall profiling, no safepoint bias |
| **JFR** | in the JDK | Always-on flight recorder, ~2% overhead |
| **JMC** | 9.1.2 | GUI for JFR recordings, with an automated rule engine |
| **VisualVM** | 2.2.1 | Live monitoring, sampling, heap dumps (+21 plugins) |
| **MAT** | 1.17.0 | Heap-dump analysis, Leak Suspects, dominator tree |
| **jfr-converter** | bundled | Turns a JFR recording into a flame graph without async-profiler |
| **GCViewer** | 1.37 | Visualises GC logs |
| **SpotBugs** | 4.10.4 | Bytecode analysis (performance + correctness) |
| **PMD / CPD** | 7.27.0 | Source analysis and copy-paste detection |
| **JaCoCo** | 0.8.15 | Coverage — to know which code is actually exercised |
| **JMH** | 1.37 | Microbenchmarks that survive JIT trickery |
| **JOL** | 0.17 | Object memory layout, byte by byte |

### JFR, in one block

Turn it on in production and leave it on. It costs ~2% and it is the difference
between having data when something goes wrong and not having it:

```
-XX:StartFlightRecording=settings=profile,disk=true,maxsize=512m,maxage=12h,dumponexit=true,filename=$HOME/perf-out/app.jfr
-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints
```

`DebugNonSafepoints` matters more than it looks: without it, stacks from
JIT-compiled code are rounded to the nearest safepoint, so a profiler can blame
the **wrong method** — often a neighbour of the real culprit.

Ad hoc, on a process that was started without it:

```bash
jcmd <pid> JFR.start name=rec settings=profile
jcmd <pid> JFR.check
jcmd <pid> JFR.stop name=rec filename=$HOME/perf-out/rec.jfr
```

### async-profiler, in one block

```bash
asprof -d 60 -e cpu   -o flamegraph -f cpu.html   <pid>   # where CPU goes
asprof -d 60 -e alloc -o flamegraph -f alloc.html <pid>   # who makes the garbage
asprof -d 60 -e wall  -o flamegraph -f wall.html  <pid>   # where threads WAIT
asprof -d 60 -e lock  -o flamegraph -f lock.html  <pid>   # lock contention
```

- `-e cpu` needs `perf_event_paranoid <= 1`. Use `-e ctimer` instead when it is
  higher; no privileges required.
- **Killing the `asprof` process does not detach the agent.** If a session is
  stuck, `asprof stop <pid>` is what ends it. (`diagnose.sh` handles this for
  you, including on Ctrl-C.)
- `-e wall` is the one people forget, and it is the answer to "CPU is low but
  the app is slow".

---

## Reading the output

A few rules that save a lot of wasted effort.

**A flame graph is read by width, not height.** Height is just stack depth. The
widest block is where the time goes. Start there, and only there.

**RSS ≫ heap means the problem is not the heap.** Lowering `-Xmx` will not help.
Check, in order:

1. `export MALLOC_ARENA_MAX=2` — glibc opens a malloc arena per thread group;
   on a many-threaded app this alone often saves hundreds of MB, especially on
   RHEL.
2. thread count × `-Xss` — 2,000 threads × 1 MB is 2 GB of stacks.
3. Metaspace and direct `ByteBuffer`s — start with
   `-XX:NativeMemoryTracking=summary`, then `jcmd <pid> VM.native_memory summary`.
   In VisualVM, the *Buffer Pools* tab shows direct buffers live.

**GC load is a ratio, not a count.** 200 young GCs in 10 seconds is fine if they
total 40 ms. One Full GC is not fine. `diagnose.sh` reports pause time as a
share of wall-clock time, which is the number that matters.

**Promotion rate separates a leak from ordinary garbage.** High allocation with
low promotion is just garbage — annoying but survivable. Steady promotion into
old gen while young GCs keep running means objects are surviving, and that is
what a leak looks like.

**Lock time is latency, not CPU.** Contention will not show up in a CPU profile
at all. `--full` adds the wall-clock and lock profiles, which is where waiting
becomes visible.

**Throttling invalidates a profile.** If `cgroup throttle` is non-zero, the
application is not slow — it is being held back. Fix the limit first, then
measure again, or you will optimise the wrong thing.

**Old gen percentage on its own proves nothing.** G1 moves regions between
generations; capacity and usage must be read from the same sample. Watch the
*trend* with `jstat -gcutil <pid> 5000` before concluding anything.

### The anti-pattern dictionary

Section 9 matches each hot frame against a dictionary of about 50 patterns.
A sample of what it recognises and what it tells you to do:

| Frame it sees | What it concludes |
|---|---|
| `StringBuilder.append`, `makeConcat` | String concat in a loop → build the `StringBuilder` outside the loop, pre-sized |
| `Pattern.compile` | Regex recompiled on every call → `static final Pattern` |
| `HashMap.resize`, `HashMap.putVal` | Map growing and rehashing → give it an initial capacity |
| `ArrayList.grow`, `Arrays.copyOf` | List growing → pre-size it |
| `Integer.valueOf`, `*.valueOf` | Boxing → primitives, `IntStream`, `LongAdder` |
| `SimpleDateFormat` | Expensive and not thread safe → `DateTimeFormatter` |
| `Method.invoke`, `Class.forName` | Reflection on a hot path → cache the handle |
| `ObjectOutputStream` | Java serialization → a binary format |
| `FileInputStream.read` | Unbuffered IO → wrap in a `Buffered*` |
| `ConcurrentHashMap.transfer` | Map resizing under contention → pre-size it |
| `Unsafe.park`, `LockSupport` | Threads blocked → look at the lock section |
| `System.gc` | A manual Full GC, usually from a library → `-XX:+DisableExplicitGC` |

---

## Split archives

GitHub rejects files over 100 MB, so the three large archives are split with
`zip -s`:

```
jdk/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.z01   (100 MB)
jdk/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.zip   (the LAST part)
compile-time/pmd-dist-7.27.0-bin.z01
compile-time/pmd-dist-7.27.0-bin.zip
```

**`cat` will not join them.** In a split zip, every central-directory offset is
written relative to its own part, so a naive concatenation makes `unzip` report
*"overlapped components"* and `jar` report *"invalid LOC header"*. That is why
[`scripts/zip-join.py`](scripts/zip-join.py) exists: it concatenates the parts
**and rewrites the offsets** to be absolute.

`00-setup.sh` calls it automatically. If you would rather use the `zip` tool:

```bash
zip -s 0 compile-time/pmd-dist-7.27.0-bin.zip --out /tmp/pmd-joined.zip
```

Do not commit new tool archives without splitting them the same way.

---

## Writing policy: `$HOME` only

Nothing here writes to `/opt`, `/usr`, `/var` or `/tmp`, and nothing needs root.

- Tools unpack into `tools/`, inside the repository.
- All output goes to `$PERF_OUT`, which defaults to `$HOME/perf-out`.
- `env.sh` sets `TMPDIR="$PERF_OUT/tmp"`, and the scripts pass
  `-Djava.io.tmpdir` explicitly to every Java tool they launch.

**One exception you should know about.** The JVM you are *measuring* keeps its
own perf file in `/tmp/hsperfdata_<user>/<pid>`, and attach mechanisms use a
socket under `/tmp`. That is the target application's behaviour, not this
toolkit's. If `/tmp` is unwritable or mounted `noexec`, `jcmd`/`jstat` may fail
to attach — start the target with `-Djava.io.tmpdir=$HOME/tmp` and
`-XX:+PerfDisableSharedMem` if that is your situation.

---

## Repository layout

```
java-profiling-tools/
├── scripts/                 all the tooling
│   ├── 00-setup.sh          unpack + configure + verify
│   ├── env.sh               environment and aliases  (source this)
│   ├── common.sh            shared helpers (sourced, not run)
│   ├── diagnose.sh          ← the main command
│   ├── jmc-open.sh          JMC, pinned to the bundled JDK 21
│   ├── visualvm-open.sh     VisualVM, with its plugin cluster
│   ├── heap-summary.sh      memory analysis without a GUI
│   ├── jfr-record.sh        start a JFR recording
│   ├── jfr-summary.sh       decode a recording in the terminal
│   ├── cpu-profile.sh       CPU flame graph
│   ├── memory-profile.sh    allocation flame graph
│   ├── static-scan.sh       SpotBugs + PMD + CPD
│   └── zip-join.py          split-archive joiner
├── jdk/                     JDK 21 archive (split)
├── runtime/                 async-profiler, JMC, MAT, VisualVM, GCViewer, jfr-converter
├── compile-time/            SpotBugs, PMD (split), JaCoCo, JOL
├── plugins/visualvm/        21 .nbm modules, installed offline by 00-setup.sh
├── jmh/                     JMH jars, a runner, and an example benchmark
├── docs/                    screenshots, and how they were made
├── tools/                   created by 00-setup.sh  (git-ignored)
└── SHA256SUMS.txt           checksums for every bundled archive
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `jcmd not found` | The target is a JRE, or you are not its user. `jcmd` ships with the JDK. |
| `Unable to open socket file` / attach fails | You are not the same user as the JVM, or `/proc/sys/kernel/yama/ptrace_scope` is 1. |
| JMC: *"not suitable for this product"* | Run `./scripts/jmc-open.sh`, not `tools/jmc/jmc`. Check with `--where`. |
| VisualVM: *"could not install some modules"* | Re-run `./scripts/00-setup.sh` — a plugin dependency is missing from the cluster. |
| VisualVM starts but the tabs are missing | You launched `tools/visualvm/bin/visualvm` directly; it does not know about the cluster. Use `visualvm-open.sh`. |
| async-profiler: *"Perf events unavailable"* | `perf_event_paranoid > 1`. The scripts fall back to `ctimer` automatically. |
| A profiling session seems stuck | `asprof stop <pid>` — killing the asprof process does not detach the agent. |
| `unzip: overlapped components` | You joined a split archive with `cat`. Use `scripts/zip-join.py`. |
| MAT runs out of memory on a dump | Raise `-Xmx` in `tools/mat/MemoryAnalyzer.ini` to at least half the dump size. |
| An empty flame graph | The app was idle, or the window was too short. Measure under load, with `--duration 180`. |
| The report blames a JDK method you never call | Look at the `your code:` line under it — that is the first frame in your package. |

---

## Verifying the downloads

Every bundled archive is listed in [`SHA256SUMS.txt`](SHA256SUMS.txt):

```bash
sha256sum -c SHA256SUMS.txt
```

---

## Licence

The scripts and documentation in this repository are released under the terms
in [`LICENSE`](LICENSE). The bundled third-party tools keep their own licences —
GPLv2+CE (OpenJDK, VisualVM), EPL (JMC, MAT, JaCoCo), Apache 2.0
(async-profiler, PMD, JMH, JOL), LGPL (SpotBugs) — and their licence files
travel inside their own archives.
