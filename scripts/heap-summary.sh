#!/usr/bin/env bash
# Memory analysis - IN THE TERMINAL. No GUI needed.
#
# Usage:
#   ./heap-summary.sh <pid|process-name>            -> instant histogram (no dump)
#   ./heap-summary.sh <pid|process-name> --dump     -> takes a dump + runs MAT HEADLESS
#   ./heap-summary.sh $PERF_OUT/heap.hprof          -> analyses an existing dump headless
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/env.sh"    >/dev/null
source "$HERE/common.sh"

ARG=""; DUMP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dump)    DUMP=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        c_err "unknown option: $1"; exit 1 ;;
    *)         ARG="$1" ;;
  esac
  shift
done
[ -n "$ARG" ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
N="${TOP:-30}"

bar() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

mat_headless() {
  local dump="$1"
  local pd="$TOOLS/mat/ParseHeapDump.sh"
  [ -x "$pd" ] || { echo "MAT is not unpacked. Run ./scripts/00-setup.sh first."; return 1; }
  bar "MAT HEADLESS ANALYSIS (no GUI)"
  echo "Large dumps take a while. If MAT runs out of memory, raise"
  echo "the -Xmx value inside tools/mat/MemoryAnalyzer.ini."
  "$pd" "$dump" org.eclipse.mat.api:suspects org.eclipse.mat.api:overview
  echo
  echo ">> Reports produced (HTML inside the zip - download and open in a browser):"
  ls -la "$(dirname "$dump")"/*Leak_Suspects* "$(dirname "$dump")"/*System_Overview* 2>/dev/null || true
}

# --- If an existing .hprof was given, analyse it directly ---
if [ -f "$ARG" ] && [[ "$ARG" == *.hprof ]]; then
  mat_headless "$ARG"
  exit 0
fi

PID=$(resolve_pid "$ARG") || exit 1

bar "RSS vs HEAP  (make this distinction first)"
RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
echo "RSS (operating system):  $((RSS_KB/1024)) MB"
jcmd "$PID" GC.heap_info 2>/dev/null || echo "(jcmd failed - are you the same user?)"
cat <<'NOTE'

  RSS ~ heap       -> the problem IS the heap, look at the histogram below.
  RSS >> heap      -> DO NOT touch the heap. Check these three, in order:
      1) glibc malloc arenas  ->  export MALLOC_ARENA_MAX=2   (very common on RHEL, one line)
      2) thread count x -Xss
      3) Metaspace / direct buffers  ->  start with -XX:NativeMemoryTracking=summary,
                                          then: jcmd <pid> VM.native_memory summary
NOTE

bar "THREAD COUNT"
TC=$(jcmd "$PID" Thread.print 2>/dev/null | grep -c '^"' || echo "?")
echo "$TC threads   (x -Xss = total stack memory. 2000 x 1MB = 2GB)"

bar "TOP $N CLASSES BY SIZE  (instant, no dump)"
echo "  Causes a brief STW pause."
jcmd "$PID" GC.class_histogram 2>/dev/null | head -n $((N+3)) \
  || echo "  (failed - you can try jmap -histo:live $PID)"

if [ "$DUMP" = "1" ]; then
  D="$PERF_OUT/heap-$PID-$(date +%Y%m%d-%H%M%S).hprof"
  bar "TAKING HEAP DUMP"
  echo "  File size ~ live heap size. Causes an STW pause."
  echo "  Do it during low traffic and watch your disk space."
  jcmd "$PID" GC.heap_dump "$D"
  ls -lh "$D"
  mat_headless "$D"
fi

cat <<END

Output: $PERF_OUT

Next step:
  Suspect a leak         ->  ./heap-summary.sh <pid> --dump
  Investigate garbage    ->  ./memory-profile.sh <pid> 60      (allocation flame graph)
  Whole picture          ->  ./jfr-record.sh <pid> 180  then  ./jfr-summary.sh \$PERF_OUT/jfr-*.jfr
END
