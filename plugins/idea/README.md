# `plugins/idea/` — the IntelliJ IDEA plugins

**[English](README.md) · [Türkçe](README.tr.md)**

The two static analysers [`scripts/static-scan.sh`](../../scripts/static-scan.sh)
runs, packaged so they can be installed on a machine with no internet. Same
analysis, moved into the editor: right-click a class, get the findings inline.

| | [SpotBugs][sb] | [PMD][pmd] |
|---|---|---|
| File (in `tools/idea-plugins/`) | `spotbugs-idea-1.2.8.zip` | `PMDPlugin-2.1.0.zip` |
| Plugin id | `org.jetbrains.plugins.spotbugs` | `PMDPlugin` |
| Requires | IDEA build `222.1`+ (2022.2 onwards) | IDEA build `241`+ (2024.1 onwards) |
| Reads | **bytecode** | **source** |
| Bundled engine | SpotBugs 4.8.6 | PMD 7.21.0 |
| Settings page | `Settings → Tools → SpotBugs` | `Settings → Tools → PMD` |

[sb]: https://plugins.jetbrains.com/plugin/14014-spotbugs
[pmd]: https://plugins.jetbrains.com/plugin/1137-pmd

Both work in Community or Ultimate, and both are current for 2025.2.x — neither
declares an `until-build`.

## Install

The plugins are committed here as `idea-plugins.tar.xz`: some git hosts reject
`.zip` uploads, so the two plugin zips travel inside one archive. Unpack them
first — they land in `tools/idea-plugins/`:

```bash
./scripts/00-setup.sh          # or, on its own:
tar -xJf plugins/idea/idea-plugins.tar.xz -C /tmp
```

Then `Settings → Plugins → ⚙ → Install Plugin from Disk…`, pick a zip, repeat
for the other, then restart once. No Marketplace connection is attempted. The
`.zip` form is kept deliberately: that is what *Install Plugin from Disk*
expects.

For a team, serving the zips from an internal web server with an
`updatePlugins.xml` beats twenty people installing from disk — plugins then show
up in IDEA's normal search and update flow
(`Settings → Plugins → ⚙ → Manage Plugin Repositories → +`).

## SpotBugs reads bytecode, so compile first

This is the one thing that confuses people. IDEA's own inspections and PMD read
your *source* as you type. SpotBugs reads **compiled bytecode** — it follows
data flow across method boundaries, which is how it finds null paths and
unclosed streams that source-level analysis misses.

So: **`Build → Build Project` before you analyse.** Analysing a class you edited
but did not rebuild reports findings against the old bytecode, with line numbers
that no longer line up.

Then right-click a class or package → `SpotBugs → Analyze …`.

Under `Settings → Tools → SpotBugs`:

| Setting | Value | Why |
|---|---|---|
| Effort | `Max` | Lower settings skip the interprocedural analysis that makes SpotBugs worth running. |
| Minimum confidence | `Medium` | `Low` roughly triples the findings. Start here, drop to `Low` once the report is clean. |
| Analysis effort on the fly | off | Max effort on every keystroke will make the IDE crawl on a large module. |

Add an exclude filter too — `Filter → Exclude filter files → +`, pointing at
[`spotbugs-rule-packs/spotbugs-exclude.xml`](../../spotbugs-rule-packs/spotbugs-exclude.xml).
Without one, `EI_EXPOSE_REP` fires on nearly every getter and the report fills
with thousands of findings nobody reads.

## Making the IDE run the same rules as the build

Out of the box the two disagree, and each plugin needs one step to fix it.

![Two steps, once per machine](../../docs/images/14-ide-setup-steps.svg)

### SpotBugs — swap in the newer rule packs

The plugin ships its own copies of the rule packs, and they are **older** than
the ones in [`spotbugs-rule-packs/`](../../spotbugs-rule-packs/):

| Bundled in the plugin | In this repository |
|---|---|
| `fb-contrib-7.6.0` (and `6.2.1`) | `sb-contrib-7.6.9` |
| `findsecbugs-plugin-1.12.0` | `findsecbugs-plugin-1.14.0` |
| `AndroidFindbugs_0.5` | — |

`Settings → Tools → SpotBugs → Plugins → +`, add `sb-contrib-7.6.9.jar` and
`findsecbugs-plugin-1.14.0.jar` from `tools/spotbugs-rule-packs/` (they are
committed as a `.tar.xz` and unpacked there by `00-setup.sh`), **and disable the
bundled copy of each one.**

> Disabling is not optional. SpotBugs refuses to load two plugins with the same
> plugin id, and these pairs share theirs — `com.mebigfatguy.fbcontrib` and
> `com.h3xstream.findsecbugs`. Leave both enabled and analysis fails outright
> rather than picking the newer.

Going the other way — downgrading this repository to the plugin's versions so
nothing has to be disabled — does not work. fb-contrib 7.6.0 predates a BCEL
change in SpotBugs 4.10.4, and three of its detectors
(`IncorrectInternalClassUse`, `OverlyPermissiveMethod`,
`FunctionalInterfaceIssues`) throw on every class instead of reporting.
sb-contrib 7.6.9 is the release that fixed it.

### PMD — point it at the shared ruleset

`Settings → Tools → PMD`, add
[`pmd-rulesets/pmd-performance.xml`](../../pmd-rulesets/pmd-performance.xml)
as a custom ruleset. Run it with right-click → `Run PMD → Custom →
java-profiling-tools`.

That is the same file `static-scan.sh` passes to the CLI, and it is written to
load identically on the plugin's PMD 7.21.0 and the bundled 7.27.0 — 68 rules
against 69, zero configuration errors either way, same findings. Details in
[`pmd-rulesets/README.md`](../../pmd-rulesets/README.md).

## What ends up running where

![One set of rules, two places that run them](../../docs/images/13-ide-vs-cli.svg)

After both steps:

| | IDE | `static-scan.sh` |
|---|---|---|
| SpotBugs engine | 4.8.6 | 4.10.4 |
| SpotBugs rule packs | **sb-contrib 7.6.9 + findsecbugs 1.14.0** | **same** |
| PMD engine | 7.21.0 | 7.27.0 |
| PMD ruleset | **pmd-performance.xml** | **same** |

The rules match. The engines do not, and cannot: each plugin links against the
analyser version it was built with, and replacing that inside the plugin is not
something you can do safely. In practice the difference is small, and where the
two disagree the CLI is the newer analyser — so the build, not the IDE, is what
a disagreement should be settled against.

## The IDE is the convenience, the build is the authority

Run both tools in your build and fail on new findings there. The IDE plugins are
for the loop while you are writing code; they are not a quality gate, because
they only cover what someone remembered to right-click. See
[`spotbugs-rule-packs/README.md`](../../spotbugs-rule-packs/README.md#using-these-in-a-build)
for the CLI and Maven wiring.

## What this is not

Both tools find *patterns*. Neither knows which of them is on a hot path, and
both will flag a `String` concatenation that runs once at startup with the same
emphasis as one inside a 400-iteration loop. Use
[`diagnose.sh`](../../scripts/diagnose.sh) to find out where the time actually
goes, then come back here to see whether the analysers already had something to
say about that method.

## Licences

The SpotBugs IDEA plugin is LGPL 2.1, like SpotBugs itself. The PMD plugin is
BSD-style, like PMD. Neither is covered by this repository's
[`LICENSE`](../../LICENSE); their terms travel inside their own archives.
