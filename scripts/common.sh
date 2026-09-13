# common.sh - helpers shared by the GUI launchers.  Meant to be 'source'd.
#
# All this file holds: finding a JDK, reading its version, and shared output.
# Not meant to be executed on its own.

_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROFILING_HOME="${PROFILING_HOME:-$_COMMON}"
export TOOLS="${TOOLS:-$PROFILING_HOME/tools}"
export PERF_OUT="${PERF_OUT:-$HOME/perf-out}"

if [ -t 1 ]; then CB=$'\033[1m'; CR=$'\033[31m'; CY=$'\033[33m'; CG=$'\033[32m'; CC=$'\033[36m'; CZ=$'\033[0m'
else CB=""; CR=""; CY=""; CG=""; CC=""; CZ=""; fi
c_info() { printf '>> %s\n' "$*"; }
c_warn() { printf '%s!! %s%s\n' "$CY" "$*" "$CZ" >&2; }
c_err()  { printf '%sERROR: %s%s\n' "$CR" "$*" "$CZ" >&2; }

# Extracts the MAJOR version number from `java -version` output.
#   "1.8.0_412" -> 8      "11.0.23" -> 11      "21.0.12" -> 21
java_version() { # java_version <java-executable>
  local j="$1" v
  [ -x "$j" ] || return 1
  # If JAVA_TOOL_OPTIONS/_JAVA_OPTIONS is set, java prints "Picked up ..." lines
  # first; the version line comes after them.
  v=$("$j" -version 2>&1 | grep -v '^Picked up ' | sed -n 's/.*version "\([0-9._]*\).*/\1/p' | head -1)
  [ -n "$v" ] || return 1
  case "$v" in
    1.*) echo "$v" | cut -d. -f2 ;;
    *)   echo "$v" | cut -d. -f1 ;;
  esac
}

# Finds a JDK of at least <min> major version and prints its JAVA_HOME.
# Order: bundled JDK 21 -> JAVA_HOME -> java on PATH -> /usr/lib/jvm/*
find_jdk() { # find_jdk <min-major-version>
  local min="$1" cand v
  for cand in "$TOOLS/jdk21/bin/java" "${JAVA_HOME:-/nonexistent}/bin/java" \
              "$(command -v java 2>/dev/null || echo /nonexistent)"; do
    [ -x "$cand" ] || continue
    v=$(java_version "$cand") || continue
    if [ "${v:-0}" -ge "$min" ] 2>/dev/null; then dirname "$(dirname "$cand")"; return 0; fi
  done
  for cand in /usr/lib/jvm/*/bin/java /usr/java/*/bin/java /opt/*/bin/java; do
    [ -x "$cand" ] || continue
    v=$(java_version "$cand") || continue
    if [ "${v:-0}" -ge "$min" ] 2>/dev/null; then dirname "$(dirname "$cand")"; return 0; fi
  done
  return 1
}

# Which java binaries exist and at what version - for showing the user.
list_jdks() {
  local cand v seen=""
  for cand in "$TOOLS/jdk21/bin/java" "${JAVA_HOME:-/nonexistent}/bin/java" \
              "$(command -v java 2>/dev/null || echo /nonexistent)" \
              /usr/lib/jvm/*/bin/java /usr/java/*/bin/java; do
    [ -x "$cand" ] || continue
    local real; real=$(readlink -f "$cand")
    case "$seen" in *"|$real|"*) continue ;; esac
    seen="$seen|$real|"
    v=$(java_version "$cand" 2>/dev/null || echo "?")
    printf '    Java %-4s %s\n' "${v:-?}" "$real"
  done
}

# Is there a display? Don't launch a GUI tool blind and hand back a cryptic error.
has_display() {
  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

display_help() {
  cat >&2 <<'MSG'
!! DISPLAY is not set - no graphical display available.
   On a server you have two options:

   1) Connect with X forwarding:     ssh -X user@server
      (xauth must be installed on the server; X11Forwarding yes in sshd_config)

   2) Better: copy the file to your workstation and open it there.
      scp server:~/perf-out/recording.jfr .
      If you want to stay in the terminal you don't need a GUI at all:
      ./scripts/jfr-summary.sh <recording.jfr>      ./scripts/diagnose.sh <pid>
MSG
}

# ------------------------------------------------------------------ pid + args
# Resolves a pid or a process-name to a REAL JVM pid.
# CAREFUL: a plain 'pgrep -f <name>' also matches the command line of the script
# you are running right now (it contains <name> too) and things like
# "tail -f log | grep <name>". So every candidate is verified to be a JVM.
resolve_pid() { # resolve_pid <pid|process-name>
  local t="$1" p c
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    [ -d "/proc/$t" ] || { c_err "pid $t is not running"; return 1; }
    echo "$t"; return 0
  fi
  for p in $(pgrep -f "$t" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    [ "$p" = "$PPID" ] && continue
    c=$(cat "/proc/$p/comm" 2>/dev/null) || continue
    case "$c" in java|jsvc|*java*) echo "$p"; return 0 ;; esac
    case "$(readlink -f "/proc/$p/exe" 2>/dev/null)" in */bin/java) echo "$p"; return 0 ;; esac
  done
  c_err "no running Java process matches '$t'"
  return 1
}

# Accepts a duration either positionally or as --duration N, and rejects
# anything that is not a plain number - otherwise asprof silently profiles
# for 0 seconds and you get an empty flame graph.
check_duration() { # check_duration <value>
  case "${1:-}" in
    ''|*[!0-9]*) c_err "duration must be a whole number of seconds, got: '${1:-}'"; return 1 ;;
  esac
  [ "$1" -ge 1 ] || { c_err "duration must be at least 1 second"; return 1; }
  echo "$1"
}
