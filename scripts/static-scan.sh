#!/usr/bin/env bash
# Compile-time performance scan: bottleneck CANDIDATES without running the code.
# Usage: ./static-scan.sh <compiled-classes-dir> [source-dir]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null
CLASSES="${1:?usage: $0 <classes-dir> [src-dir]}"; SRC="${2:-src/main/java}"
REPORT="$PERF_OUT/static-report"; mkdir -p "$REPORT"
# Optional SpotBugs rule packs. Drop sb-contrib / findsecbugs jars in here and
# they get loaded automatically - their performance rules go well beyond core.
PACKS="${SPOTBUGS_RULE_PACKS:-$PROFILING_HOME/spotbugs-rule-packs}"

echo "=== SpotBugs (bytecode: PERFORMANCE + CORRECTNESS) ==="
EXTRA=""
if [ -d "$PACKS" ]; then
  PACKLIST=$(find "$PACKS" -name '*.jar' | tr '\n' ':' | sed 's/:$//')
  [ -n "$PACKLIST" ] && EXTRA="-pluginList $PACKLIST"
fi
"$TOOLS/spotbugs/bin/spotbugs" -textui -effort:max -low $EXTRA \
  -bugCategories PERFORMANCE,CORRECTNESS,MT_CORRECTNESS \
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
