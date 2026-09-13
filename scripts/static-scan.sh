#!/usr/bin/env bash
# Compile-time performance scan: bottleneck CANDIDATES without running the code.
#
# Usage: ./static-scan.sh [options] <compiled-classes-dir> [source-dir]
#
#   --security            also report the SECURITY category (Find Security Bugs)
#   --categories LIST     replace the SpotBugs category list entirely
#   --no-exclude          ignore the exclude filter, report everything
#
# Environment overrides:
#   SPOTBUGS_RULE_PACKS   directory of rule-pack jars  (default: spotbugs-rule-packs/)
#   SPOTBUGS_CATEGORIES   category list                (default: PERFORMANCE,CORRECTNESS,MT_CORRECTNESS)
#   SPOTBUGS_EXCLUDE      exclude filter file; set empty to disable
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null

CATEGORIES="${SPOTBUGS_CATEGORIES:-PERFORMANCE,CORRECTNESS,MT_CORRECTNESS}"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --security)     CATEGORIES="$CATEGORIES,SECURITY" ;;
    --categories)   CATEGORIES="${2:?--categories needs a list}"; shift ;;
    --no-exclude)   SPOTBUGS_EXCLUDE="" ;;
    -h|--help)      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 1 ;;
    *)              ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

CLASSES="${1:?usage: $0 [options] <classes-dir> [src-dir]}"; SRC="${2:-src/main/java}"
REPORT="$PERF_OUT/static-report"; mkdir -p "$REPORT"

# SpotBugs rule packs. The two that ship with this repository are loaded from
# here automatically; drop more jars in and they are picked up too.
#   sb-contrib   - 319 extra patterns, 43 of them PERFORMANCE
#   findsecbugs  - 144 patterns, ALL of them in the SECURITY category, which is
#                  why they only show up with --security
PACKS="${SPOTBUGS_RULE_PACKS:-$PROFILING_HOME/spotbugs-rule-packs}"

# Without a filter, EI_EXPOSE_REP alone can account for most of the report.
# See spotbugs-rule-packs/spotbugs-exclude.xml for what is filtered and why.
EXCLUDE="${SPOTBUGS_EXCLUDE-$PROFILING_HOME/spotbugs-rule-packs/spotbugs-exclude.xml}"

echo "=== SpotBugs (bytecode: $CATEGORIES) ==="
SBOPTS=()
if [ -d "$PACKS" ]; then
  PACKLIST=$(find "$PACKS" -name '*.jar' | sort | tr '\n' ':' | sed 's/:$//')
  if [ -n "$PACKLIST" ]; then
    SBOPTS+=(-pluginList "$PACKLIST")
    find "$PACKS" -name '*.jar' | sort | while read -r j; do
      echo "    rule pack: $(basename "$j")"
    done
  fi
fi
if [ -n "$EXCLUDE" ] && [ -f "$EXCLUDE" ]; then
  SBOPTS+=(-exclude "$EXCLUDE")
  echo "    exclude:   $(basename "$EXCLUDE")"
elif [ -n "$EXCLUDE" ]; then
  echo "    exclude:   $EXCLUDE not found, reporting everything"
fi

"$TOOLS/spotbugs/bin/spotbugs" -textui -effort:max -low "${SBOPTS[@]+"${SBOPTS[@]}"}" \
  -bugCategories "$CATEGORIES" \
  -html -output "$REPORT/spotbugs.html" "$CLASSES" || true
echo ">> $REPORT/spotbugs.html"

echo "=== PMD (source: performance + design) ==="
"$TOOLS/pmd/bin/pmd" check -d "$SRC" \
  -R category/java/performance.xml,category/java/design.xml \
  -f html -r "$REPORT/pmd.html" --no-fail-on-violation || true
echo ">> $REPORT/pmd.html"

echo "=== CPD (copy-paste detection) ==="
"$TOOLS/pmd/bin/pmd" cpd --minimum-tokens 100 --dir "$SRC" --language java \
  --format text > "$REPORT/cpd.txt" 2>/dev/null || true
echo ">> $REPORT/cpd.txt"
