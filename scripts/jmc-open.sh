#!/usr/bin/env bash
#
# jmc-open.sh - Opens JDK Mission Control with the RIGHT JDK.
#
# WHY THIS SCRIPT EXISTS
#   JMC is an Eclipse RCP application and needs Java 17+. If your system has
#   JDK 11 installed, running the launcher directly fails with:
#
#       Version 11.0.x of the JVM is not suitable for this product.
#       Version: 17 or greater is required.
#
#   Eclipse decides which JVM to use from the '-vm' line in jmc.ini; without it
#   it falls back to 'java' on PATH - that is, JDK 11. This script passes the
#   bundled JDK 21 EXPLICITLY with '-vm' on the command line, which overrides
#   the ini file and keeps working even if the package is moved elsewhere.
#
#   IMPORTANT: this only affects how JMC ITSELF runs. The application you are
#   analysing stays on JDK 11; JMC opens JDK 11 recordings without any trouble.
#
# Usage:
#   ./jmc-open.sh                          -> open JMC
#   ./jmc-open.sh ~/perf-out/recording.jfr -> open with the recording loaded
#   ./jmc-open.sh --memory 8g              -> JMC's own heap (for large JFR files)
#   ./jmc-open.sh --jdk /path/to/jdk17     -> run with a different JDK
#   ./jmc-open.sh --clean                  -> reset the workspace (if settings broke)
#   ./jmc-open.sh --foreground             -> don't background it, show the log here
#   ./jmc-open.sh --where                  -> open nothing, print which JDK would be used
#
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

JMC="$TOOLS/jmc"
MEMORY=""; JDKSEL=""; CLEAN=0; FOREGROUND=0; WHERE=0; FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --memory)     MEMORY="${2:?example: --memory 8g}"; shift ;;
    --jdk)        JDKSEL="${2:?example: --jdk /usr/lib/jvm/java-21}"; shift ;;
    --clean)      CLEAN=1 ;;
    --foreground) FOREGROUND=1 ;;
    --where)      WHERE=1 ;;
    -h|--help)    sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            FILE="$1" ;;
  esac
  shift
done

# ------------------------------------------------------------------ is JMC there
if [ ! -x "$JMC/jmc" ]; then
  c_err "JMC not found: $JMC/jmc"
  echo "   Unpack the package first:   ./scripts/00-setup.sh" >&2
  exit 1
fi

# ------------------------------------------------------- choose the JDK to run on
if [ -n "$JDKSEL" ]; then
  JAVA="$JDKSEL/bin/java"; [ -x "$JAVA" ] || JAVA="$JDKSEL"
  if [ ! -x "$JAVA" ]; then c_err "no java at the path given to --jdk: $JDKSEL"; exit 1; fi
  VER=$(java_version "$JAVA" || echo 0)
  if [ "${VER:-0}" -lt 17 ]; then
    c_err "--jdk points at Java $VER - JMC needs at least 17."; exit 1
  fi
else
  JDKHOME=$(find_jdk 17) || {
    c_err "No Java 17+ found. JMC cannot start."
    echo "   Java versions visible on this system:" >&2
    list_jdks >&2
    echo >&2
    echo "   The bundled JDK 21 may not be unpacked yet:  ./scripts/00-setup.sh" >&2
    echo "   If you would rather stay in the terminal, you don't need JMC at all:" >&2
    echo "     ./scripts/jfr-summary.sh <recording.jfr>" >&2
    exit 1
  }
  JAVA="$JDKHOME/bin/java"
  VER=$(java_version "$JAVA" || echo "?")
fi

if [ "$WHERE" = "1" ]; then
  echo "JMC          : $JMC/jmc"
  echo "will run with: $JAVA   (Java $VER)"
  echo "on this system:"; list_jdks
  exit 0
fi

# --------------------------------------------------------------- workspace
# We keep it under PERF_OUT rather than the default ~/.jmc so that all output
# lives in one place and removing it is a single directory delete.
WS="${JMC_WORKSPACE:-$PERF_OUT/jmc-workspace}"
[ "$CLEAN" = "1" ] && { c_info "deleting workspace: $WS"; rm -rf "$WS"; }
mkdir -p "$WS" "$PERF_OUT/tmp"

# Seed Eclipse preferences so the first launch comes up sensibly configured.
# The critical one is the p2 update check: with no internet JMC tries to reach
# the update site on every start and waits for the timeout.
SETTINGS="$WS/.metadata/.plugins/org.eclipse.core.runtime/.settings"
if [ ! -d "$SETTINGS" ]; then
  mkdir -p "$SETTINGS"
  printf '%s\n' 'eclipse.preferences.version=1' 'enabled=false' \
    > "$SETTINGS/org.eclipse.equinox.p2.ui.sdk.scheduler.prefs"   # no automatic update check
  printf '%s\n' 'eclipse.preferences.version=1' 'SHOW_WORKSPACE_SELECTION_DIALOG=false' \
    > "$SETTINGS/org.eclipse.ui.ide.prefs"                        # no workspace picker
  printf '%s\n' 'eclipse.preferences.version=1' 'showIntro=false' \
    > "$SETTINGS/org.eclipse.ui.prefs"                            # no welcome screen
  c_info "workspace prepared: $WS  (automatic update check disabled)"
fi

# ------------------------------------------------------------------- display
if ! has_display; then display_help; exit 1; fi

# ----------------------------------------------------------------- launch
ARGS=( -data "$WS" -vm "$JAVA" )
if [ -n "$FILE" ]; then
  if [ ! -f "$FILE" ]; then c_err "no such file: $FILE"; exit 1; fi
  FULL=$(readlink -f "$FILE")
  # JMC treats command line arguments as COMMANDS; the one that opens a file is 'open'.
  ARGS+=( open "$FULL" )
  c_info "file to open: $FULL"
fi
VMARGS=( -Djava.io.tmpdir="$PERF_OUT/tmp" )
[ -n "$MEMORY" ] && VMARGS+=( "-Xmx$MEMORY" )
# jmc.ini contains --launcher.appendVmargs, so the -vmargs given here do NOT
# replace the ones in the ini - they are added to them.
ARGS+=( -vmargs "${VMARGS[@]}" )

c_info "starting JMC - Java $VER ($JAVA)"
LOG="$PERF_OUT/jmc-last-run.log"
if [ "$FOREGROUND" = "1" ]; then
  "$JMC/jmc" "${ARGS[@]}" 2>&1 | tee "$LOG"
  exit "${PIPESTATUS[0]}"
fi

"$JMC/jmc" "${ARGS[@]}" > "$LOG" 2>&1 &
PID=$!
sleep 3
if ! kill -0 "$PID" 2>/dev/null; then
  wait "$PID"; RC=$?
  c_err "JMC did not start (exit code $RC). Log: $LOG"
  echo "--- end of log ---" >&2; tail -20 "$LOG" >&2
  if grep -qi 'not suitable for this product' "$LOG" 2>/dev/null; then
    echo >&2
    c_warn "The classic JDK version error. If this happens even though -vm passed Java $VER,"
    echo "   jmc.ini may be damaged:  ./scripts/00-setup.sh --reset" >&2
  fi
  exit "$RC"
fi
echo "   JMC is running in the background (pid $PID). Log: $LOG"
cat <<'DONE'

   Read this first: the "Automated Analysis Results" tab of the recording you opened.
   It scores and ranks every problem it finds. Then, in order:
     Method Profiling  ->  Memory / TLAB Allocations  ->  Garbage Collections  ->  Lock Instances
DONE
