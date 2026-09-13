# `pmd-rulesets/` — the shared PMD ruleset

**[English](README.md) · [Türkçe](README.tr.md)**

`pmd-performance.xml` is one ruleset used in two places:

- **The command line** — [`scripts/static-scan.sh`](../scripts/static-scan.sh)
  passes it to PMD with `-R`. Nothing to configure.
- **IntelliJ IDEA** — `Settings → Tools → PMD`, add the file under the custom
  rulesets. Run it with right-click → `Run PMD → Custom → java-profiling-tools`.

One file in both places means the IDE and the build report the same things.
That matters more than it sounds: the usual failure mode is a developer whose
IDE is quiet and a CI job that fails, or the reverse.

## Why it is version-portable

The IDEA PMD plugin bundles **PMD 7.21.0**; this repository ships **PMD 7.27.0**
in [`compile-time/`](../compile-time/). The ruleset is written so the engine
version does not matter:

| | PMD 7.21.0 (IDE) | PMD 7.27.0 (CLI) |
|---|---|---|
| Rules loaded | 68 | 69 |
| Configuration errors | 0 | 0 |
| Findings on the same input | 3 | 3 |

Two things make that work. It references **whole categories** rather than
individual rules, so a rule added in a later PMD does not have to be named here
and a rule missing from an earlier one cannot break the load. And every rule it
*excludes* exists in both versions, so no exclude is a dangling reference.

The `performance` category — the one this toolkit is actually about — is
**identical in both**: the same 25 rules.

The single-rule difference is `OverridingThreadRun`, added to `multithreading`
after 7.21.

## What is in it

| Category | Rules | Why |
|---|---|---|
| `performance` | all 25 | The point of the file. `InefficientStringBuffering`, `ConsecutiveLiteralAppends`, `AvoidInstantiatingObjectsInLoops`, `InsufficientStringBufferDeclaration`, `UseArraysAsList` are the ones that show up in real profiles. |
| `multithreading` | all | Threading mistakes surface as lock contention, which is what `diagnose.sh --full` measures. |
| `design` | minus 9 | Mostly the complexity metrics — the numbers that answer "where do I refactor first?" once a profile has named the hot class. |

Excluded from `design`, and why:

| Excluded | Reason |
|---|---|
| `LawOfDemeter` | Fires on nearly every line of ordinary Java. |
| `LoosePackageCoupling` | Means nothing without per-project configuration. |
| `ExcessiveImports`, `TooManyMethods`, `TooManyFields`, `ExcessivePublicCount` | Counting things says little on its own, and these four produce most of an unfiltered design report. |
| `DataClass` | Flags every DTO and value object. |
| `SignatureDeclareThrowsException`, `AvoidCatchingGenericException` | Style arguments, not performance ones. |

## Changing it

```bash
PMD_RULESET=quality/my-pmd.xml ./scripts/static-scan.sh build/classes src/main/java
PMD_RULESET= ./scripts/static-scan.sh build/classes    # PMD's own categories instead
```

If you edit the file, keep referencing categories rather than individual rules —
that is what keeps it working across PMD versions. The
[ruleset syntax](https://docs.pmd-code.org/latest/pmd_userdocs_making_rulesets.html)
covers the rest.

## CPD

`static-scan.sh` also runs CPD, PMD's copy-paste detector, at 100 tokens. It
takes no ruleset, so there is nothing to configure here. Duplicated blocks are
a good refactor target but not, on their own, a performance problem.

## Licence

PMD is Apache 2.0 (BSD-style for some components); its licence travels inside
the distribution in [`compile-time/`](../compile-time/). This ruleset is part of
this repository and covered by [`LICENSE`](../LICENSE).

## What these findings are

**Candidates.** PMD reads source and does not know what runs often — it flags a
`String` concatenation in startup code exactly as loudly as one in a hot loop.
Confirm with [`diagnose.sh`](../scripts/diagnose.sh) before changing anything.
