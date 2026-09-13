#!/usr/bin/env bash
# Runs JMH WITHOUT Maven. Only javac + java are required.
# All output goes under $PERF_OUT (home); /tmp is never used.
# Usage: ./jmh-run.sh <Benchmark.java> [extra-classpath] [jmh-args...]
#   example: ./jmh-run.sh example/SpeedBenchmark.java "" -f 1 -wi 3 -i 5
#            ./jmh-run.sh example/SpeedBenchmark.java $HOME/myapp/lib/app.jar
#
# NOTE: the benchmark class must declare a package. JMH rejects the default
#       package with "Benchmark class should have package other than default".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/env.sh" >/dev/null
SRC="${1:?usage: $0 <Benchmark.java> [extra-classpath]}"; EXTRA="${2:-}"
LIB="$HERE/lib"
CP="$LIB/jmh-core-1.37.jar:$LIB/jopt-simple-5.0.4.jar:$LIB/commons-math3-3.6.1.jar"
[ -n "$EXTRA" ] && CP="$CP:$EXTRA"
OUT="$PERF_OUT/jmh"; rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/gen" "$OUT/tmp"

echo ">> compiling (JMH annotation processor runs now)..."
javac -cp "$CP" \
      -processorpath "$LIB/jmh-generator-annprocess-1.37.jar:$LIB/jmh-core-1.37.jar" \
      -d "$OUT/classes" -s "$OUT/gen" "$SRC"

echo ">> running..."
# -prof gc IS ESSENTIAL: bytes allocated per operation (gc.alloc.rate.norm) usually
# tells you more than the timing does.
# -jvmArgsAppend: the JVMs JMH forks should also write to home instead of /tmp.
java -Djava.io.tmpdir="$OUT/tmp" -cp "$OUT/classes:$CP" org.openjdk.jmh.Main \
     -prof gc -rf json -rff "$OUT/result-$(date +%Y%m%d-%H%M%S).json" \
     -jvmArgsAppend "-Djava.io.tmpdir=$OUT/tmp" "${@:3}"
echo ">> $OUT/  (compare the result-*.json files from before and after your refactor)"
