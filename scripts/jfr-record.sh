#!/usr/bin/env bash
# JFR recording. Built into JDK 11+, free, ~2% overhead.
#
# Usage:
#   ./jfr-record.sh <pid|process-name> [seconds]
#   ./jfr-record.sh <pid|process-name> --duration 300
#
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
source "$HERE/env.sh"    >/dev/null
source "$HERE/common.sh"

TARGET=""; DURATION=180
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

OUT="$PERF_OUT/jfr-$PID-$(date +%Y%m%d-%H%M%S).jfr"
# A unique name, so a second run does not collide with the first.
NAME="rec_$$"
jcmd "$PID" JFR.start name="$NAME" settings=profile duration="${DURATION}s" filename="$OUT"
c_info "ready in ${DURATION}s: $OUT"
c_info "then:  ./scripts/jfr-summary.sh $OUT"
c_info "to stop it early:  jcmd $PID JFR.stop name=$NAME filename=$OUT"
