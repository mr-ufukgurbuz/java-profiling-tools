#!/usr/bin/env bash
# Analyses a JFR recording IN THE TERMINAL ONLY. No GUI, no JMC.
# Usage: ./jfr-summary.sh <recording.jfr> [line-count]
#
# NOTE: uses the bundled JDK 21's 'jfr' tool. Reading a recording produced by
#       JDK 11 is fine - the format is forward compatible.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null
FILE="${1:?usage: $0 <recording.jfr> [line-count]}"
N="${2:-20}"
[ -f "$FILE" ] || { echo "no such file: $FILE"; exit 1; }

# jfr tool: prefer the bundled one, fall back to whatever is on PATH
JFR="$JFRCLI"
[ -x "$JFR" ] || JFR="$(command -v jfr || true)"
[ -n "$JFR" ] || { echo "jfr tool not found. Run ./scripts/00-setup.sh first."; exit 1; }

bar() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

bar "RECORDING SUMMARY (which event, how many times)"
"$JFR" summary "$FILE" 2>/dev/null | head -40

# The FIRST line of a stack trace is the method where self time is spent.
# We take the line right after 'stackTrace = [' and count them.
top_frame() {
  awk '
    /stackTrace = \[/ { grab=1; next }
    grab { gsub(/^[ \t]+/,""); sub(/ line: [0-9]+$/,""); print; grab=0 }
  ' | sort | uniq -c | sort -rn | head -"$N"
}

bar "CPU: TOP $N HOTTEST METHODS (self time)"
echo "  (wide = eats most of the time. Focus on the first 3.)"
"$JFR" print --events ExecutionSample "$FILE" 2>/dev/null | top_frame \
  || echo "  No ExecutionSample - the recording needs settings=profile."

bar "MEMORY: TOP $N ALLOCATED TYPES"
echo "  (source of the garbage. In Java most CPU goes here.)"
"$JFR" print --events ObjectAllocationInNewTLAB,ObjectAllocationOutsideTLAB,ObjectAllocationSample "$FILE" 2>/dev/null \
  | grep -E '^[[:space:]]*objectClass = ' \
  | sed 's/^[[:space:]]*objectClass = //; s/ *(classLoader.*$//' \
  | sort | uniq -c | sort -rn | head -"$N" \
  || echo "  No allocation events - 'settings=profile' is required."

bar "MEMORY: TOP $N ALLOCATING CODE LINES"
"$JFR" print --events ObjectAllocationInNewTLAB,ObjectAllocationOutsideTLAB,ObjectAllocationSample "$FILE" 2>/dev/null | top_frame \
  || true

bar "GC: LONGEST $N PAUSES"
"$JFR" print --events GarbageCollection "$FILE" 2>/dev/null \
  | grep -E '^[[:space:]]*duration = ' | sed 's/^[[:space:]]*duration = //' \
  | sort -rn | head -"$N" \
  || echo "  No GC events."

bar "GC: CAUSE BREAKDOWN"
"$JFR" print --events GarbageCollection "$FILE" 2>/dev/null \
  | grep -E '^[[:space:]]*cause = ' | sed 's/^[[:space:]]*cause = //' \
  | sort | uniq -c | sort -rn | head -10 || true

bar "LOCKS: TOP $N CONTENDED MONITORS"
"$JFR" print --events JavaMonitorEnter "$FILE" 2>/dev/null \
  | grep -E '^[[:space:]]*monitorClass = ' \
  | sed 's/^[[:space:]]*monitorClass = //; s/ *(classLoader.*$//' \
  | sort | uniq -c | sort -rn | head -"$N" \
  || echo "  No contention events (good news)."

echo
echo "To dig into the raw events:"
echo "  $JFR print --events ExecutionSample --stack-depth 30 $FILE | less"
echo "  $JFR print --json --events GarbageCollection $FILE"
