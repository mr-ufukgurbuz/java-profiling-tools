# `plugins/idea/` — the SpotBugs plugin for IntelliJ IDEA

**[English](README.md) · [Türkçe](README.tr.md)**

`spotbugs-idea-1.2.8.zip` is the [SpotBugs plugin][mp] for IntelliJ IDEA,
packaged here so it can be installed on a machine with no internet. It is the
same analysis [`scripts/static-scan.sh`](../../scripts/static-scan.sh) runs,
moved into the editor: right-click a class, get the findings inline.

[mp]: https://plugins.jetbrains.com/plugin/14014-spotbugs

| | |
|---|---|
| Plugin id | `org.jetbrains.plugins.spotbugs` |
| Version | 1.2.8 |
| Requires | IDEA build `222.1` or later — that is 2022.2 onwards, including 2025.2.x |
| Editions | Community or Ultimate (it needs `com.intellij.modules.java`) |
| Bundled analyser | SpotBugs **4.8.6** |

## Install

`Settings → Plugins → ⚙ → Install Plugin from Disk…`, pick the zip, restart the
IDE. No Marketplace connection is attempted.

For a team, serving the zip from an internal web server with an
`updatePlugins.xml` beats twenty people installing from disk — plugins then show
up in IDEA's normal search and update flow. Point developers at it with
`Settings → Plugins → ⚙ → Manage Plugin Repositories → +`.

## It reads bytecode, so compile first

This is the one thing that confuses people. IDEA's own inspections read your
*source* as you type. SpotBugs reads **compiled bytecode** — it follows data
flow across method boundaries, which is how it finds null paths and unclosed
streams that source-level inspections miss.

The practical consequence: **`Build → Build Project` first.** Analysing a class
you have edited but not rebuilt reports findings against the old bytecode, with
line numbers that no longer line up.

Then: right-click a class or package → `SpotBugs → Analyze …`, or use the
SpotBugs tool window for the whole module.

## First-run settings

`Settings → Tools → SpotBugs`

| Setting | Value | Why |
|---|---|---|
| Effort | `Max` | Lower settings skip the interprocedural analysis that makes SpotBugs worth running. |
| Minimum confidence | `Medium` | `Low` roughly triples the findings. Start at `Medium`, drop to `Low` once the report is clean. |
| Analysis effort on the fly | off | Max effort on every keystroke will make the IDE crawl on a large module. |

## Adding the newer rule packs

The plugin already bundles rule packs of its own, and they are **older** than
the ones in [`spotbugs-rule-packs/`](../../spotbugs-rule-packs/):

| Bundled in the plugin | In this repository |
|---|---|
| `fb-contrib-7.6.0` (and `6.2.1`) | `sb-contrib-7.6.9` |
| `findsecbugs-plugin-1.12.0` | `findsecbugs-plugin-1.14.0` |
| `AndroidFindbugs_0.5` | — |

To use the newer ones: `Settings → Tools → SpotBugs → Plugins → +`, then add
`spotbugs-rule-packs/sb-contrib-7.6.9.jar` and
`spotbugs-rule-packs/findsecbugs-plugin-1.14.0.jar` from disk.

> **Disable the bundled copy of each one first.** SpotBugs refuses to load two
> plugins with the same plugin id, and these pairs share theirs —
> `com.mebigfatguy.fbcontrib` and `com.h3xstream.findsecbugs`. Enable both
> versions and analysis fails outright rather than picking the newer.

## Set an exclude filter

`Settings → Tools → SpotBugs → Filter → Exclude filter files → +`, and point it
at [`spotbugs-rule-packs/spotbugs-exclude.xml`](../../spotbugs-rule-packs/spotbugs-exclude.xml).

Without one, `EI_EXPOSE_REP` and `EI_EXPOSE_REP2` fire on nearly every getter
and setter. The report fills with thousands of findings, and the team stops
reading it — which costs more than the two real bugs buried in there.

## The IDE is the convenience, the build is the authority

Run SpotBugs in your build and fail on new findings there. The IDE plugin is for
the loop while you are writing code; it is not a quality gate, because it only
covers what someone remembered to right-click. See
[`spotbugs-rule-packs/README.md`](../../spotbugs-rule-packs/README.md#using-these-in-a-build)
for the CLI and Maven wiring.

One caveat if you compare the two: this plugin bundles SpotBugs **4.8.6**, while
[`compile-time/spotbugs-4.10.4.tgz`](../../compile-time/) — what `static-scan.sh`
uses — is **4.10.4**. The findings are close but not identical. When they
disagree, the CLI is the newer analyser.

## What this is not

SpotBugs finds bug *patterns*. It does not know which of them is on a hot path,
and it will happily flag a `String` concatenation that runs once at startup with
the same emphasis as one inside a 400-iteration loop. Use
[`diagnose.sh`](../../scripts/diagnose.sh) to find out where the time actually
goes, then come back here to see whether SpotBugs already had something to say
about that method.

## Licence

The SpotBugs IDEA plugin is LGPL 2.1, like SpotBugs itself. It is not covered by
this repository's [`LICENSE`](../../LICENSE).
