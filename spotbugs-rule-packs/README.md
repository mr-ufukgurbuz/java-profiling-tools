# `spotbugs-rule-packs/` — extra SpotBugs detectors

**[English](README.md) · [Türkçe](README.tr.md)**

The bundled SpotBugs 4.10.4 ships 518 bug patterns across 196 detectors. These
two jars add 463 more. They are not IntelliJ plugins and `00-setup.sh` does not
unpack them — they are plain SpotBugs *plugin jars*, loaded two ways:

- **From the command line** — [`scripts/static-scan.sh`](../scripts/static-scan.sh)
  finds every `.jar` in this directory and passes it to SpotBugs with
  `-pluginList`. Nothing to configure.
- **From IntelliJ IDEA** — `Settings → Tools → SpotBugs → Plugins → +`, then
  pick these jars from disk. See [`plugins/idea/`](../plugins/idea/).

## What is in here

| Jar | Plugin id | Patterns | Detectors |
|---|---|---|---|
| `sb-contrib-7.6.9.jar` | `com.mebigfatguy.fbcontrib` | 319 | 153 |
| `findsecbugs-plugin-1.14.0.jar` | `com.h3xstream.findsecbugs` | 144 | 121 |

Which category a pattern lands in decides whether you ever see it:

| | CORRECTNESS | STYLE | PERFORMANCE | MT_CORRECTNESS | SECURITY |
|---|---|---|---|---|---|
| SpotBugs core | 159 | 94 | 37 | 54 | 23 |
| **sb-contrib** | 187 | 80 | **43** | 8 | — |
| **findsecbugs** | — | — | — | — | **144** |

**sb-contrib** is the one that matters for profiling work: it more than doubles
the PERFORMANCE patterns available, and it covers ground core SpotBugs does not
— fields that grow without bound (`PMB_POSSIBLE_MEMORY_BLOAT`), collections
built and never read (`WOC_WRITE_ONLY_COLLECTION`), boxing in loops, `Map`
iteration that goes through `keySet()` and then calls `get()` for every key.

**findsecbugs** is a security pack — deserialization, path traversal, weak
crypto, XXE, command injection. All 144 of its patterns are `SECURITY`.

## Why `--security` exists

`static-scan.sh` asks SpotBugs for `PERFORMANCE,CORRECTNESS,MT_CORRECTNESS`.
This is a profiling toolkit, and a performance report that also lists every XXE
risk is a report nobody finishes reading. `SECURITY` is not in that list, so
**findsecbugs is loaded but silent by default**. Turn it on explicitly:

```bash
./scripts/static-scan.sh --security build/classes src/main/java
```

Or choose the categories yourself:

```bash
./scripts/static-scan.sh --categories SECURITY build/classes
```

## The exclude filter

`spotbugs-exclude.xml` is applied by default. It drops three things:

| Excluded | Why |
|---|---|
| `EI_EXPOSE_REP`, `EI_EXPOSE_REP2`, `MS_EXPOSE_REP` | Fires on nearly every getter. Left on, it is most of the report, and people stop reading. |
| `*Test`, `*Tests`, `*TestCase`, `Test*`, `*.test.*` classes | Not on a hot path, and tests legitimately do things these detectors flag. |
| Synthetic and generated classes | `Foo$1`, `Foo$$Bar`, anything under a `generated/` source directory. |

That last one is not cosmetic: a `switch` over an enum makes javac synthesise a
`$SwitchMap` holder class that trips detectors on code nobody wrote.

To see everything anyway:

```bash
./scripts/static-scan.sh --no-exclude build/classes
```

To use your project's own filter instead:

```bash
SPOTBUGS_EXCLUDE=quality/my-exclude.xml ./scripts/static-scan.sh build/classes
```

The [filter syntax](https://spotbugs.readthedocs.io/en/latest/filter.html) is
worth ten minutes if you are going to run this in CI.

## Adding more packs

Drop the jar in this directory. `static-scan.sh` picks up every `.jar` here, and
`00-setup.sh --verify` counts them.

One rule: **SpotBugs refuses to load two plugins with the same plugin id.** The
ids are in the table above. Renaming a second copy of sb-contrib does not help —
SpotBugs reads the id out of the jar and fails rather than picking one.

## Using these in a build

The IDE plugin and `static-scan.sh` are for the loop you run while working. The
authority should be the build, with the same two jars. SpotBugs takes them the
same way `static-scan.sh` does:

```bash
spotbugs -textui -effort:max -low \
    -pluginList spotbugs-rule-packs/sb-contrib-7.6.9.jar:spotbugs-rule-packs/findsecbugs-plugin-1.14.0.jar \
    -exclude spotbugs-rule-packs/spotbugs-exclude.xml \
    -auxclasspath "$(cat compile.classpath)" \
    -xml:withMessages -output build/reports/spotbugs.xml \
    build/classes
```

With Maven, point `spotbugs-maven-plugin` at the jars on disk rather than at
coordinates it would have to download:

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

Suppressions (`@SuppressFBWarnings`) should carry a written justification and be
questioned in review — an unexplained suppression is how a real finding gets
buried.

## Licences

`sb-contrib` is LGPL 2.1 (`license.txt` inside the jar). `findsecbugs` is
LGPL 3.0. Both keep their own terms; neither is covered by this repository's
[`LICENSE`](../LICENSE).

## What these findings are

They are **candidates**. A static analyser cannot tell you that
`PMB_POSSIBLE_MEMORY_BLOAT` on a 12-entry cache does not matter, or that the
boxing it found is on a path executed twice a day. Confirm with
[`diagnose.sh`](../scripts/diagnose.sh) before changing anything — the whole
point of this repository is that you measure first.
