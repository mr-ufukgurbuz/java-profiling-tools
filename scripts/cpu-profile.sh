#!/usr/bin/env bash
# CPU flame graph.
#
# Usage:
#   ./cpu-profile.sh <pid|process-name> [seconds]
#   ./cpu-profile.sh <pid|process-name> --duration 120
#
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/env.sh"    >/dev/null
source "$HERE/common.sh"

TARGET=""; DURATION=60
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="${2:?--duration needs a number of seconds}"; shift ;;
    -h|--help)  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         c_err "unknown option: $1"; exit 1 ;;
    *)          if [ -z "$TARGET" ]; then TARGET="$1"; else DURATION="$1"; fi ;;
  esac
  shift
done
[ -n "$TARGET" ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
DURATION=$(check_duration "$DURATION") || exit 1
PID=$(resolve_pid "$TARGET") || exit 1
[ -x "${ASPROF:-/nonexistent}" ] || { c_err "async-profiler missing - run ./scripts/00-setup.sh"; exit 1; }

# 'cpu' uses perf events, which need perf_event_paranoid <= 1. 'ctimer' is the
# fallback that needs no privileges at all; it samples on a timer instead.
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)
EVENT=cpu
if [ "$PARANOID" -gt 1 ] 2>/dev/null; then
  EVENT=ctimer
  c_info "perf_event_paranoid=$PARANOID -> using 'ctimer' (needs no root)."
fi

OUT="$PERF_OUT/cpu-$PID-$(date +%Y%m%d-%H%M%S).html"
c_info "pid=$PID  event=$EVENT  duration=${DURATION}s"
"$ASPROF" -d "$DURATION" -e "$EVENT" -o flamegraph -f "$OUT" "$PID"
c_info "$OUT   (read the width, not the height)"
