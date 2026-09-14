#!/usr/bin/env bash
#
# diagnose.sh - Full diagnosis of a running Java process. One command, terminal only.
#
# Usage:
#   ./diagnose.sh <pid|process-name>   -> full diagnosis (~90 s, profiling included)
#   ./diagnose.sh --list               -> list the running Java processes
#
# Options:
#   --quick              No profiling, instant metrics only (~20 s)
#   --full               + wall-clock and lock profile (where threads WAIT)
#   --duration N         Profiling duration in seconds (default 60)
#   --deep               + heap dump + MAT headless leak report (HEAVY, STW pause)
#   --package com.acme   Match hot spots against YOUR code
#   --output DIR         Output directory (default $PERF_OUT/diag-<pid>-<time>)
#   --threshold strict|normal|loose   Finding thresholds (default normal)
#   --compare DIR        Compare against an earlier diagnosis (did the fix help?)
#   --json               Also write summary.json (for monitoring/automation)
#   --no-color           Do not emit ANSI colour codes
#
# Exit code:  0 = clean   1 = warnings   2 = critical findings   3 = could not run
# (so it can be used inside CI/cron.)
#
# Output: $PERF_OUT/diag-<pid>-<time>/   (default $HOME/perf-out)
# Writes nothing to the system. No root needed - just be the same user as the JVM.
#
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh" >/dev/null 2>&1 || {
  PERF_OUT="${PERF_OUT:-$HOME/perf-out}"; mkdir -p "$PERF_OUT"; TOOLS=""; ASPROF=""
}
PROFILING_HOME="${PROFILING_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ------------------------------------------------------------------ arguments
# The help text is generated from this file's own header comment - single source.
usage() { sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; }

TARGET=""; DURATION=60; QUICK=0; DEEP=0; FULL=0; PKG=""; OUTSEL=""
THRESH="normal"; JSON=0; NOCOLOR=0; COMPARE=""; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick)       QUICK=1 ;;
    --full)         FULL=1 ;;
    --deep)       DEEP=1 ;;
    --list)       LIST=1 ;;
    --json)        JSON=1 ;;
    --no-color)     NOCOLOR=1 ;;
    --duration)  DURATION="${2:?--duration needs a number of seconds}"; shift ;;
    --package)   PKG="${2:?--package example: com.acme}"; shift ;;
    --output)    OUTSEL="${2:?--output needs a directory}"; shift ;;
    --threshold) THRESH="${2:?--threshold: strict|normal|loose}"; shift ;;
    --compare)   COMPARE="${2:?--compare needs the directory of an earlier run}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "unknown option: $1"; echo; usage; exit 3 ;;
    *)             TARGET="$1" ;;
  esac
  shift
done

case "$DURATION" in ''|*[!0-9]*) echo "--duration must be a number: $DURATION"; exit 3 ;; esac
[ "$DURATION" -lt 5 ] && DURATION=5

# -------------------------------------------------------------------- colours
if [ -t 1 ] && [ "$NOCOLOR" = "0" ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; C=$'\033[36m'; M=$'\033[35m'; Z=$'\033[0m'
else B=""; R=""; Y=""; G=""; C=""; M=""; Z=""; fi

# ----------------------------------------------------- running Java processes
# 'jps' is not always present (could be a JRE), so we scan /proc as well.
list_java_processes() {
  printf '%s%-8s %-9s %-7s %s%s\n' "$B" "PID" "RSS(MB)" "UPTIME" "COMMAND" "$Z"
  local p cmd rss et
  for p in /proc/[0-9]*; do
    p="${p#/proc/}"
    [ -r "/proc/$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
      *java\ *|*/java\ *|*java) : ;;
      *) continue ;;
    esac
    case "$cmd" in *diagnose.sh*) continue ;; esac
    rss=$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$p/status" 2>/dev/null)
    et=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
    printf '%-8s %-9s %-7s %s\n' "$p" "${rss:-?}" "${et:-?}" "$(echo "$cmd" | cut -c1-90)"
  done
}
if [ "$LIST" = "1" ]; then list_java_processes; exit 0; fi

if [ -z "$TARGET" ]; then
  usage
  echo
  echo "${B}Running Java processes:${Z}"
  list_java_processes
  exit 3
fi

# ---------------------------------------------------------------- target pid
# Only accept REAL JVMs as candidates. When you run 'pgrep -f MyApp', diagnose.sh's
# OWN command line contains that text too, so it would find itself; processes like
# "tail -f log | grep MyApp" match as well. So we verify every candidate really is
# a java process.
is_jvm() { # is_jvm <pid>
  local p="$1" c
  [ "$p" = "$$" ] && return 1
  [ "$p" = "$PPID" ] && return 1
  [ -r "/proc/$p/comm" ] || return 1
  c=$(cat "/proc/$p/comm" 2>/dev/null)
  case "$c" in java|jsvc|*java*) return 0 ;; esac
  # comm is truncated at 15 chars, so check the exe path too
  case "$(readlink -f "/proc/$p/exe" 2>/dev/null)" in */bin/java) return 0 ;; esac
  return 1
}

PID="$TARGET"
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  CANDIDATES=$(for p in $(pgrep -f "$TARGET" 2>/dev/null); do is_jvm "$p" && echo "$p"; done | head -20)
  N_CAND=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)
  PID=$(printf '%s\n' "$CANDIDATES" | head -1)
  if [ "${N_CAND:-0}" -gt 1 ]; then
    echo "${Y}'$TARGET' matched ${N_CAND} processes, picked the first (pid $PID).${Z}"
    echo "If that is wrong, pass the pid directly. Matches:"
    for p in $CANDIDATES; do
      printf '  %-8s %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)"
    done
    echo
  fi
fi
if [ -z "${PID:-}" ]; then
  echo "No running Java process matches '$TARGET'."
  echo
  list_java_processes
  exit 3
fi
[ -d "/proc/$PID" ] || { echo "pid $PID is not running"; exit 3; }

# --------------------------------------------- find the process's OWN JDK
# To avoid version mismatches we take the tools from the target JVM's own bin/
# directory (a JDK 11 target gets JDK 11's jcmd). /proc/<pid>/exe tells us where.
JBIN=""
if [ -r "/proc/$PID/exe" ]; then
  JEXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)
  [ -n "$JEXE" ] && JBIN=$(dirname "$JEXE")
fi
pick() { local t="$1"
  [ -n "$JBIN" ] && [ -x "$JBIN/$t" ] && { echo "$JBIN/$t"; return; }
  command -v "$t" 2>/dev/null && return
  [ -x "$TOOLS/jdk21/bin/$t" ] && { echo "$TOOLS/jdk21/bin/$t"; return; }
  echo ""
}
JCMD=$(pick jcmd); JSTAT=$(pick jstat)
if [ -z "$JCMD" ]; then
  cat <<SON
jcmd not found - cannot attach to the target JVM.

Check these in order:
  1) Is the target a JRE?  jcmd ships with the JDK: java-11-openjdk-devel must be installed.
  2) Are you the same user?  process owner: $(stat -c %U "/proc/$PID" 2>/dev/null), you: $(id -un)
  3) ptrace restriction:  cat /proc/sys/kernel/yama/ptrace_scope   (1 blocks attaching from another user)
SON
  exit 3
fi

# If an earlier run was cut short (machine went down, session dropped), a recording
# we opened may still be hanging around on the target JVM. An open recording burns
# both disk and overhead for nothing, so we clean up before starting.
# Likewise a half-finished async-profiler session prevents a new one from starting.
if [ -n "${ASPROF:-}" ] && [ -x "${ASPROF:-/nonexistent}" ]; then
  if "$ASPROF" status "$PID" 2>/dev/null | grep -qi 'is running'; then
    echo "an async-profiler session is running on the target, stopping it..."
    "$ASPROF" stop "$PID" >/dev/null 2>&1 || true
  fi
fi

STALE_REC=$("$JCMD" "$PID" JFR.check 2>/dev/null | grep -oE 'name=diag_[0-9]+' | cut -d= -f2)
if [ -n "${STALE_REC:-}" ]; then
  for k in $STALE_REC; do
    echo "stopping a JFR recording left over from an earlier run: $k"
    "$JCMD" "$PID" JFR.stop name="$k" >/dev/null 2>&1 || true
  done
fi

OUT="${OUTSEL:-$PERF_OUT/diag-$PID-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT" || { echo "could not create output directory: $OUT"; exit 3; }

# ---------------------------------------------------------------- safety net
# On Ctrl-C or an error, stop the JFR recording WE started and detach asprof.
# Without this we would leave a recording running in production.
JFR_NAME="diag_$$"
JFR_STARTED=0
ASPROF_PID=""
# Cleanup works by NAME, not by a flag. The recording name contains $$ (the main
# process's pid) and bash keeps $$ unchanged in subshells, so whichever process runs
# this can still find and stop "our" recording. If it already stopped, the command
# just fails quietly - no harm done.
#
# The same applies to asprof: killing the asprof PROCESS does NOT close the profiling
# session inside the target JVM - the agent keeps running in there, so 'asprof stop'
# is needed as well.
cleanup() {
  local rc=$?
  "$JCMD" "$PID" JFR.stop name="$JFR_NAME" >/dev/null 2>&1 || true
  JFR_STARTED=0
  [ -n "${ASPROF_PID:-}" ] && kill "$ASPROF_PID" 2>/dev/null
  ASPROF_PID=""
  if [ -n "${ASPROF:-}" ] && [ -x "${ASPROF:-/nonexistent}" ]; then
    "$ASPROF" stop "$PID" >/dev/null 2>&1 || true
  fi
  rm -f "$OUT"/.*.tmp 2>/dev/null || true
  exit $rc
}
trap 'echo; echo "${Y}interrupted - stopping the recordings on the target JVM...${Z}"; cleanup' INT TERM
trap 'cleanup' EXIT

# =================================================================== HELPERS
heading() { printf '\n%s%s %s %s\n' "$B$C" "───────" "$1" "$Z"; }
kv()     { printf '  %-34s %s\n' "$1" "$2"; }
alt()    { printf '    %-32s %s\n' "$1" "$2"; }

# Counting with grep -c. CAREFUL: "$(grep -c X f || echo 0)" IS WRONG - with no
# match grep prints "0" AND returns 1, so the value becomes "0\n0" and every numeric
# comparison blows up. The correct form falls back only when the output is empty:
count() { local n; n=$(grep -c "$@" 2>/dev/null); case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }
# Turns a non-numeric value into 0 (so empty fields do not break the arithmetic).
num()  { case "${1:-}" in ''|*[!0-9.]*) echo 0 ;; *) echo "$1" ;; esac; }
# a > b ?  (works with decimals)
gt() { awk -v a="$(num "$1")" -v b="$2" 'BEGIN{print (a+0 > b+0) ? 1 : 0}'; }
pct()  { awk -v a="$(num "$1")" -v b="$(num "$2")" 'BEGIN{ if(b+0==0){print "0"} else {printf "%.1f", a/b*100} }'; }
mb()    { awk -v k="$(num "$1")" 'BEGIN{printf "%.0f", k/1024}'; }          # KB -> MB
bmb()   { awk -v b="$(num "$1")" 'BEGIN{printf "%.0f", b/1048576}'; }       # byte -> MB

# ------------------------------------------------------------ threshold profile
# The same script has to serve a relaxed batch job and a strict latency service,
# so every threshold is configured in one place.
case "$THRESH" in
  strict) T_GC_CRIT=5;   T_GC_WARN=2;  T_OLD_CRIT=85; T_OLD_WARN=70
          T_ALLOC=200;    T_THREAD_CRIT=1000; T_THREAD_WARN=300; T_BLOCKED=5;  T_FD=70; T_CC=85 ;;
  loose)  T_GC_CRIT=20; T_GC_WARN=12; T_OLD_CRIT=95; T_OLD_WARN=85
          T_ALLOC=1500;   T_THREAD_CRIT=4000; T_THREAD_WARN=1500; T_BLOCKED=25; T_FD=90; T_CC=95 ;;
  *)      THRESH="normal"
          T_GC_CRIT=10; T_GC_WARN=5;  T_OLD_CRIT=90; T_OLD_WARN=75
          T_ALLOC=500;    T_THREAD_CRIT=2000; T_THREAD_WARN=500; T_BLOCKED=10; T_FD=80; T_CC=90 ;;
esac

# ------------------------------------------------------------ finding records
FIND_N=0; CRIT=0; WARN=0
FIND_JSON="$OUT/.findings.jsonl"; : > "$FIND_JSON"
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }
finding() { # finding <CRIT|WARN|INFO> <title> <explanation> <what-to-do>
  local sev="$1" ttl="$2" expl="$3" fix="$4" col="$G"
  case "$sev" in
    CRIT) col="$R"; CRIT=$((CRIT+1)) ;;
    WARN) col="$Y"; WARN=$((WARN+1)) ;;
  esac
  FIND_N=$((FIND_N+1))
  printf '\n%s[%s]%s %s%s%s\n' "$col" "$sev" "$Z" "$B" "$ttl" "$Z"
  printf '        %s\n' "$expl"
  [ -n "$fix" ] && printf '        %s->%s %s\n' "$C" "$Z" "$fix"
  printf '{"level":"%s","title":"%s","explanation":"%s","fix":"%s"}\n' \
    "$sev" "$(json_escape "$ttl")" "$(json_escape "$expl")" "$(json_escape "$fix")" >> "$FIND_JSON"
}

# Metrics are gathered into one file for --compare and --json.
METRICS="$OUT/metrics.env"; : > "$METRICS"
m() { # m <name> <value>
  printf '%s=%s\n' "$1" "${2:-}" >> "$METRICS"
}

# ==================================================== ANTI-PATTERN DICTIONARY
# Given a stack frame (or a type name), returns "likely cause|suggested fix".
# ORDER MATTERS: specific patterns must come BEFORE general ones. For example
# String.valueOf sits above so it does not fall into the generic *valueOf*
# pattern and get mislabelled as "boxing".
cause_fix() {
  case "$1" in
    # ---- string ----
    *String.valueOf*|*String.join*|*String.split*)
      echo "String production on a hot path (valueOf/join/split allocate every call)|Use indexOf/substring instead of split; append directly instead of valueOf; cache the result" ;;
    *StringBuilder.append*|*AbstractStringBuilder*|*String.concat*|*StringConcatHelper*|*makeConcat*)
      echo "String concatenation in a loop; a new array is copied on every step|Create the StringBuilder OUTSIDE the loop and give it a capacity up front: new StringBuilder(estimatedLength)" ;;
    *String.format*|*Formatter*)
      echo "String.format on a hot path; it parses the format string on every call|Use manual concat or StringBuilder. For logging, switch to the parameterised form" ;;
    *String.substring*|*String.replace*|*String.toLowerCase*|*String.toUpperCase*|*String.trim*)
      echo "String-copying operations inside a hot loop|Compute the result outside the loop; for comparisons use equalsIgnoreCase/regionMatches" ;;
    # ---- regex ----
    *Pattern.compile*)
      echo "The regex is recompiled ON EVERY CALL|Hoist it: static final Pattern PAT = Pattern.compile(...) and reuse it" ;;
    *regex.Matcher*|*regex.Pattern*)
      echo "Regex matching on a hot path|For simple checks indexOf/startsWith/endsWith are many times faster than a regex" ;;
    # ---- collections ----
    *HashMap.resize*|*HashMap.putVal*|*HashMap.put*|*HashMap.treeifyBin*|*ConcurrentHashMap.transfer*)
      echo "The HashMap keeps growing and rehashing|Give it an initial capacity: new HashMap<>((int)(expected/0.75f)+1)" ;;
    *HashMap.get*|*HashMap.hash*|*.hashCode*|*.equals*)
      echo "Map lookups on a hot path; hashCode/equals run on every access|Simplify the key (int/enum instead of String); cache an expensive hashCode in a field" ;;
    *Integer.getChars*|*Long.getChars*|*Integer.toString*|*Long.toString*|*NumberFormat*)
      echo "Number -> String conversion on a hot path|Move the conversion out of the hot loop; for logs/JSON pass the number itself instead of converting first" ;;
    *ArrayList.grow*|*ArrayList.add*|*Arrays.copyOf*|*ensureCapacity*)
      echo "The list/array keeps growing, and every growth copies the whole thing|Pre-size it: new ArrayList<>(expectedSize)" ;;
    *LinkedList*)
      echo "LinkedList access is O(n) and it is not cache friendly|ArrayList/ArrayDeque is faster in almost every case" ;;
    *TreeMap*|*TreeSet*)
      echo "Sorted collections cost O(log n) plus a comparator call per operation|If you do not actually need the ordering, use HashMap/HashSet" ;;
    *Collections.sort*|*Arrays.sort*|*.sort*)
      echo "Sorting on a hot path|Move the sort out of the loop, or keep the data sorted already (TreeMap/priority queue)" ;;
    *Collections.unmodifiable*|*ImmutableList*|*List.copyOf*)
      echo "A defensive copy/wrapper is created on every call|Create the wrapper once and keep it in a field" ;;
    # ---- boxing ----
    *Integer.valueOf*|*Long.valueOf*|*Double.valueOf*|*Float.valueOf*|*Boolean.valueOf*|*.intValue*|*.longValue*|*.doubleValue*|*autobox*)
      echo "Boxing/unboxing; an object is created for every value|Use primitives: int/long, IntStream/LongStream, LongAdder for counters" ;;
    *Number.*|*BigDecimal*|*BigInteger*)
      echo "BigDecimal/BigInteger arithmetic on a hot path; every operation is a new object|For money use long cents, otherwise double; do the scaling once" ;;
    # ---- date/time ----
    *SimpleDateFormat*|*text.DateFormat*|*Calendar*|*java.util.Date*)
      echo "SimpleDateFormat is both slow and not thread-safe|Move to java.time.format.DateTimeFormatter (immutable, safe to share as static final)" ;;
    *java.time.format*|*DateTimeFormatter*)
      echo "Date formatting on a hot path|Make the formatter static final; do not format the same value repeatedly, cache the result" ;;
    # ---- exceptions / reflection ----
    *fillInStackTrace*|*Throwable.*init*|*Throwable.getStackTrace*)
      echo "Exception construction cost; filling in the stack trace is expensive|Do not use exceptions for control flow. If thrown often, use a custom exception with writableStackTrace=false" ;;
    *Class.forName*|*java.lang.reflect*|*Method.invoke*|*Field.get*|*getDeclaredMethod*)
      echo "Reflection on a hot path|Cache the result (Method/Field/Class); prefer a MethodHandle or a direct call where possible" ;;
    *MethodHandle*|*LambdaMetafactory*|*invokedynamic*)
      echo "Lambda/MethodHandle linkage cost (usually the first call)|Stop creating lambdas inside the hot loop; keep the lambda in a field" ;;
    *Proxy*|*cglib*|*bytebuddy*|*javassist*)
      echo "Dynamic proxy / bytecode generation|Take the proxy layer off the hot path; cache the generated class (it inflates Metaspace too)" ;;
    # ---- logging / serialization ----
    *Logger*|*log4j*|*slf4j*|*logback*|*Log4j*|*LogRecord*)
      echo "Logging is burning CPU; the message is probably built BEFORE the level check|Switch to the parameterised form log.debug(\"x={}\", o); consider an async appender" ;;
    *ObjectOutputStream*|*ObjectInputStream*|*Serializ*|*readObject*|*writeObject*)
      echo "Java serialization is expensive and produces bulky output|Reduce the field count, use transient; move to a faster format if you can" ;;
    *jackson*|*ObjectMapper*|*JsonParser*|*JsonGenerator*|*gson*)
      echo "JSON serialization on a hot path|Make ObjectMapper static final (it is expensive to build); drop unused fields with @JsonIgnore; consider the streaming API" ;;
    *xml*|*XML*|*DocumentBuilder*|*SAXParser*|*Transformer*)
      echo "XML parsing/generation on a hot path|Reuse the factory objects (thread-local); prefer streaming (SAX/StAX) over DOM" ;;
    # ---- IO / network ----
    *Charset*|*getBytes*|*StringCoding*|*String.*init*byte*|*CharsetEncoder*|*CharsetDecoder*)
      echo "Character encoding conversion (String <-> byte[])|Remove needless conversions, use the StandardCharsets.UTF_8 constant (not a name lookup)" ;;
    *BufferedInputStream*|*FileInputStream.read*|*FileOutputStream.write*|*RandomAccessFile*|*Files.read*|*Files.write*)
      echo "Unbuffered or small-chunk file IO|Wrap it in BufferedInputStream/BufferedReader; use an 8-64 KB buffer" ;;
    *SocketInputStream*|*SocketOutputStream*|*java.net*|*NioSocket*|*SocketChannel*|*EPoll*)
      echo "Network IO wait|This may be waiting rather than CPU: confirm with a wall profile (--full). Check timeout and connection pool settings" ;;
    *jdbc*|*JDBC*|*PreparedStatement*|*ResultSet*|*Connection.*)
      echo "Database calls on a hot path|Look for N+1 queries, use batching, measure the connection pool size; the biggest win is usually in the SQL" ;;
    *zip.Deflater*|*zip.Inflater*|*GZIP*|*Compress*)
      echo "Compression is burning CPU|Lower the compression level, or question whether it is needed at all" ;;
    *MessageDigest*|*Cipher*|*crypto*|*security.*|*SSL*|*TLS*)
      echo "Cryptography on a hot path|Reuse the MessageDigest/Cipher objects (thread-local); revisit the algorithm choice" ;;
    # ---- concurrency ----
    *Object.wait*|*Unsafe.park*|*LockSupport.park*|*ReentrantLock*|*monitorenter*|*ConditionObject*|*Semaphore*)
      echo "Lock contention; threads are waiting instead of working|Take a lock profile with --full. Narrow the synchronized block, move to ConcurrentHashMap/LongAdder" ;;
    *ThreadLocal*)
      echo "ThreadLocal access/cleanup|Watch for ThreadLocal leaks on pooled threads; remember to call remove()" ;;
    *AtomicInteger*|*AtomicLong*|*compareAndSet*|*getAndAdd*)
      echo "Multi-core CAS contention (a race on the same cache line)|Under high contention use LongAdder/DoubleAdder - it scales through striped counters" ;;
    *ThreadPoolExecutor*|*ForkJoinPool*|*CompletableFuture*)
      echo "Pool management on a hot path|Measure the pool size: CPU-bound work needs roughly one thread per core; give IO-bound work its own pool" ;;
    # ---- streams / functional ----
    *stream.*|*Collectors*|*Spliterator*|*lambda*|*ReferencePipeline*)
      echo "Stream pipeline on a hot path; lambda and boxing overhead|In a VERY hot loop switch to a classic for. Only change it if the profiler says so" ;;
    *Optional*)
      echo "Optional wrapping on a hot path|A null check is cheaper in a hot loop; keep Optional at API boundaries" ;;
    # ---- GC / memory ----
    *System.gc*|*Runtime.gc*)
      echo "An explicit System.gc() call; it stops the whole application|Remove the call. If it comes from a library, use -XX:+DisableExplicitGC" ;;
    *Reference.*|*Finalizer*|*Cleaner*|*PhantomReference*|*WeakHashMap*)
      echo "Reference/finalizer processing overhead|Do not use finalize() (deprecated since Java 9); close deterministically with Cleaner or try-with-resources" ;;
    *DirectByteBuffer*|*ByteBuffer.allocateDirect*|*Unsafe.allocateMemory*)
      echo "Direct ByteBuffer allocation - this memory is OFF-HEAP and does not count against -Xmx|Pool and reuse the buffers; cap it with -XX:MaxDirectMemorySize" ;;
    *clone*|*System.arraycopy*)
      echo "Array/object copying|Remove unnecessary defensive copies; return a read-only view instead" ;;
    # ---- type names (allocation side) ----
    *byte\[\]*)   echo "Large byte[] allocations|Set up a buffer pool or reuse a fixed-size buffer" ;;
    *char\[\]*|*java.lang.String*) echo "Excessive String production|Reduce concat/format/substring calls, eliminate intermediate Strings" ;;
    *int\[\]*|*long\[\]*|*double\[\]*) echo "Frequent primitive array allocation|Allocate the array once outside the loop and reuse it" ;;
    *HashMap\$Node*|*HashMap\$Entry*|*ConcurrentHashMap\$Node*)
      echo "A great many map entries are being created|Review the map's size and lifetime; pre-size it" ;;
    *Object\[\]*) echo "Many array allocations (most likely collection growth)|Pre-size your collections" ;;
    *java.lang.Integer|*java.lang.Long|*java.lang.Double)
      echo "Boxed number objects|Switch to primitives; values outside -128..127 are not cached, so each one is a new object" ;;
    *) echo "|" ;;
  esac
}

# Reads jstat output BY COLUMN NAME (the column order can differ between versions)
jcol() { awk -v c="$2" -v r="$3" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} NR==r+1{ if (h[c]) print $h[c] }' "$1"; }

# ============================================================ REPORT BEGINS
# CAREFUL: the { } block below sits on the left side of a pipeline (| tee), so it
# runs IN A SUBSHELL - and bash resets traps to DEFAULT in a subshell. Without
# re-arming the trap here, Ctrl-C would run no cleanup at all and would leave an
# open JFR recording on the target JVM.
{
trap 'echo; echo "interrupted - stopping the recordings on the target JVM..."; cleanup' INT TERM
printf '%s╔════════════════════════════════════════════════════════════╗%s\n' "$B$C" "$Z"
printf '%s║  JAVA DIAGNOSTIC REPORT                                    ║%s\n' "$B$C" "$Z"
printf '%s╚════════════════════════════════════════════════════════════╝%s\n' "$B$C" "$Z"
kv "Time"   "$(date '+%Y-%m-%d %H:%M:%S %Z')"
kv "PID"    "$PID"
kv "Output" "$OUT"
kv "Mode"   "$([ "$QUICK" = 1 ] && echo 'quick (no profiling)' || echo "profile ${DURATION}s")$([ "$FULL" = 1 ] && echo ' + wall/lock')$([ "$DEEP" = 1 ] && echo ' + heap dump')   thresholds: $THRESH"

# -------------------------------------------------------------- 1. IDENTITY
heading "1. IDENTITY"
CMDLINE=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null | cut -c1-4000)
JVER=$("$JCMD" "$PID" VM.version 2>/dev/null | sed -n '2p')
UPTIME_S=$("$JCMD" "$PID" VM.uptime 2>/dev/null | sed -n '2p' | awk '{print $1}')
POWNER=$(stat -c %U "/proc/$PID" 2>/dev/null)
# Read up front: the -Xss line below multiplies by it, and section 2 re-reads it anyway.
NTHREAD=$(awk '/^Threads:/{print $2}' "/proc/$PID/status" 2>/dev/null)
kv "User"       "${POWNER:-?}   (you: $(id -un))"
kv "JVM"        "${JVER:-?}"
kv "Uptime"     "$(awk -v s="$(num "${UPTIME_S:-0}")" 'BEGIN{printf "%.1f hours (%.0f s)", s/3600, s}')"
kv "JDK bin"    "${JBIN:-PATH}"
echo "$CMDLINE" > "$OUT/cmdline.txt"
"$JCMD" "$PID" VM.flags -all > "$OUT/flags-all.txt" 2>/dev/null
"$JCMD" "$PID" VM.command_line > "$OUT/command-line.txt" 2>/dev/null
"$JCMD" "$PID" VM.system_properties > "$OUT/system-properties.txt" 2>/dev/null
FLAGS=$("$JCMD" "$PID" VM.flags 2>/dev/null | sed -n '2p')
echo "$FLAGS" > "$OUT/flags.txt"
printf '  %-34s %s\n' "Startup flags" ""
echo "$FLAGS" | tr ' ' '\n' | grep -v '^$' | sed 's/^/      /' | head -30
FLAG_N=$(echo "$FLAGS" | tr ' ' '\n' | grep -c . || true)
[ "${FLAG_N:-0}" -gt 30 ] && echo "      ... (${FLAG_N} flags in total, full list: $OUT/flags-all.txt)"

# Reads a single flag value out of the VM.flags -all output
flagval() { awk -v f="$1" '$2==f {print $4; exit}' "$OUT/flags-all.txt" 2>/dev/null; }
XMX=$(flagval MaxHeapSize); XMS=$(flagval InitialHeapSize); XSS=$(flagval ThreadStackSize)
MAXMETA=$(flagval MaxMetaspaceSize); CODECACHE=$(flagval ReservedCodeCacheSize)
MAXDIRECT=$(flagval MaxDirectMemorySize)
USE_G1=$(flagval UseG1GC); USE_PAR=$(flagval UseParallelGC); USE_SER=$(flagval UseSerialGC)
USE_Z=$(flagval UseZGC); USE_SHEN=$(flagval UseShenandoahGC)
HEAPDUMP_OOM=$(flagval HeapDumpOnOutOfMemoryError)
PRETOUCH=$(flagval AlwaysPreTouch); COMPOOPS=$(flagval UseCompressedOops)
CONTAINER=$(flagval UseContainerSupport); ACTIVEPROC=$(flagval ActiveProcessorCount)
DEBUGNSP=$(flagval DebugNonSafepoints); EXPLICITGC=$(flagval DisableExplicitGC)
GCNAME="?"
[ "${USE_SER:-false}" = "true" ]  && GCNAME="Serial"
[ "${USE_PAR:-false}" = "true" ]  && GCNAME="Parallel"
[ "${USE_G1:-false}" = "true" ]   && GCNAME="G1"
[ "${USE_Z:-false}" = "true" ]    && GCNAME="ZGC"
[ "${USE_SHEN:-false}" = "true" ] && GCNAME="Shenandoah"
kv "GC" "$GCNAME"
kv "Heap (Xms / Xmx)" "$(awk -v a="$(num "${XMS:-0}")" -v b="$(num "${XMX:-0}")" 'BEGIN{printf "%.0f MB / %.0f MB", a/1048576, b/1048576}')"
# CAREFUL: ThreadStackSize is in KB (not bytes) - no division here.
[ -n "${XSS:-}" ] && [ "$(num "${XSS:-0}")" -gt 0 ] 2>/dev/null && \
  kv "Thread stack (-Xss)" "$XSS KB   (x ${NTHREAD:-?} threads ~ $(( XSS * $(num "${NTHREAD:-0}") / 1024 )) MB of stack)"
m JVM "${JVER:-?}"; m GC "$GCNAME"; m XMX_MB "$(bmb "${XMX:-0}")"; m UPTIME_S "$(num "${UPTIME_S:-0}")"

# ------------------------------------------------------ 2. OPERATING SYSTEM
heading "2. OPERATING SYSTEM"
RSS_KB=$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null)
VSZ_KB=$(awk '/^VmSize:/{print $2}' "/proc/$PID/status" 2>/dev/null)
SWAP_KB=$(awk '/^VmSwap:/{print $2}' "/proc/$PID/status" 2>/dev/null)
NTHREAD=$(awk '/^Threads:/{print $2}' "/proc/$PID/status" 2>/dev/null)
CTX_V=$(awk '/^voluntary_ctxt_switches:/{print $2}' "/proc/$PID/status" 2>/dev/null)
CTX_N=$(awk '/^nonvoluntary_ctxt_switches:/{print $2}' "/proc/$PID/status" 2>/dev/null)
NPROC=$(nproc 2>/dev/null || echo 1)
CPUPCT=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')
FD_N=$(ls "/proc/$PID/fd" 2>/dev/null | wc -l)
FD_MAX=$(awk '/Max open files/{print $4}' "/proc/$PID/limits" 2>/dev/null)
MEM_TOT_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
kv "RSS (resident)"      "$(mb "$RSS_KB") MB   / machine $(mb "$MEM_TOT_KB") MB"
kv "Virtual (VSZ)"       "$(mb "$VSZ_KB") MB"
[ -n "${SWAP_KB:-}" ] && kv "Swap"  "$(mb "$SWAP_KB") MB"
kv "CPU"                 "${CPUPCT:-?} %   ($NPROC cores -> ceiling $((NPROC*100))%)"
kv "Threads"             "${NTHREAD:-?}"
kv "Open files (FD)"     "${FD_N:-?} / ${FD_MAX:-?}"
kv "Context switches"    "voluntary ${CTX_V:-?} / involuntary ${CTX_N:-?}"
if [ -r "/proc/$PID/io" ]; then
  IO_R=$(awk '/^read_bytes:/{print $2}' "/proc/$PID/io" 2>/dev/null)
  IO_W=$(awk '/^write_bytes:/{print $2}' "/proc/$PID/io" 2>/dev/null)
  [ -n "${IO_R:-}" ] && kv "Disk IO (total)" "read $(bmb "$IO_R") MB / written $(bmb "$IO_W") MB"
fi
m RSS_MB "$(mb "$RSS_KB")"; m THREAD "$(num "${NTHREAD:-0}")"; m CPU_PCT "$(num "${CPUPCT:-0}")"
m FD "$(num "${FD_N:-0}")"; m SWAP_MB "$(mb "${SWAP_KB:-0}")"

# --- cgroup (container) limits and throttling: both v2 and v1 ---
CGP=$(awk -F: '$1=="0"{print $3}' "/proc/$PID/cgroup" 2>/dev/null)
THROTTLED=""; CPUMAX=""; MEMMAX=""; CG_VER=""
if [ -n "${CGP:-}" ] && [ -d "/sys/fs/cgroup${CGP}" ]; then
  CGDIR="/sys/fs/cgroup${CGP}"; CG_VER="v2"
  [ -r "$CGDIR/cpu.max" ]    && CPUMAX=$(cat "$CGDIR/cpu.max" 2>/dev/null)
  [ -r "$CGDIR/memory.max" ] && MEMMAX=$(cat "$CGDIR/memory.max" 2>/dev/null)
  [ -r "$CGDIR/cpu.stat" ]   && { THROTTLED=$(awk '/nr_throttled/{print $2}' "$CGDIR/cpu.stat"); cp "$CGDIR/cpu.stat" "$OUT/cgroup-cpu.stat" 2>/dev/null; }
else
  # cgroup v1: a separate directory per controller
  CG1=$(awk -F: '$2 ~ /cpu,cpuacct|^cpu$/{print $3; exit}' "/proc/$PID/cgroup" 2>/dev/null)
  if [ -n "${CG1:-}" ] && [ -d "/sys/fs/cgroup/cpu,cpuacct${CG1}" ]; then
    CGDIR="/sys/fs/cgroup/cpu,cpuacct${CG1}"; CG_VER="v1"
    Q=$(cat "$CGDIR/cpu.cfs_quota_us" 2>/dev/null); P=$(cat "$CGDIR/cpu.cfs_period_us" 2>/dev/null)
    [ -n "${Q:-}" ] && [ "$Q" != "-1" ] && CPUMAX="$Q $P"
    THROTTLED=$(awk '/nr_throttled/{print $2}' "$CGDIR/cpu.stat" 2>/dev/null)
    MEMMAX=$(cat "/sys/fs/cgroup/memory${CG1}/memory.limit_in_bytes" 2>/dev/null)
  fi
fi
if [ -n "$CG_VER" ]; then
  kv "cgroup"            "$CG_VER"
  kv "cgroup cpu.max"    "${CPUMAX:-none}"
  kv "cgroup memory.max" "${MEMMAX:-none}"
  kv "cgroup throttle"   "${THROTTLED:-0} times"
  # Convert the cgroup CPU limit into a core count - JVM ergonomics uses this
  if [ -n "${CPUMAX:-}" ] && [ "$CPUMAX" != "max" ]; then
    CG_CORES=$(echo "$CPUMAX" | awk '{ if ($1=="max"||$1=="-1") print ""; else printf "%.2f", $1/$2 }')
    [ -n "$CG_CORES" ] && kv "cgroup CPU equivalent" "$CG_CORES cores   (nproc: $NPROC)"
  fi
fi
m THROTTLE "$(num "${THROTTLED:-0}")"

# ---------------------------------------------------------------- 3. MEMORY
heading "3. MEMORY"
"$JCMD" "$PID" GC.heap_info > "$OUT/heap-info.txt" 2>/dev/null
sed -n '2,12p' "$OUT/heap-info.txt" 2>/dev/null | sed 's/^/  /'
NMT=$("$JCMD" "$PID" VM.native_memory summary 2>/dev/null)
if echo "$NMT" | grep -q "Total:"; then
  echo "$NMT" > "$OUT/native-memory.txt"
  echo
  echo "  Native Memory Tracking (off-heap breakdown):"
  echo "$NMT" | grep -E "^-|Total:" | sed 's/^/    /' | head -18
else
  echo
  echo "  NMT is off. To break down off-heap memory, start the application"
  echo "  with -XX:NativeMemoryTracking=summary and then run:"
  echo "    jcmd $PID VM.native_memory summary"
fi

# -------------------------------------------------------------------- 4. GC
GCN=10
heading "4. GC  (${GCN}s sampling)"
if [ -n "$JSTAT" ]; then
  "$JSTAT" -gc "$PID" 1000 $GCN > "$OUT/jstat-gc.txt" 2>/dev/null
  # Capacity and usage must be read from the SAME row: in G1 regions move between
  # young and old, so dividing values from different rows yields ratios above 100%.
  EC=$(jcol "$OUT/jstat-gc.txt" EC $GCN);   OC=$(jcol "$OUT/jstat-gc.txt" OC $GCN)
  MC=$(jcol "$OUT/jstat-gc.txt" MC $GCN)
  EC0=$(jcol "$OUT/jstat-gc.txt" EC 1)
  EU0=$(jcol "$OUT/jstat-gc.txt" EU 1);    EU1=$(jcol "$OUT/jstat-gc.txt" EU $GCN)
  OU0=$(jcol "$OUT/jstat-gc.txt" OU 1);    OU1=$(jcol "$OUT/jstat-gc.txt" OU $GCN)
  MU1=$(jcol "$OUT/jstat-gc.txt" MU $GCN)
  YGC0=$(jcol "$OUT/jstat-gc.txt" YGC 1);  YGC1=$(jcol "$OUT/jstat-gc.txt" YGC $GCN)
  FGC0=$(jcol "$OUT/jstat-gc.txt" FGC 1);  FGC1=$(jcol "$OUT/jstat-gc.txt" FGC $GCN)
  GCT0=$(jcol "$OUT/jstat-gc.txt" GCT 1);  GCT1=$(jcol "$OUT/jstat-gc.txt" GCT $GCN)
  WALL=$((GCN-1))
  DGCT=$(awk -v a="$(num "${GCT1:-0}")" -v b="$(num "${GCT0:-0}")" 'BEGIN{printf "%.3f", a-b}')
  GC_LOAD=$(awk -v d="$DGCT" -v w="$WALL" 'BEGIN{ if(w==0){print 0}else{printf "%.1f", d/w*100} }')
  DYGC=$(( $(num "${YGC1:-0}") - $(num "${YGC0:-0}") ))
  DFGC=$(( $(num "${FGC1:-0}") - $(num "${FGC0:-0}") ))
  O_PCT=$(pct "${OU1:-0}" "${OC:-1}")
  # A percentage of committed metaspace is always ~90% (the JVM commits exactly what
  # it needs) - meaningless. The real risk is approaching MaxMetaspaceSize.
  META_MAX_KB=$(awk -v m="$(num "${MAXMETA:-0}")" 'BEGIN{printf "%.0f", m/1024}')
  if [ "$(num "$META_MAX_KB")" -gt 0 ] 2>/dev/null; then
    M_PCT=$(pct "${MU1:-0}" "$META_MAX_KB"); M_AGAINST="MaxMetaspaceSize"
  else
    M_PCT=""; M_AGAINST="unlimited"
  fi
  # Approximate allocation rate: (eden fills x eden size) + the change in eden usage
  ALLOC_MB=$(awk -v y="$DYGC" -v ec="$(num "${EC0:-0}")" -v a="$(num "${EU0:-0}")" -v b="$(num "${EU1:-0}")" -v w="$WALL" \
    'BEGIN{ t=(y*ec)+(b-a); if(t<0)t=0; if(w==0){print 0}else{printf "%.0f", t/1024/w} }')
  # Promotion rate into old gen: the key signal for telling a leak apart from "just a
  # lot of garbage". If old gen keeps growing while young GCs run, objects are surviving.
  PROMO_MB=$(awk -v a="$(num "${OU0:-0}")" -v b="$(num "${OU1:-0}")" -v w="$WALL" \
    'BEGIN{ d=b-a; if(d<0)d=0; if(w==0){print 0}else{printf "%.1f", d/1024/w} }')
  kv "GC load (pause / wall time)" "${GC_LOAD}%   (${DGCT}s of pause within ${WALL}s)"
  kv "Young GC"         "$DYGC times / ${WALL}s"
  kv "Full GC"          "$DFGC times / ${WALL}s"
  kv "Old gen usage"    "${O_PCT}%   ($(mb "${OU1:-0}") / $(mb "${OC:-0}") MB)"
  if [ -n "$M_PCT" ]; then
    kv "Metaspace"      "${M_PCT}% of max   ($(mb "${MU1:-0}") MB in use)"
  else
    kv "Metaspace"      "$(mb "${MU1:-0}") MB in use / $(mb "${MC:-0}") MB committed   (ceiling: $M_AGAINST)"
  fi
  kv "Allocation rate"  "~${ALLOC_MB} MB/s"
  kv "Promotion to old" "~${PROMO_MB} MB/s   (steadily climbing = leak candidate)"
  m GC_LOAD "$GC_LOAD"; m YGC "$DYGC"; m FGC "$DFGC"; m OLD_PCT "$O_PCT"
  m META_MB "$(mb "${MU1:-0}")"; m ALLOC_MBS "$ALLOC_MB"; m PROMO_MBS "$PROMO_MB"
else
  echo "  jstat not found - GC metrics skipped."
  echo "  (jstat ships with the JDK; a JRE-only target will not have it.)"
fi

# If GC logging is on, point it out - it can be visualised with gcviewer
GCLOG=$(grep -oE '\-Xlog:gc[^ ]*|\-Xloggc:[^ ]*' "$OUT/command-line.txt" 2>/dev/null | head -1)
[ -n "${GCLOG:-}" ] && kv "GC log" "$GCLOG"

# -------------------------------------------------------------- 5. THREADS
heading "5. THREADS"
for i in 1 2 3; do
  "$JCMD" "$PID" Thread.print > "$OUT/thread-dump-$i.txt" 2>/dev/null
  [ $i -lt 3 ] && sleep 1
done
TD="$OUT/thread-dump-3.txt"
DEADLOCK=$(count "Found one Java-level deadlock" "$TD")
echo "  State distribution:"
grep -o "java.lang.Thread.State: [A-Z_]*" "$TD" 2>/dev/null | awk '{print $2}' \
  | sort | uniq -c | sort -rn | sed 's/^/    /'
N_BLOCKED=$(count "java.lang.Thread.State: BLOCKED" "$TD")
N_WAITING=$(count "java.lang.Thread.State: WAITING" "$TD")
N_TIMED=$(count "java.lang.Thread.State: TIMED_WAITING" "$TD")
N_RUNNABLE=$(count "java.lang.Thread.State: RUNNABLE" "$TD")
N_TOTAL=$(count "java.lang.Thread.State:" "$TD")
[ "$N_TOTAL" -eq 0 ] && N_TOTAL=1

# Group thread pools by name: "http-nio-8080-exec-12" -> "http-nio-8080-exec-*"
echo
echo "  Thread groups (by name pattern):"
grep -oE '^"[^"]+"' "$TD" 2>/dev/null | tr -d '"' \
  | sed 's/[-_#]\?[0-9]\+$//; s/#$//' | sort | uniq -c | sort -rn | head -8 \
  | awk '{n=$1; $1=""; sub(/^ /,""); printf "    %-46s %s\n", $0"-*", n}'

# Threads stuck on the same stack = "the poor man's profiler"
echo
echo "  Threads sitting in the SAME method in all 3 dumps (possibly stuck):"
STUCK=$(for i in 1 2 3; do
  grep -A1 "java.lang.Thread.State: " "$OUT/thread-dump-$i.txt" 2>/dev/null \
    | grep -oE "^\s+at [a-zA-Z0-9_.$]+" | sed 's/^\s*at //'
done | sort | uniq -c | awk '$1>=3' | sort -rn | head -8)
if [ -n "$STUCK" ]; then echo "$STUCK" | sed 's/^/    /'; else echo "    (none - good news)"; fi
m BLOCKED "$N_BLOCKED"; m THREAD_TOTAL "$N_TOTAL"; m DEADLOCK "$DEADLOCK"

# ------------------------------------------------- 6. TOP CPU-EATING THREADS
heading "6. TOP CPU-EATING THREADS  (3s measurement)"
# We read /proc/<pid>/task/*/stat directly instead of using 'top -H':
#   - top does not report the same columns on every system/locale
#   - this way we get the REAL delta between two samples, not an instant value
TICK=$(getconf CLK_TCK 2>/dev/null || echo 100)
tsnap() { # tsnap -> lines of "tid utime+stime"
  local f tid line rest
  for f in /proc/"$PID"/task/*/stat; do
    [ -r "$f" ] || continue
    tid=${f%/stat}; tid=${tid##*/}
    read -r line < "$f" 2>/dev/null || continue
    rest=${line#*") "}           # comm may contain spaces/parens - take what follows
    # field 1 of rest is state (field 3 overall) -> utime is 14 overall = 12 here, stime 15 = 13
    set -- $rest
    [ $# -ge 13 ] || continue
    echo "$tid $(( ${12} + ${13} ))"
  done
}
tsnap > "$OUT/.t0.tmp" 2>/dev/null
sleep 3
tsnap > "$OUT/.t1.tmp" 2>/dev/null
awk -v tick="$TICK" -v sn=3 '
  NR==FNR { a[$1]=$2; next }
  { d = $2 - (($1 in a) ? a[$1] : $2); if (d > 0) printf "%s %.1f\n", $1, d*100.0/(tick*sn) }
' "$OUT/.t0.tmp" "$OUT/.t1.tmp" | sort -k2 -rn | head -10 > "$OUT/.tcpu.tmp"

if [ -s "$OUT/.tcpu.tmp" ]; then
  printf '    %-7s %-7s %-40s %s\n' "TID" "CPU%" "THREAD NAME" "CURRENT METHOD"
  while read -r tid cpu; do
    # Finding the OS thread id in a thread dump needs both notations:
    #   JDK 8/11 : nid=0x1eb0   (hexadecimal)
    #   JDK 17+  : nid=7856     (decimal)  and also "#23 [7856]"
    hex=$(printf '%x' "$tid" 2>/dev/null)
    line=$(grep -m1 -E "nid=(0x$hex|$tid)[^0-9a-f]" "$TD" 2>/dev/null)
    [ -n "$line" ] || line=$(grep -m1 -F "[$tid]" "$TD" 2>/dev/null)
    tname=$(printf '%s' "$line" | sed -n 's/^"\([^"]*\)".*/\1/p')
    # Non-Java threads (GC/JIT/VM) are absent from the dump; /proc keeps a kernel name
    [ -n "$tname" ] || tname="[$(cat "/proc/$PID/task/$tid/comm" 2>/dev/null || echo '?')]"
    frame=""
    if [ -n "$line" ]; then
      frame=$(grep -A4 -F "$line" "$TD" 2>/dev/null | grep -oE "at [a-zA-Z0-9_.$]+" | head -1 | sed 's/^at //')
    fi
    printf '    %-7s %-7s %-40s %s\n' "$tid" "$cpu" "$(echo "$tname" | cut -c1-40)" "${frame:-}"
  done < "$OUT/.tcpu.tmp"
  cp "$OUT/.tcpu.tmp" "$OUT/thread-cpu.txt"
  TOP_THREAD_CPU=$(head -1 "$OUT/.tcpu.tmp" | awk '{print $2}')
else
  echo "    (no thread burned CPU during the window - the application may be idle)"
fi
rm -f "$OUT/.t0.tmp" "$OUT/.t1.tmp" "$OUT/.tcpu.tmp"

# ------------------------------------------------------- 7. JIT / CODE CACHE
heading "7. JIT / CODE CACHE / CLASS LOADING"
"$JCMD" "$PID" Compiler.codecache > "$OUT/codecache.txt" 2>/dev/null
CC_USED=$(grep -oE "used=[0-9]+Kb" "$OUT/codecache.txt" 2>/dev/null | head -1 | grep -oE "[0-9]+")
CC_MAX=$(awk -v c="$(num "${CODECACHE:-0}")" 'BEGIN{printf "%.0f", c/1024}')
if [ -n "${CC_USED:-}" ] && [ "$(num "${CC_MAX:-0}")" -gt 0 ] 2>/dev/null; then
  CC_PCT=$(pct "$CC_USED" "$CC_MAX")
  kv "Code cache" "$((CC_USED/1024)) MB / $((CC_MAX/1024)) MB  (${CC_PCT}%)"
  m CODECACHE_PCT "$CC_PCT"
else
  sed -n '2,6p' "$OUT/codecache.txt" 2>/dev/null | sed 's/^/  /'
fi
# A long compiler queue means JIT is falling behind (normal at startup, not later)
"$JCMD" "$PID" Compiler.queue > "$OUT/compiler-queue.txt" 2>/dev/null
CQ=$(grep -cE '^\s*[0-9]+\s' "$OUT/compiler-queue.txt" 2>/dev/null || true)
kv "Compiler queue" "$(num "${CQ:-0}") methods waiting"
# Class count: if it keeps climbing, suspect a classloader leak / dynamic proxies
"$JCMD" "$PID" VM.classloader_stats > "$OUT/classloader-stats.txt" 2>/dev/null
# Columns: ClassLoader Parent CLD* Classes ChunkSz BlockSz Type
# The class count is column 4. Only count real loader rows (those starting with 0x);
# continuation rows such as "+ hidden classes" hold the count in field 1 instead.
CLS_N=$(awk '$1 ~ /^0x/ {n+=$4} /hidden classes/ {n+=$1} END{print n+0}' "$OUT/classloader-stats.txt" 2>/dev/null)
CL_N=$(awk '$1 ~ /^0x/ {c++} END{print c+0}' "$OUT/classloader-stats.txt" 2>/dev/null)
kv "Loaded classes / loaders" "$(num "${CLS_N:-0}") classes / $(num "${CL_N:-0}") loaders"
m CLASSES "$(num "${CLS_N:-0}")"; m CLASSLOADER "$(num "${CL_N:-0}")"

# -------------------------------------------------------------- 8. PROFILE
JFRF=""
if [ "$QUICK" = "0" ]; then
  heading "8. PROFILE  (${DURATION}s)"

  # JFR: built into JDK 11+, ~2% overhead with settings=profile.
  # We deliberately do NOT pass duration= - we stop the recording ourselves, so the
  # safety net (trap) can close it on Ctrl-C too. No half-finished recordings left.
  JFRF="$OUT/recording.jfr"
  PROF_START=$(date +%s)
  if "$JCMD" "$PID" JFR.start name="$JFR_NAME" settings=profile >/dev/null 2>&1; then
    JFR_STARTED=1
    echo "  JFR recording started (name: $JFR_NAME)"
  else
    echo "  ${Y}Could not start JFR${Z} - needs JDK 11+ (JFR is free from 11 on)."
    echo "    Try by hand: $JCMD $PID JFR.start settings=profile"
    JFRF=""
  fi

  # async-profiler: unlike JFR it has no safepoint bias.
  run_asprof() { # run_asprof <event> <seconds> <output-file> [label]
    local ev="$1" sr="$2" file="$3" label="${4:-$1}"
    printf '  async-profiler %s (%ss)...' "$label" "$sr"
    "$ASPROF" -d "$sr" -e "$ev" -o flamegraph -f "$file" "$PID" >"$OUT/.asprof.log" 2>&1 &
    ASPROF_PID=$!
    wait "$ASPROF_PID" 2>/dev/null; local rc=$?
    ASPROF_PID=""
    if [ "$rc" = "0" ] && [ -s "$file" ]; then
      printf ' -> %s\n' "$file"
    else
      printf ' %sfailed%s\n' "$Y" "$Z"
      sed 's/^/      /' "$OUT/.asprof.log" 2>/dev/null | head -4
    fi
    return $rc
  }

  if [ -n "${ASPROF:-}" ] && [ -x "${ASPROF:-/nonexistent}" ]; then
    PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 3)
    EV=cpu
    if [ "$(num "$PARANOID")" -gt 1 ] 2>/dev/null; then
      EV=ctimer
      echo "  perf_event_paranoid=$PARANOID -> using 'ctimer' instead (needs no root)."
    fi
    run_asprof "$EV" "$DURATION" "$OUT/cpu.html" "CPU ($EV)" || true
    ALLOC_DURATION=$(( DURATION / 2 )); [ "$ALLOC_DURATION" -lt 20 ] && ALLOC_DURATION=20
    run_asprof alloc "$ALLOC_DURATION" "$OUT/alloc.html" "allocation" || true
    if [ "$FULL" = "1" ]; then
      # wall = where are threads WHILE WAITING? The answer to "low CPU but slow app".
      run_asprof wall "$ALLOC_DURATION" "$OUT/wall.html" "wall-clock (waiting)" || true
      run_asprof lock "$ALLOC_DURATION" "$OUT/lock.html" "lock contention" || true
    else
      echo "  (add --full for the wall and lock profiles - that is where waiting shows up)"
    fi
  else
    echo "  ${Y}async-profiler missing${Z} - flame graphs will be built from the JFR recording."
    echo "    To install it: ./scripts/00-setup.sh"
  fi

  # The JFR window must be AT LEAST --duration long.
  # CAREFUL: this window used to be created as a side effect of async-profiler's
  # blocking "-d $DURATION" run. With async-profiler not installed (i.e. 00-setup.sh
  # never run) JFR was stopped the instant it started, leaving a ~0 second recording
  # with a handful of samples. The elapsed-time wait below guarantees the window.
  if [ "$JFR_STARTED" = "1" ]; then
    ELAPSED=$(( $(date +%s) - PROF_START ))
    REMAIN=$(( DURATION - ELAPSED ))
    if [ "$REMAIN" -gt 0 ]; then
      echo "  JFR recording in progress, waiting another ${REMAIN}s..."
      sleep "$REMAIN"
    fi
  fi

  # Stop JFR and write it to a file
  if [ "$JFR_STARTED" = "1" ]; then
    echo "  Stopping the JFR recording and writing it out..."
    JFR_ERR=$("$JCMD" "$PID" JFR.stop name="$JFR_NAME" filename="$JFRF" 2>&1)
    JFR_RC=$?
    JFR_STARTED=0
    if [ "$JFR_RC" = "0" ] && [ -s "$JFRF" ]; then
      echo "    -> $JFRF  ($(du -h "$JFRF" 2>/dev/null | cut -f1))"
    else
      JFRF=""
      echo "    ${Y}could not write the recording${Z} - the JVM answered:"
      printf '%s\n' "$JFR_ERR" | grep -v '^Picked up ' | sed 's/^/      /' | head -6
      case "$JFR_ERR" in
        *OutOfMemory*) echo "      ${R}The target JVM has filled its heap - fix the OOM first.${Z}" ;;
        *"Could not"*|*"No recording"*) echo "      The recording name may clash; check for other JFR recordings on the process:"
                                        echo "        $JCMD $PID JFR.check" ;;
      esac
    fi
  fi
fi

# The 'jfr' command line tool: prefer the bundled JDK 21, else the target's own jfr
JFRTOOL="${JFRCLI:-}"; [ -x "${JFRTOOL:-/nonexistent}" ] || JFRTOOL=$(pick jfr)

# With no async-profiler we build the flame graph out of the JFR recording instead.
# The bundled jfr-converter.jar exists exactly for this.
if [ -n "${JFRF:-}" ] && [ -s "${JFRF:-/nonexistent}" ] && [ ! -s "$OUT/cpu.html" ]; then
  JFRCONV="${JFRCONV:-$PROFILING_HOME/tools/jfr-converter/jfr-converter.jar}"
  JAVABIN=$(pick java)
  if [ -f "$JFRCONV" ] && [ -n "$JAVABIN" ]; then
    echo "  Building a flame graph from the JFR recording (jfr-converter)..."
    "$JAVABIN" -jar "$JFRCONV" "$JFRF" "$OUT/cpu.html"          >/dev/null 2>&1 \
      && echo "    -> $OUT/cpu.html"
    "$JAVABIN" -jar "$JFRCONV" --alloc "$JFRF" "$OUT/alloc.html" >/dev/null 2>&1 \
      && echo "    -> $OUT/alloc.html"
  fi
fi

# ------------------------------------------------------- 9. HOT CODE PATHS
N_CPU=0; N_ALLOC=0; N_LOCK=0
if [ -n "${JFRF:-}" ] && [ -s "${JFRF:-/nonexistent}" ] && [ -n "$JFRTOOL" ]; then
heading "9. HOT CODE PATHS  (class.method + likely cause + fix)"

# Summary first: how many of each event type are there? Empty types are never
# dumped - 'jfr print' is expensive and there is no point running it for nothing.
"$JFRTOOL" summary "$JFRF" > "$OUT/jfr-summary.txt" 2>/dev/null
# The 'jfr summary' format differs between JDK 11 and JDK 17+, so we look the event
# name up both as "jdk.X" and as plain "X" - otherwise sections vanish silently.
event_count() {
  awk -v e="$1" '
    { n=$1; sub(/^jdk\./,"",n); t=e; sub(/^jdk\./,"",t)
      if (n==t) { print $2; exit } }' "$OUT/jfr-summary.txt" 2>/dev/null
}
has_event() { local n; n=$(num "$(event_count "$1")"); [ "$n" -gt 0 ] 2>/dev/null; }

dump_events() { # dump_events <event-list> <target-file> [stack-depth]
  local events="$1" target="$2" depth="${3:-60}"
  "$JFRTOOL" print --events "$events" --stack-depth "$depth" "$JFRF" > "$target" 2>/dev/null
}

# Shared duration converter for awk (jfr prints things like "5.23 ms")
read -r -d '' MSFN <<'AWKFN' || true
function msec(v, u) {
  v = v + 0
  if (u == "s")   return v * 1000
  if (u == "ms")  return v
  if (u == "us")  return v / 1000
  if (u == "ns")  return v / 1000000
  if (u == "min") return v * 60000
  if (u == "h")   return v * 3600000
  return v
}
AWKFN

dump_events jdk.ExecutionSample "$OUT/.exec.tmp"
ALLOC_EVENTS="jdk.ObjectAllocationInNewTLAB,jdk.ObjectAllocationOutsideTLAB,jdk.ObjectAllocationSample"
dump_events "$ALLOC_EVENTS" "$OUT/.alloc.tmp"

# From every sample: (a) the topmost frame = where the time is spent,
#                    (b) the first frame in YOUR package = the RESPONSIBLE method,
#                    (c) the allocated type, when there is one
extract() { # extract <file>
  awk -v pkg="$PKG" '
    /^[ \t]*objectClass = / { oc=$0; sub(/^[ \t]*objectClass = /,"",oc); sub(/ *\(classLoader.*/,"",oc); next }
    /stackTrace = \[/ { ins=1; top=""; usr=""; next }
    ins && /^[ \t]*\]/ {
      if (top != "") printf "%s\t%s\t%s\n", top, (usr==""?"-":usr), (oc==""?"-":oc);
      ins=0; oc=""; next
    }
    ins {
      l=$0; sub(/^[ \t]+/,"",l); sub(/ line: [0-9]+$/,""); sub(/ line: [0-9]+$/,"",l); sub(/\(.*/,"",l);
      if (l=="") next;
      if (top=="") top=l;
      if (usr=="" && pkg!="" && index(l,pkg)==1) usr=l;
    }' "$1"
}

# With no --package given: scan ALL frames and find the most frequent package
# prefix that is neither JDK nor a well-known library. (Looking only at the top
# frame is useless - that is always a JDK method; your code sits further down.)
if [ -z "$PKG" ]; then
  PKG=$(cat "$OUT/.exec.tmp" "$OUT/.alloc.tmp" 2>/dev/null | awk '
      /stackTrace = \[/ { ins=1; next }
      ins && /^[ \t]*\]/ { ins=0; next }
      ins { l=$0; sub(/^[ \t]+/,"",l); sub(/\(.*/,"",l); if (l!="") print l }
    ' \
    | grep -vE '^(java|javax|jdk|sun|com\.sun|org\.graalvm|kotlin|scala|org\.apache|org\.springframework|io\.netty|ch\.qos|org\.slf4j|org\.hibernate|com\.fasterxml)\.' \
    | awk -F. 'NF>=3{print $1"."$2}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$PKG" ]; then
    echo "  Package prefix detected automatically: ${B}${PKG}${Z}   (override it with --package)"
  else
    echo "  Could not determine a package prefix - the 'your code' lines stay empty."
    echo "  For accurate attribution: ./diagnose.sh $PID --package com.acme"
  fi
fi

# --------------------------------------------------------------- 9a. CPU
extract "$OUT/.exec.tmp" > "$OUT/cpu-frames.tsv"
N_CPU=$(wc -l < "$OUT/cpu-frames.tsv" 2>/dev/null || echo 0)
if [ "$(num "$N_CPU")" -gt 0 ]; then
  echo
  printf '  %sCPU: where the time actually goes%s   (%s samples)\n' "$B" "$Z" "$N_CPU"
  cut -f1,2 "$OUT/cpu-frames.tsv" | sort | uniq -c | sort -rn | head -6 \
    | sed 's/^ *\([0-9]*\) /\1\t/' > "$OUT/cpu-top.tsv"
  i=0
  while IFS=$'\t' read -r cnt frame usr; do
    i=$((i+1))
    pct=$(pct "$cnt" "$N_CPU")
    nc=$(cause_fix "$frame"); cause="${nc%%|*}"; fix="${nc#*|}"
    printf '\n  %s%d)%s %s%-6s%s %s\n' "$B" "$i" "$Z" "$B" "${pct}%" "$Z" "$frame"
    [ "$usr" != "-" ] && printf '       %syour code:%s    %s\n' "$C" "$Z" "$usr"
    if [ -n "$cause" ]; then
      printf '       %slikely cause:%s %s\n' "$Y" "$Z" "$cause"
      printf '       %sfix:%s          %s\n' "$G" "$Z" "$fix"
    elif [ "$usr" = "$frame" ]; then
      printf '       %sstatus:%s       the time is spent DIRECTLY in your code, not in a JDK method\n' "$Y" "$Z"
      printf '       %sfix:%s          expand this method in cpu.html: where is the real work done?\n' "$G" "$Z"
      printf '                     Then measure before/after with JMH: ./jmh/jmh-run.sh\n'
    else
      printf '       %sstatus:%s       not a known anti-pattern\n' "$C" "$Z"
      printf '       %sfix:%s          expand this method in cpu.html, then measure it with JMH\n' "$G" "$Z"
    fi
  done < "$OUT/cpu-top.tsv"
  TOPC_CNT=$(head -1 "$OUT/cpu-top.tsv" | cut -f1)
  TOPC_FRAME=$(head -1 "$OUT/cpu-top.tsv" | cut -f2)
  TOPC_USR=$(head -1 "$OUT/cpu-top.tsv" | cut -f3)
  TOPC_PCT=$(pct "${TOPC_CNT:-0}" "$N_CPU")
fi

# ------------------------------------------------------------ 9b. MEMORY
extract "$OUT/.alloc.tmp" > "$OUT/alloc-frames.tsv"
N_ALLOC=$(wc -l < "$OUT/alloc-frames.tsv" 2>/dev/null || echo 0)
if [ "$(num "$N_ALLOC")" -gt 0 ]; then
  echo
  printf '  %sMEMORY: where the garbage is produced%s   (%s samples)\n' "$B" "$Z" "$N_ALLOC"
  awk -F'\t' '{print $3"\t"$2"\t"$1}' "$OUT/alloc-frames.tsv" | sort | uniq -c | sort -rn | head -6 \
    | sed 's/^ *\([0-9]*\) /\1\t/' > "$OUT/alloc-top.tsv"
  i=0
  while IFS=$'\t' read -r cnt atype usr frame; do
    i=$((i+1))
    pct=$(pct "$cnt" "$N_ALLOC")
    nc=$(cause_fix "$frame"); cause="${nc%%|*}"; fix="${nc#*|}"
    if [ -z "$cause" ]; then nc=$(cause_fix "$atype"); cause="${nc%%|*}"; fix="${nc#*|}"; fi
    printf '\n  %s%d)%s %s%-6s%s type: %s\n' "$B" "$i" "$Z" "$B" "${pct}%" "$Z" "$atype"
    printf '       allocated by: %s\n' "$frame"
    [ "$usr" != "-" ] && printf '       %syour code:%s    %s\n' "$C" "$Z" "$usr"
    if [ -n "$cause" ]; then
      printf '       %slikely cause:%s %s\n' "$Y" "$Z" "$cause"
      printf '       %sfix:%s          %s\n' "$G" "$Z" "$fix"
    fi
  done < "$OUT/alloc-top.tsv"
  TOPA_CNT=$(head -1 "$OUT/alloc-top.tsv" | cut -f1)
  TOPA_TYPE=$(head -1 "$OUT/alloc-top.tsv" | cut -f2)
  TOPA_USR=$(head -1 "$OUT/alloc-top.tsv" | cut -f3)
  TOPA_PCT=$(pct "${TOPA_CNT:-0}" "$N_ALLOC")
fi

# -------------------------------------------------------------- 9c. LOCKS
if has_event jdk.JavaMonitorEnter; then
  dump_events "jdk.JavaMonitorEnter,jdk.JavaMonitorWait" "$OUT/.lock.tmp" 40
  awk -v pkg="$PKG" "$MSFN"'
    /^[ \t]*duration = /      { dur = msec($3, $4); next }
    /^[ \t]*monitorClass = /  { mc = $3; next }
    /stackTrace = \[/         { ins=1; usr=""; top=""; next }
    ins && /^[ \t]*\]/ {
      # Keep the locks of our own measurement tools out of the report (we started
      # the JFR recording and attached async-profiler) - not a real application issue.
      if (mc != "" && mc !~ /^jdk\.jfr\./ && mc !~ /^one\.profiler/ && top !~ /^one\.profiler/)
        printf "%s\t%s\t%s\t%.3f\n", mc, (usr==""?"-":usr), (top==""?"-":top), dur;
      ins=0; mc=""; dur=0; next
    }
    ins {
      l=$0; sub(/^[ \t]+/,"",l); sub(/ line: [0-9]+$/,"",l); sub(/\(.*/,"",l);
      if (l=="") next;
      if (top=="") top=l;
      if (usr=="" && pkg!="" && index(l,pkg)==1) usr=l;
    }' "$OUT/.lock.tmp" > "$OUT/lock-frames.tsv"
  N_LOCK=$(wc -l < "$OUT/lock-frames.tsv" 2>/dev/null || echo 0)
  if [ "$(num "$N_LOCK")" -gt 0 ]; then
    echo
    printf '  %sLOCKS: where threads wait instead of working%s   (%s events)\n' "$B" "$Z" "$N_LOCK"
    # Sort by total wait time - what matters is the TIME lost, not the event COUNT
    awk -F'\t' '{k=$1"\t"$2; t[k]+=$4; n[k]++} END{for(x in t) printf "%.1f\t%d\t%s\n", t[x], n[x], x}' \
      "$OUT/lock-frames.tsv" | sort -rn | head -4 > "$OUT/lock-top.tsv"
    LOCK_TOTAL=$(awk -F'\t' '{s+=$4} END{printf "%.0f", s}' "$OUT/lock-frames.tsv")
    i=0
    while IFS=$'\t' read -r ms cnt mon usr; do
      i=$((i+1))
      printf '\n  %s%d)%s %s%.0f ms%s of waiting in total, %s times  ->  monitor: %s\n' \
        "$B" "$i" "$Z" "$B" "$ms" "$Z" "$cnt" "$mon"
      [ "$usr" != "-" ] && printf '       %syour code:%s    %s\n' "$C" "$Z" "$usr"
      printf '       %sfix:%s          narrow the synchronized block; guard only the shared state.\n' "$G" "$Z"
      printf '                     For counters LongAdder, for maps ConcurrentHashMap remove contention entirely.\n'
    done < "$OUT/lock-top.tsv"
    m LOCK_MS "$(num "${LOCK_TOTAL:-0}")"
  fi
  rm -f "$OUT/.lock.tmp"
fi

# ------------------------------------------------------------------ 9d. IO
IO_TOTAL_MS=0
if has_event jdk.SocketRead || has_event jdk.FileRead || has_event jdk.SocketWrite || has_event jdk.FileWrite; then
  dump_events "jdk.SocketRead,jdk.SocketWrite,jdk.FileRead,jdk.FileWrite" "$OUT/.io.tmp" 40
  awk -v pkg="$PKG" "$MSFN"'
    /^jdk\.(Socket|File)(Read|Write)/ { kind=$1; next }
    /^[ \t]*duration = /  { dur = msec($3, $4); next }
    /stackTrace = \[/     { ins=1; usr=""; next }
    ins && /^[ \t]*\]/    { printf "%s\t%s\t%.3f\n", kind, (usr==""?"-":usr), dur; ins=0; dur=0; next }
    ins {
      l=$0; sub(/^[ \t]+/,"",l); sub(/ line: [0-9]+$/,"",l); sub(/\(.*/,"",l);
      if (usr=="" && pkg!="" && index(l,pkg)==1) usr=l;
    }' "$OUT/.io.tmp" > "$OUT/io-frames.tsv"
  IO_TOTAL_MS=$(awk -F'\t' '{s+=$3} END{printf "%.0f", s+0}' "$OUT/io-frames.tsv")
  if [ "$(num "$IO_TOTAL_MS")" -gt 0 ] 2>/dev/null; then
    echo
    printf '  %sIO: time spent waiting%s   (total %s ms)\n' "$B" "$Z" "$IO_TOTAL_MS"
    awk -F'\t' '{k=$1"\t"$2; t[k]+=$3; n[k]++} END{for(x in t) printf "%.0f\t%d\t%s\n", t[x], n[x], x}' \
      "$OUT/io-frames.tsv" | sort -rn | head -4 \
      | while IFS=$'\t' read -r ms cnt kind usr; do
          printf '    %8s ms  %5s x  %-24s %s\n' "$ms" "$cnt" "$kind" "$([ "$usr" != "-" ] && echo "<- $usr")"
        done
    echo "    Note: IO waiting is not CPU. If the total is large, the bottleneck is not"
    echo "          in your code but outside it (network, disk, database). Use --full."
    m IO_MS "$(num "$IO_TOTAL_MS")"
  fi
  rm -f "$OUT/.io.tmp"
fi

# ---------------------------------------------------------- 9e. EXCEPTION
EXC_N=0
if has_event jdk.JavaExceptionThrow || has_event jdk.ExceptionStatistics; then
  dump_events "jdk.JavaExceptionThrow,jdk.JavaErrorThrow" "$OUT/.exc.tmp" 20
  # async-profiler throws a NoClassDefFoundError while loading itself; do not count it.
  EXC_N=$(count '^jdk\.Java\(Exception\|Error\)Throw' "$OUT/.exc.tmp")
  EXC_TOOL=$(count 'one/profiler' "$OUT/.exc.tmp")
  EXC_N=$(( $(num "$EXC_N") - $(num "$EXC_TOOL") ))
  [ "$EXC_N" -lt 0 ] && EXC_N=0
  if [ "$(num "$EXC_N")" -gt 0 ] 2>/dev/null; then
    echo
    printf '  %sEXCEPTIONS: %s thrown during the recording%s\n' "$B" "$EXC_N" "$Z"
    grep -E '^\s*(thrownClass|message) = ' "$OUT/.exc.tmp" 2>/dev/null \
      | sed 's/^\s*[a-zA-Z]* = //' \
      | grep -vE 'one/profiler|one\.profiler|jdk\.jfr' \
      | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
    echo "    Creating an exception is expensive because it fills in a stack trace."
    echo "    If they drive control flow (not-found/invalid), return a value instead."
  fi
  rm -f "$OUT/.exc.tmp"
  m EXCEPTION "$(num "$EXC_N")"
fi

# --------------------------------------------------------- 9f. SAFEPOINT
SP_MS=0
if has_event jdk.SafepointBegin; then
  dump_events "jdk.SafepointBegin" "$OUT/.sp.tmp" 1
  SP_MS=$(awk "$MSFN"'/^[ \t]*duration = /{s+=msec($3,$4)} END{printf "%.0f", s+0}' "$OUT/.sp.tmp")
  SP_N=$(count '^jdk\.SafepointBegin' "$OUT/.sp.tmp")
  if [ "$(num "$SP_N")" -gt 0 ] 2>/dev/null; then
    echo
    printf '  %sSAFEPOINTS: %s pauses, %s ms in total%s\n' "$B" "$SP_N" "$SP_MS" "$Z"
    echo "    A safepoint is not only GC: bias revocation, deoptimization and thread"
    echo "    dumps all request one. If this number is high while GC load is low, the"
    echo "    cause is outside GC (-XX:+PrintSafepointStatistics gives the detail)."
  fi
  rm -f "$OUT/.sp.tmp"
  m SAFEPOINT_MS "$(num "$SP_MS")"
fi

# ----------------------------------------------------- 9g. THREAD CREATION
if has_event jdk.ThreadStart; then
  TS_N=$(num "$(event_count jdk.ThreadStart)")
  if [ "$TS_N" -gt 50 ] 2>/dev/null; then
    echo
    printf '  %sTHREAD CREATION: %s new threads during the recording%s\n' "$B" "$TS_N" "$Z"
    echo "    Creating a thread is expensive (~1 MB of stack + kernel structures)."
    echo "    If a thread is spawned per request, use a pool (ExecutorService)."
  fi
  m THREAD_START "$TS_N"
fi

if [ "$(num "$N_CPU")" = 0 ] && [ "$(num "$N_ALLOC")" = 0 ]; then
  echo "  No samples in the JFR recording (the app may be idle, or the window too short)."
  echo "  Try again under load with --duration 180."
fi
rm -f "$OUT/.exec.tmp" "$OUT/.alloc.tmp"
fi

# ----------------------------------------------------------- 10. HEAP DUMP
if [ "$DEEP" = "1" ]; then
  heading "10. HEAP DUMP + MAT HEADLESS"
  HD="$OUT/heap.hprof"
  DISK_FREE=$(df -Pk "$OUT" 2>/dev/null | awk 'NR==2{print $4}')
  HEAP_KB=$(awk -v x="$(num "${XMX:-0}")" 'BEGIN{printf "%.0f", x/1024}')
  if [ -n "${DISK_FREE:-}" ] && [ "$(num "$DISK_FREE")" -lt "$(num "$HEAP_KB")" ] 2>/dev/null; then
    echo "  ${R}Disk space may be short${Z}: $(mb "$DISK_FREE") MB free, heap ceiling $(mb "$HEAP_KB") MB"
    echo "  A dump is roughly the size of the LIVE heap. Trying anyway..."
  fi
  echo "  Taking the dump (STW pause, file ~ live heap size)..."
  "$JCMD" "$PID" GC.heap_dump "$HD" 2>&1 | sed 's/^/    /'
  if [ -s "$HD" ]; then
    echo "  -> $HD  ($(du -h "$HD" 2>/dev/null | cut -f1))"
    if [ -x "${TOOLS:-}/mat/ParseHeapDump.sh" ]; then
      echo "  Running MAT headless (this can take a while)..."
      "$TOOLS/mat/ParseHeapDump.sh" "$HD" org.eclipse.mat.api:suspects >"$OUT/mat.log" 2>&1 \
        && echo "    -> $(ls "$OUT"/*Leak_Suspects*.zip 2>/dev/null | head -1)" \
        || { echo "    MAT did not run, log: $OUT/mat.log"; tail -5 "$OUT/mat.log" 2>/dev/null | sed 's/^/      /'; }
    else
      echo "  MAT is not unpacked (./scripts/00-setup.sh). To analyse the dump:"
      echo "    ./scripts/heap-summary.sh $HD"
    fi
  fi
fi

# ----------------------------------------------------------- 11. COMPARISON
if [ -n "$COMPARE" ]; then
  heading "11. COMPARISON WITH AN EARLIER RUN"
  PREV="$COMPARE/metrics.env"
  if [ ! -f "$PREV" ]; then
    echo "  ${Y}$PREV does not exist${Z} - nothing to compare against."
    echo "  (Pass the output directory of an earlier run to --compare.)"
  else
    echo "  Earlier run: $COMPARE"
    printf '    %-18s %14s %14s %12s\n' "METRIC" "BEFORE" "NOW" "CHANGE"
    print_delta() { # print_delta <key> <label> <unit> <better: lower|higher>
      local key="$1" label="$2" unit="$3" better="${4:-lower}"
      local a b
      a=$(awk -F= -v k="$key" '$1==k{print $2}' "$PREV" | tail -1)
      b=$(awk -F= -v k="$key" '$1==k{print $2}' "$METRICS" | tail -1)
      [ -n "${a:-}" ] && [ -n "${b:-}" ] || return 0
      case "$a$b" in *[!0-9.]*) return 0 ;; esac
      local d col
      d=$(awk -v a="$a" -v b="$b" 'BEGIN{ if(a+0==0){ print (b+0==0)?"0.0":"new" } else printf "%+.1f%%", (b-a)/a*100 }')
      col=""
      if [ "$d" != "new" ]; then
        local dir; dir=$(awk -v a="$a" -v b="$b" 'BEGIN{print (b+0>a+0)?"up":((b+0<a+0)?"down":"same")}')
        if [ "$dir" = "same" ]; then col=""
        elif { [ "$better" = "lower" ] && [ "$dir" = "down" ]; } || { [ "$better" = "higher" ] && [ "$dir" = "up" ]; }
        then col="$G"; else col="$R"; fi
      fi
      printf '    %-18s %14s %14s   %s%-10s%s %s\n' "$label" "$a" "$b" "$col" "$d" "$Z" "$unit"
    }
    print_delta GC_LOAD    "GC load"        "%"
    print_delta ALLOC_MBS  "Allocation"     "MB/s"
    print_delta PROMO_MBS  "Promotion"      "MB/s"
    print_delta OLD_PCT    "Old gen"        "%"
    print_delta RSS_MB     "RSS"            "MB"
    print_delta CPU_PCT    "CPU"            "%"
    print_delta THREAD     "Threads"        "count"
    print_delta BLOCKED    "BLOCKED threads" "count"
    print_delta LOCK_MS    "Lock waiting"   "ms"
    print_delta FGC        "Full GC"        "times"
    print_delta FD         "Open files"     "count"
    echo
    echo "    ${C}Rule:${Z} if the change did not move the number you measured, REVERT IT."
    echo "    An unmeasured 'improvement' is nothing but technical debt."
  fi
fi

# ============================================================== FINDINGS
printf '\n%s╔════════════════════════════════════════════════════════════╗%s\n' "$B$C" "$Z"
printf '%s║  FINDINGS                                                  ║%s\n' "$B$C" "$Z"
printf '%s╚════════════════════════════════════════════════════════════╝%s\n' "$B$C" "$Z"

# --- Hot code paths: with the real class.method ---
if [ -n "${TOPC_FRAME:-}" ]; then
  _nc=$(cause_fix "$TOPC_FRAME"); _n="${_nc%%|*}"; _c="${_nc#*|}"
  _owner=""
  [ -n "${TOPC_USR:-}" ] && [ "${TOPC_USR:-}" != "-" ] && _owner="  Responsible method: ${TOPC_USR}"
  if [ -n "$_n" ]; then
    finding WARN "${TOPC_PCT}% of CPU samples: ${TOPC_FRAME}" "${_n}.${_owner}" "$_c"
  elif [ -n "$_owner" ]; then
    finding INFO "${TOPC_PCT}% of CPU samples: ${TOPC_FRAME}" \
      "Not a known anti-pattern - this is your own code.${_owner}" \
      "Expand the blocks under this method in cpu.html, then write a JMH benchmark for ${TOPC_USR}."
  fi
fi
if [ -n "${TOPA_TYPE:-}" ]; then
  _owner=""
  [ -n "${TOPA_USR:-}" ] && [ "${TOPA_USR:-}" != "-" ] && _owner="  Responsible method: ${TOPA_USR}"
  finding WARN "${TOPA_PCT}% of the garbage is a single type: ${TOPA_TYPE}" \
    "This type is the largest slice of the allocation samples.${_owner}" \
    "Allocate it less often or reuse it. Detail: the MEMORY list in section 9 and alloc.html"
fi
if [ -n "${LOCK_TOTAL:-}" ] && [ "$(gt "${LOCK_TOTAL:-0}" 1000)" = 1 ]; then
  finding WARN "Lock waiting totals ${LOCK_TOTAL} ms" \
    "Threads are waiting on each other instead of working. That time is charged to latency, not CPU." \
    "See the monitor list in 9c. Order of fixes: narrow the block -> go lock-free (ConcurrentHashMap/LongAdder) -> shard the data."
fi
if [ -n "${IO_TOTAL_MS:-}" ] && [ "$(gt "${IO_TOTAL_MS:-0}" $((DURATION*300)))" = 1 ]; then
  finding WARN "IO waiting totals ${IO_TOTAL_MS} ms" \
    "Most of the recording was spent waiting on network/disk. Making the code faster will not fix that." \
    "First find out what it waits for: take a wall profile with --full. Then look at batching/pooling/timeouts."
fi

# --- GC ---
if [ -n "${GC_LOAD:-}" ]; then
  if [ "$(gt "$GC_LOAD" "$T_GC_CRIT")" = 1 ]; then
    finding CRIT "GC eats ${GC_LOAD}% of wall-clock time" \
      "Most of the application's time goes into GC pauses. That is both CPU and latency lost." \
      "The cause is almost always excessive allocation. Open alloc.html and find the widest block."
  elif [ "$(gt "$GC_LOAD" "$T_GC_WARN")" = 1 ]; then
    finding WARN "GC load is ${GC_LOAD}%" \
      "Above the acceptable limit. Aim for less than ${T_GC_WARN}%." \
      "Use alloc.html to find the code that produces the garbage."
  fi
fi
if [ "$(num "${DFGC:-0}")" -gt 0 ] 2>/dev/null; then
  finding CRIT "Full GC is running (${DFGC} times within ${WALL}s)" \
    "A Full GC is the most expensive pause there is. If it repeats regularly, the heap is too small or something leaks." \
    "Old gen is at ${O_PCT:-?}%. Take a heap dump with --deep and read the Leak Suspects report first."
fi
if [ -n "${O_PCT:-}" ] && [ "$(gt "$O_PCT" "$T_OLD_CRIT")" = 1 ]; then
  finding CRIT "Old gen is ${O_PCT}% full" \
    "The old generation is nearly full. Full GCs are imminent, or an OOM is." \
    "Is it a leak, or is the heap simply small? Tell them apart with ./diagnose.sh $PID --deep."
elif [ -n "${O_PCT:-}" ] && [ "$(gt "$O_PCT" "$T_OLD_WARN")" = 1 ]; then
  finding WARN "Old gen is at ${O_PCT}%" "Usage is high - watch the trend." \
    "Watch it for a few minutes with jstat -gcutil $PID 5000; a steady climb means a leak."
fi
if [ -n "${ALLOC_MB:-}" ] && [ "$(gt "$ALLOC_MB" "$T_ALLOC")" = 1 ]; then
  finding WARN "Allocation rate ~${ALLOC_MB} MB/s" \
    "Heavy garbage production. In Java this is where most CPU goes; memory and CPU suffer together." \
    "Look at the 3 widest blocks in alloc.html. Usual suspects: string concat, boxing, un-presized collections."
fi
if [ -n "${PROMO_MB:-}" ] && [ "$(gt "$PROMO_MB" 10)" = 1 ]; then
  finding WARN "Promotion into old gen ~${PROMO_MB} MB/s" \
    "Objects survive young GC and move to the old generation. Either they really are long-lived (cache/leak), or the young area is too small." \
    "Use --deep if you suspect a leak. Otherwise grow young with -Xmn / -XX:NewRatio."
fi
# A metaspace warning is only meaningful when there is a REAL ceiling. Without one,
# sitting at 90% of committed is normal - the JVM commits exactly what it needs.
if [ -n "${M_PCT:-}" ] && [ "$(gt "$M_PCT" 90)" = 1 ]; then
  finding WARN "Metaspace is at ${M_PCT}% of MaxMetaspaceSize" \
    "When it fills, a Full GC is triggered first and then OutOfMemoryError: Metaspace. Libraries that generate classes at runtime (proxies, ORM, script engines) are the usual cause." \
    "Raise -XX:MaxMetaspaceSize; if the growth never stops, investigate a classloader leak (see the loader count in section 7)."
fi
if [ "$(num "${CL_N:-0}")" -gt 500 ] 2>/dev/null; then
  finding WARN "$(num "${CL_N:-0}") classloaders are live" \
    "A large number of classloaders is the classic symptom of a classloader leak (hot deploy, dynamic proxies, script engines)." \
    "Watch the metaspace trend. If it does leak, dump with --deep and open MAT's 'Duplicate Classes' report."
fi

# --- Memory ---
if [ -n "${SWAP_KB:-}" ] && [ "$(num "$SWAP_KB")" -gt 10240 ] 2>/dev/null; then
  finding CRIT "The JVM has been swapped out ($(mb "$SWAP_KB") MB)" \
    "A swapping JVM is a disaster: GC walks the whole heap and has to read it back from swap, so pauses grow into seconds." \
    "Either lower -Xmx or add RAM. Even as a stopgap: lower vm.swappiness and pin the heap up front with -XX:+AlwaysPreTouch."
fi
OVER=""
if [ -n "${RSS_KB:-}" ] && [ -n "${XMX:-}" ] && [ "$(num "${XMX:-0}")" -gt 0 ] 2>/dev/null; then
  XMX_KB=$(( $(num "$XMX") / 1024 ))
  OVER=$(( $(num "$RSS_KB") - XMX_KB ))
  if [ "$OVER" -gt 1048576 ]; then
    finding WARN "RSS exceeds the heap ceiling by $(mb "$OVER") MB" \
      "Real memory use is far above -Xmx. The problem is NOT in the heap; lowering -Xmx will not help." \
      "Check in order: 1) export MALLOC_ARENA_MAX=2 (very common on RHEL) 2) ${NTHREAD:-?} threads x -Xss 3) NMT for metaspace/direct buffers."
  fi
fi
if [ -n "${MEMMAX:-}" ] && [ "$MEMMAX" != "max" ] && [ -n "${RSS_KB:-}" ]; then
  case "$MEMMAX" in
    ''|*[!0-9]*) : ;;
    *)
      MM_KB=$(( MEMMAX / 1024 ))
      MPCT=$(pct "$RSS_KB" "$MM_KB")
      if [ "$(gt "$MPCT" 85)" = 1 ]; then
        finding CRIT "${MPCT}% of the container memory limit is in use" \
          "Cross the limit and the kernel OOM-killer kills the process - unlike a JVM OOM it leaves no log and no heap dump." \
          "Either raise the limit or lower -Xmx. Rule of thumb: -Xmx should be ~70% of the limit (leave room for off-heap)."
      fi
      ;;
  esac
fi

# --- CPU / cgroup ---
if [ -n "${THROTTLED:-}" ] && [ "$(num "${THROTTLED:-0}")" -gt 0 ] 2>/dev/null; then
  finding CRIT "cgroup CPU throttling: ${THROTTLED} times" \
    "The application is not slow, it is being THROTTLED. Profiling in this state misleads you into optimizing the wrong thing." \
    "Raise the cpu.max limit first (${CPUMAX:-?}), then measure again."
fi
if [ -n "${CPUPCT:-}" ] && [ "$(gt "$CPUPCT" $((NPROC*85)))" = 1 ]; then
  finding WARN "CPU at ${CPUPCT}% (ceiling $((NPROC*100))%)" \
    "The process has nearly saturated every core." \
    "Look at the 3 widest blocks in cpu.html."
fi
if [ -n "${TOP_THREAD_CPU:-}" ] && [ "$(gt "${TOP_THREAD_CPU:-0}" 90)" = 1 ] \
   && [ "$(gt "$(pct "${CPUPCT:-0}" "$((NPROC*100))")" 60)" = 0 ]; then
  finding INFO "One thread burns ${TOP_THREAD_CPU}% CPU while total CPU stays low" \
    "The work is stuck on a single thread - adding cores will not make this application faster." \
    "Check the thread name in section 6. If the work can be split, spread it with parallelStream/ExecutorService."
fi
if [ -n "${ACTIVEPROC:-}" ] && [ -n "${CG_CORES:-}" ]; then
  if [ "$(num "${ACTIVEPROC:-0}")" -gt 0 ] 2>/dev/null && [ "$(gt "${ACTIVEPROC}" "$CG_CORES")" = 1 ]; then
    finding WARN "The JVM sees ${ACTIVEPROC} cores but the cgroup limit is ~${CG_CORES}" \
      "GC thread counts, ForkJoinPool.commonPool and pool defaults are all sized wrongly, so you throttle yourself." \
      "Pass -XX:ActiveProcessorCount=${CG_CORES%.*} or raise the cgroup limit."
  fi
fi

# --- Threads ---
if [ "$(num "${DEADLOCK:-0}")" -gt 0 ] 2>/dev/null; then
  finding CRIT "DEADLOCK detected" \
    "The JVM reported a Java-level deadlock. The affected threads are stopped for good and will not recover on their own." \
    "Detail: search for 'Found one Java-level deadlock' in $OUT/thread-dump-3.txt. Acquire locks in the SAME ORDER everywhere."
fi
if [ "$(num "${NTHREAD:-0}")" -gt "$T_THREAD_CRIT" ] 2>/dev/null; then
  finding CRIT "${NTHREAD} threads" \
    "Far too many. Every thread means stack memory (1 MB by default) plus scheduler overhead." \
    "Cap your thread pools. Roughly $(( $(num "${NTHREAD:-0}") / 1024 )) GB may be going to stacks alone."
elif [ "$(num "${NTHREAD:-0}")" -gt "$T_THREAD_WARN" ] 2>/dev/null; then
  finding WARN "${NTHREAD} threads" \
    "A high thread count costs context switches." \
    "Review the pool sizes; for CPU-bound work ~$NPROC (the core count) is enough."
fi
BPCT=$(pct "${N_BLOCKED:-0}" "${N_TOTAL:-1}")
if [ "$(gt "$BPCT" "$T_BLOCKED")" = 1 ]; then
  finding WARN "${BPCT}% of threads are BLOCKED (${N_BLOCKED}/${N_TOTAL})" \
    "Serious lock contention. Threads are waiting on each other instead of working." \
    "Take a lock profile with --full (lock.html); narrow the synchronized blocks or move to ConcurrentHashMap."
fi

# --- FD ---
if [ -n "${FD_MAX:-}" ] && [ "$(num "${FD_MAX:-0}")" -gt 0 ] 2>/dev/null; then
  FPCT=$(pct "${FD_N:-0}" "$FD_MAX")
  if [ "$(gt "$FPCT" "$T_FD")" = 1 ]; then
    finding CRIT "File descriptors at ${FPCT}% (${FD_N}/${FD_MAX})" \
      "Once the limit is hit everything collapses with 'Too many open files' - not just files, accepting sockets stops too." \
      "Hunt for unclosed streams/sockets: the SpotBugs OS_OPEN_STREAM rule (./scripts/static-scan.sh)."
  fi
fi

# --- Code cache ---
if [ -n "${CC_PCT:-}" ] && [ "$(gt "$CC_PCT" "$T_CC")" = 1 ]; then
  finding CRIT "Code cache is ${CC_PCT}% full" \
    "When it fills, JIT stops compiling entirely and the application suddenly becomes many times slower. An insidious failure." \
    "Pass -XX:ReservedCodeCacheSize=512m."
fi

# --- Configuration (wins that need no code change) ---
if [ -n "${XMS:-}" ] && [ -n "${XMX:-}" ] && [ "$(num "${XMS:-0}")" != "$(num "${XMX:-0}")" ]; then
  finding INFO "-Xms ($(bmb "$XMS") MB) differs from -Xmx ($(bmb "$XMX") MB)" \
    "Growing and shrinking the heap costs extra pauses." \
    "For server applications make them equal: -Xms$(bmb "$XMX")m -Xmx$(bmb "$XMX")m"
fi
if [ "${HEAPDUMP_OOM:-false}" != "true" ]; then
  finding INFO "HeapDumpOnOutOfMemoryError is off" \
    "If an OOM happens you are left with no evidence and have to reproduce it." \
    "Add -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=\$HOME/perf-out/"
fi
if ! grep -q "StartFlightRecording" "$OUT/command-line.txt" 2>/dev/null; then
  finding INFO "Continuous JFR recording is off" \
    "JFR runs at ~2% overhead and captures the moment things go wrong. Without it you have no data after the fact." \
    "-XX:StartFlightRecording=settings=profile,disk=true,maxsize=512m,maxage=12h,dumponexit=true,filename=\$HOME/perf-out/app.jfr"
fi
if [ "${DEBUGNSP:-false}" != "true" ]; then
  finding INFO "DebugNonSafepoints is off - the profile may blame the WRONG method" \
    "Without this flag, stacks from JIT-compiled code are rounded to the nearest safepoint. The hot method in this report could actually be its neighbour." \
    "-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints  (the cost is negligible; it can stay on permanently)"
fi
if [ -z "${MALLOC_ARENA_MAX:-}" ] && [ -n "${OVER:-}" ] && [ "$(num "${OVER:-0}")" -gt 524288 ] 2>/dev/null; then
  finding INFO "MALLOC_ARENA_MAX is not set" \
    "glibc opens a separate malloc arena per thread group, which inflates RSS in multi-threaded applications." \
    "export MALLOC_ARENA_MAX=2  (one line; on RHEL it often saves hundreds of MB)"
fi
if [ -z "${MAXMETA:-}" ] || [ "$(num "${MAXMETA:-0}")" -eq 0 ] 2>/dev/null; then
  finding INFO "MaxMetaspaceSize is unlimited" \
    "Metaspace lives outside the heap and is unbounded by default, so a classloader leak can exhaust the machine's RAM." \
    "-XX:MaxMetaspaceSize=256m  (a ceiling turns a leak into an early, visible OOM)"
fi
if [ -z "${MAXDIRECT:-}" ] || [ "$(num "${MAXDIRECT:-0}")" -eq 0 ] 2>/dev/null; then
  if [ -n "${OVER:-}" ] && [ "$(num "${OVER:-0}")" -gt 524288 ] 2>/dev/null; then
    finding INFO "MaxDirectMemorySize is not set" \
      "Direct ByteBuffers are allocated off-heap and do not count towards -Xmx. In Netty/NIO applications they are the hidden source of RSS." \
      "Pass -XX:MaxDirectMemorySize=512m and watch it live on VisualVM's 'Buffer Monitor' tab."
  fi
fi
if [ "${PRETOUCH:-false}" != "true" ] && [ -n "${XMX:-}" ] && [ "$(num "${XMX:-0}")" -gt 4294967296 ] 2>/dev/null; then
  finding INFO "AlwaysPreTouch is off (heap $(bmb "$XMX") MB)" \
    "On a large heap, pages are allocated on first touch, so that cost is spread over run time - meaning over your users." \
    "-XX:+AlwaysPreTouch  (startup takes a few seconds longer, run-time stalls disappear)"
fi
if [ "${GCNAME:-}" = "Serial" ] && [ "$NPROC" -gt 2 ]; then
  finding WARN "Serial GC is selected although there are $NPROC cores" \
    "Serial GC collects on a single thread, so pauses are needlessly long on a multi-core machine." \
    "For throughput -XX:+UseParallelGC, for p99 latency G1 (the default)."
fi
if [ "${GCNAME:-}" = "G1" ] && [ -n "${XMX:-}" ] && [ "$(num "${XMX:-0}")" -lt 1073741824 ] 2>/dev/null && [ "$NPROC" -le 2 ]; then
  finding INFO "G1 may be heavy for a small heap ($(bmb "$XMX") MB) with $NPROC cores" \
    "G1's background threads and region bookkeeping are a cost rather than a benefit at this scale." \
    "Measure -XX:+UseSerialGC and compare (--compare shows you the difference)."
fi
if [ "${COMPOOPS:-true}" = "false" ] && [ -n "${XMX:-}" ]; then
  finding WARN "Compressed OOPs are off (heap $(bmb "$XMX") MB)" \
    "Past 32 GB of heap the JVM switches to 64-bit pointers, and memory use for the same data grows by ~20-50%." \
    "Try pulling the heap below 31 GB - more often than not MORE objects fit than in a 32 GB heap."
fi
if [ "${EXPLICITGC:-false}" != "true" ] && grep -qi 'System.gc' "$OUT/cpu-frames.tsv" 2>/dev/null; then
  finding WARN "A System.gc() call showed up in the profile" \
    "A manually triggered Full GC stops the whole application. It usually comes from a library (RMI, NIO)." \
    "Pass -XX:+DisableExplicitGC; if you use RMI, also raise the -Dsun.rmi.dgc.*.gcInterval values."
fi

# --- Summary ---
echo
printf '%s────────────────────────────────────────────────────────────%s\n' "$B" "$Z"
if [ "$CRIT" -gt 0 ]; then
  printf '  %sRESULT: %d critical, %d warnings.%s Fix the critical ones first.\n' "$R$B" "$CRIT" "$WARN" "$Z"
elif [ "$WARN" -gt 0 ]; then
  printf '  %sRESULT: nothing critical, %d warnings.%s\n' "$Y$B" "$WARN" "$Z"
else
  printf '  %sRESULT: nothing crossed the thresholds.%s\n' "$G$B" "$Z"
  echo '  If the application is still slow, in this order:'
  echo '    1) ./diagnose.sh '"$PID"' --full   (wait/lock analysis - non-CPU bottlenecks)'
  echo '    2) measure again under load      (an idle measurement misleads)'
  echo '    3) the bottleneck may not be in the app at all: database, network, disk'
fi
echo
echo "  All output: $OUT"
[ -n "${JFRF:-}" ] && [ -s "${JFRF:-/nonexistent}" ] && {
  echo "  Next step:"
  echo "    ./scripts/jfr-summary.sh $JFRF   # deep analysis in the terminal"
  echo "    ./scripts/jmc-open.sh    $JFRF   # open in JMC (launches correctly with JDK 21)"
}
[ -s "$OUT/cpu.html" ] && echo "    in a browser: $OUT/cpu.html   (read the width, not the height)"
echo "  To measure the difference after a fix:"
echo "    ./scripts/diagnose.sh $PID --compare $OUT"
printf '%s────────────────────────────────────────────────────────────%s\n' "$B" "$Z"

# The counters live in a subshell, so we carry them back out through a file.
printf 'CRIT=%s\nWARN=%s\nFIND=%s\n' "$CRIT" "$WARN" "$FIND_N" > "$OUT/.result"

} 2>&1 | tee "$OUT/report.txt"

# strip the colour codes out of the report file
sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/report.txt" 2>/dev/null || true

CRIT=0; WARN=0; FIND=0
# shellcheck disable=SC1090
[ -f "$OUT/.result" ] && . "$OUT/.result"
rm -f "$OUT/.result"

# ------------------------------------------------------------------- JSON
if [ "$JSON" = "1" ]; then
  {
    printf '{\n'
    printf '  "time": "%s",\n' "$(date -Iseconds)"
    printf '  "pid": %s,\n' "$PID"
    printf '  "output": "%s",\n' "$(json_escape "$OUT")"
    printf '  "critical": %s,\n  "warnings": %s,\n' "${CRIT:-0}" "${WARN:-0}"
    printf '  "metrics": {\n'
    awk -F= 'NF==2 && $2!="" {
        gsub(/"/,"",$2)
        printf "%s    \"%s\": \"%s\"", (n++ ? ",\n" : ""), $1, $2
      } END{ if(n) printf "\n" }' "$METRICS"
    printf '  },\n'
    printf '  "findings": [\n'
    awk '{ printf "%s    %s", (n++ ? ",\n" : ""), $0 } END{ if(n) printf "\n" }' "$FIND_JSON"
    printf '  ]\n}\n'
  } > "$OUT/summary.json"
  echo "JSON summary: $OUT/summary.json"
fi
rm -f "$FIND_JSON"

# Exit code, so cron/CI can tell whether the run was actually clean.
if [ "${CRIT:-0}" -gt 0 ]; then exit 2
elif [ "${WARN:-0}" -gt 0 ]; then exit 1
else exit 0; fi
