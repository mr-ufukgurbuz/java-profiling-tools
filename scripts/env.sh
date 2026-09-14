# Usage:  source scripts/env.sh
_P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROFILING_HOME="$_P"
export TOOLS="$_P/tools"

# EVERYTHING is written under $HOME. /tmp and /var are never used.
export PERF_OUT="${PERF_OUT:-$HOME/perf-out}"
mkdir -p "$PERF_OUT/tmp"
export TMPDIR="$PERF_OUT/tmp"          # for native tools
export _JAVA_OPTIONS_TMP="-Djava.io.tmpdir=$PERF_OUT/tmp"   # passed explicitly to java tools

export ASPROF="$TOOLS/async-profiler/bin/asprof"
export JFRCLI="$TOOLS/jdk21/bin/jfr"
export JAVA21="$TOOLS/jdk21/bin/java"
# These jars are committed inside .tar.xz archives (a git host that rejects
# .jar uploads still has to be able to take this repository), so they live in
# tools/ after 00-setup.sh has run - not next to their archive.
export JOL="$TOOLS/jol/jol-cli-0.17-full.jar"
export GCVIEWER="$TOOLS/gcviewer/gcviewer-1.37.jar"
export JFRCONV="$TOOLS/jfr-converter/jfr-converter.jar"
export PATH="$TOOLS/pmd/bin:$TOOLS/spotbugs/bin:$TOOLS/async-profiler/bin:$PATH"

# For the GUI tools we alias the WRAPPER scripts, not the launchers themselves.
# Reason: JMC (and MAT) need Java 17+. If your system has JDK 11 installed and you
# run the launcher directly, it fails with "Version 11.0.x of the JVM is not
# suitable for this product". The wrappers pass the bundled JDK 21 explicitly via
# -vm, and the VisualVM wrapper also wires in the plugin cluster.
alias jmc="$_P/scripts/jmc-open.sh"
alias visualvm="$_P/scripts/visualvm-open.sh"
alias mat="$TOOLS/mat/MemoryAnalyzer &"
alias diagnose="$_P/scripts/diagnose.sh"

echo "PROFILING_HOME=$PROFILING_HOME"
echo "PERF_OUT=$PERF_OUT   <- all output goes here"
echo "commands: diagnose, asprof, pmd, spotbugs, jmc, mat, visualvm"
