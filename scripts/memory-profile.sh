#!/usr/bin/env bash
# Allocation flame graph = "which code produces the garbage".
#
# Usage:
#   ./memory-profile.sh <pid|process-name> [seconds]
#   ./memory-profile.sh <pid|process-name> --duration 120 --heap-dump
#
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/env.sh"    >/dev/null
source "$HERE/common.sh"

TARGET=""; DURATION=60; HEAPDUMP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --heap-dump) HEAPDUMP=1 ;;
    --duration)  DURATION="${2:?--duration needs a number of seconds}"; shift ;;
    -h|--help)   sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          c_err "unknown option: $1"; exit 1 ;;
    *)           if [ -z "$TARGET" ]; then TARGET="$1"; else DURATION="$1"; fi ;;
  esac
  shift
done
[ -n "$TARGET" ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
DURATION=$(check_duration "$DURATION") || exit 1
PID=$(resolve_pid "$TARGET") || exit 1
[ -x "${ASPROF:-/nonexistent}" ] || { c_err "async-profiler missing - run ./scripts/00-setup.sh"; exit 1; }

echo "=== Heap summary ==="
jcmd "$PID" GC.heap_info 2>/dev/null || c_warn "jcmd failed - are you the same user as the JVM?"
RSS=$(ps -o rss= -p "$PID" | tr -d ' ')
echo "RSS: $((RSS/1024)) MB   <- if this is far above the heap, the problem is NOT in the heap"

OUT="$PERF_OUT/alloc-$PID-$(date +%Y%m%d-%H%M%S).html"
echo
c_info "allocation profile, ${DURATION}s"
"$ASPROF" -d "$DURATION" -e alloc -o flamegraph -f "$OUT" "$PID"
c_info "$OUT"

if [ "$HEAPDUMP" = "1" ]; then
  D="$PERF_OUT/heap-$PID-$(date +%Y%m%d-%H%M%S).hprof"
  c_info "heap dump ($D) - STW pause, file size ~ live heap size"
  jcmd "$PID" GC.heap_dump "$D"
  c_info "headless analysis:  ./scripts/heap-summary.sh $D"
fi
