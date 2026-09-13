#!/usr/bin/env bash
#
# 00-setup.sh - Unpacks every tool into the package's OWN tools/ directory and
#               makes the GUI tools (JMC, MAT, VisualVM) actually RUNNABLE.
#
# Writes nothing to the system: no /opt, no /usr, no /var, no root.
#
# Usage:
#   ./00-setup.sh                -> unpack what is missing, configure the GUI tools
#   ./00-setup.sh --reset        -> delete tools/ and unpack from scratch
#   ./00-setup.sh --no-plugins   -> do not install the VisualVM plugins
#   ./00-setup.sh --verify       -> unpack nothing, only check the current install
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$HERE/tools"
TMP="$TOOLS/.tmp"

RESET=0; PLUGINS=1; VERIFY_ONLY=0
for a in "$@"; do
  case "$a" in
    --reset)      RESET=1 ;;
    --no-plugins) PLUGINS=0 ;;
    --verify)     VERIFY_ONLY=1 ;;
    -h|--help)    sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a"; sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
done

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=""; R=""; Y=""; G=""; Z=""; fi
info() { printf '>> %s\n' "$*"; }
warn() { printf '%s!! %s%s\n' "$Y" "$*" "$Z"; }
err()  { printf '%sERROR: %s%s\n' "$R" "$*" "$Z" >&2; }

case "$HERE" in
  "$HOME"/*) : ;;
  *) warn "package lives outside home ($HERE). Policy says move it under \$HOME." ;;
esac

[ "$RESET" = "1" ] && { info "deleting tools/ (--reset)"; rm -rf "$TOOLS"; }
mkdir -p "$TOOLS" "$TMP"
trap 'rm -rf "$TMP"' EXIT

# ============================================================ ZIP EXTRACTION
# 'unzip' MAY NOT be installed on RHEL 9. We use whatever is available, in order.
# The bundled JDK's 'jar' comes first once it exists.
ZIP_METHOD=""
pick_zip_method() {
  [ -n "$ZIP_METHOD" ] && return 0
  if [ -x "$TOOLS/jdk21/bin/jar" ];      then ZIP_METHOD="$TOOLS/jdk21/bin/jar"
  elif command -v unzip >/dev/null 2>&1; then ZIP_METHOD="unzip"
  elif command -v jar   >/dev/null 2>&1; then ZIP_METHOD="jar"
  elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jar" ]; then ZIP_METHOD="$JAVA_HOME/bin/jar"
  elif command -v python3 >/dev/null 2>&1; then ZIP_METHOD="python3"
  elif command -v bsdtar  >/dev/null 2>&1; then ZIP_METHOD="bsdtar"
  else return 1; fi
  return 0
}
unzip_to() { # unzip_to <zip> <target-dir>
  local z="$1" d="$2"
  pick_zip_method || {
    err "no tool available to read zip files. One of unzip, jar (JDK), python3 or bsdtar is required."
    return 1
  }
  mkdir -p "$d"
  case "$ZIP_METHOD" in
    unzip)   unzip -q -o "$z" -d "$d" ;;
    python3) python3 -m zipfile -e "$z" "$d" ;;
    bsdtar)  bsdtar -xf "$z" -C "$d" ;;
    *)       ( cd "$d" && "$ZIP_METHOD" xf "$z" ) ;;   # jar
  esac
}

# ==================================================== JOINING SPLIT ARCHIVES
# GitHub caps files at 100 MB, so the large archives are split with "zip -s":
#   name.z01 name.z02 ... name.zip   (name.zip is the LAST part, it holds the
#                                     central directory)
join_split() { # join_split <name.zip> -> prints the path of the joined file
  local last="$1" base="${1%.zip}" target
  target="$TMP/$(basename "$base")-joined.zip"
  local parts=() p
  for p in "$base".z[0-9][0-9]; do [ -f "$p" ] && parts+=("$p"); done
  if [ ${#parts[@]} -eq 0 ]; then echo "$last"; return 0; fi   # not split
  [ -s "$target" ] && { echo "$target"; return 0; }

  # CAREFUL: this function's stdout is read by the caller AS A PATH.
  # Every progress/error message must go to stderr.
  #
  # Plain 'cat' is NOT enough: every central directory offset is written
  # relative to its own part. Concatenating naively makes unzip say
  # "overlapped components" and jar say "invalid LOC header". So we use a
  # joiner that fixes the offsets too.
  local joiner="$HERE/scripts/zip-join.py"
  local py=""
  for p in python3 python /usr/libexec/platform-python; do
    command -v "$p" >/dev/null 2>&1 && { py="$p"; break; }
    [ -x "$p" ] && { py="$p"; break; }
  done

  if [ -n "$py" ] && [ -f "$joiner" ]; then
    "$py" "$joiner" "$last" "$target" >&2 || { rm -f "$target"; return 1; }
  elif command -v zip >/dev/null 2>&1; then
    info "joining split archive (zip -s 0): $(basename "$base")" >&2
    zip -q -s 0 "$last" --out "$target" >&2 || { rm -f "$target"; return 1; }
  else
    err "cannot join the split archive: $(basename "$last")"
    cat >&2 <<'HELP'
   This archive was split into .z01 + .zip because of GitHub's 100 MB limit.
   To join it you need ONE of:
     - python3            (installed by default on RHEL 9)
     - zip                (dnf install zip)
   If you have neither, join it on a machine with internet and copy it over:
     zip -s 0 pmd-dist-7.27.0-bin.zip --out pmd-joined.zip
HELP
    return 1
  fi
  echo "$target"
}

# ================================================================ UNPACKING
# Finds the "product root" inside an archive:
#   - if there is a single directory, descend into it (for PMD that is 2 levels:
#     dist/ -> pmd-bin-*/)
#   - if there are several top-level entries (JMC: "JDK Mission Control/" plus
#     "legal/"), the directory containing the marker file is the product root.
product_root() { # product_root <dir> [marker]
  local d="$1" marker="${2:-}"
  if [ -n "$marker" ]; then
    local found
    found=$(find "$d" -maxdepth 3 -name "$marker" -print 2>/dev/null | head -1)
    [ -n "$found" ] && { dirname "$found"; return 0; }
  fi
  local level=0
  while [ $level -lt 4 ]; do
    local n; n=$(find "$d" -mindepth 1 -maxdepth 1 | wc -l)
    [ "$n" -eq 1 ] || break
    local only; only=$(find "$d" -mindepth 1 -maxdepth 1)
    [ -d "$only" ] || break
    d="$only"; level=$((level+1))
  done
  echo "$d"
}

unpack() { # unpack <archive> <target-dir-name> [marker]
  local archive="$1" target="$TOOLS/$2" marker="${3:-}"
  [ -d "$target" ] && { info "$2 already unpacked, skipping"; return 0; }
  [ -f "$archive" ] || { warn "archive missing, skipping: $archive"; return 0; }

  local stage="$TMP/stage-$2"; rm -rf "$stage"; mkdir -p "$stage"
  info "$(basename "$archive")  ->  tools/$2"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$stage" ;;
    *.tar)          tar -xf  "$archive" -C "$stage" ;;
    *.zip)
      local joined; joined=$(join_split "$archive")
      unzip_to "$joined" "$stage" || return 1
      # There may be a tar nested inside (the JDK ships a plain .tar in a .zip)
      # -type f matters: a zip can contain a DIRECTORY named "X.tar".
      local inner; inner=$(find "$stage" -maxdepth 3 -type f -name '*.tar' -print 2>/dev/null | head -1)
      if [ -n "$inner" ]; then
        info "  unpacking inner archive: $(basename "$inner")" >&2
        local stage2="$TMP/stage2-$2"; rm -rf "$stage2"; mkdir -p "$stage2"
        tar -xf "$inner" -C "$stage2"
        rm -rf "$stage"; stage="$stage2"
      fi
      ;;
    *) warn "unknown archive type: $archive"; return 0 ;;
  esac

  local root; root=$(product_root "$stage" "$marker")
  mkdir -p "$target"
  ( shopt -s dotglob nullglob; mv "$root"/* "$target"/ )
  # Move whatever sits outside the product root too (e.g. JMC's legal/ directory)
  if [ "$root" != "$stage" ]; then
    ( shopt -s dotglob nullglob
      for rest in "$stage"/*; do
        case "$root" in "$rest"|"$rest"/*) continue ;; esac
        mv "$rest" "$target"/ 2>/dev/null || true
      done )
  fi
  rm -rf "$stage"
}

# ==================================================================== ORDER
if [ "$VERIFY_ONLY" = "0" ]; then
  # 1) JDK 21 FIRST: it runs MAT/JMC and provides the 'jfr' CLI and 'jar'.
  #    It ships as a plain .tar inside a split zip.
  JDKARC=$(find "$HERE/jdk" -maxdepth 1 -name 'OpenJDK21U-jdk_x64_linux_hotspot_*.tar.zip' 2>/dev/null | head -1)
  [ -n "$JDKARC" ] || JDKARC=$(find "$HERE/jdk" -maxdepth 1 -name 'OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz' 2>/dev/null | head -1)
  [ -n "$JDKARC" ] || { err "JDK 21 archive not found ($HERE/jdk)"; exit 1; }
  unpack "$JDKARC" jdk21 "release"
  ZIP_METHOD=""   # from here on we can use the bundled JDK's jar

  # A marker is only meaningful for files that sit IN the product root; asprof
  # lives under bin/ and visualvm.clusters under etc/, so those get no marker
  # (both archives have a single top-level directory, so descending is correct).
  unpack "$HERE/runtime/async-profiler-4.5-linux-x64.tar.gz"                 async-profiler
  unpack "$HERE/runtime/org.openjdk.jmc-9.1.2-linux.gtk.x86_64.tar.gz"       jmc            jmc.ini
  unpack "$HERE/runtime/MemoryAnalyzer-1.17.0.20260601-linux.gtk.x86_64.zip" mat            MemoryAnalyzer.ini
  unpack "$HERE/runtime/visualvm_221.zip"                                    visualvm
  unpack "$HERE/compile-time/spotbugs-4.10.4.tgz"                            spotbugs
  unpack "$HERE/compile-time/pmd-dist-7.27.0-bin.zip"                        pmd
  unpack "$HERE/compile-time/jacoco-0.8.15.zip"                              jacoco

  find "$TOOLS" -maxdepth 3 -name '*.sh' -exec chmod u+x {} \; 2>/dev/null || true
  for f in "$TOOLS/async-profiler/bin/"* "$TOOLS/pmd/bin/pmd" "$TOOLS/mat/MemoryAnalyzer" \
           "$TOOLS/mat/ParseHeapDump.sh" "$TOOLS/jmc/jmc" "$TOOLS/spotbugs/bin/spotbugs" \
           "$TOOLS/visualvm/bin/visualvm"; do
    [ -f "$f" ] && chmod u+x "$f" 2>/dev/null || true
  done
fi

JAVA21="$TOOLS/jdk21/bin/java"

# ============================================== PIN THE ECLIPSE PRODUCTS TO JDK 21
# MAT and JMC are built on Eclipse RCP and need Java 17+. With JDK 11 on the
# system they refuse to start, and the message is misleading:
#   "Version 11.0.x of the JVM is not suitable for this product. Version: 17 or greater"
#
# The Eclipse launcher reads the '-vm' line and the path on the line BELOW it
# from the .ini file. Two conditions apply: (1) it must come BEFORE '-vmargs'
# and (2) the path must be on its own line. We point at the java executable
# rather than the bin directory - that is the form Eclipse recommends, and some
# versions silently ignore the directory form.
pin_jdk() { # pin_jdk <ini-file>
  local ini="$1" name; name="$(basename "$ini")"
  [ -f "$ini" ] || { warn "$name not found - could not pin the JDK"; return 1; }
  [ -x "$JAVA21" ] || { warn "bundled JDK 21 missing - could not pin $name"; return 1; }

  # Drop any old/broken -vm block, then insert a fresh one right above -vmargs.
  awk -v java="$JAVA21" '
    BEGIN { written=0 }
    # a previous -vm line and the path line following it are dropped
    $0 == "-vm" { skip=1; next }
    skip == 1   { skip=0; next }
    $0 == "-vmargs" && written == 0 { print "-vm"; print java; written=1 }
    { print }
    END { if (written == 0) { print "-vm"; print java } }
  ' "$ini" > "$ini.new" && mv "$ini.new" "$ini"
  info "$name -> pinned to the bundled JDK 21 ($JAVA21)"
}

if [ "$VERIFY_ONLY" = "0" ]; then
  pin_jdk "$TOOLS/mat/MemoryAnalyzer.ini" || true
  pin_jdk "$TOOLS/jmc/jmc.ini"            || true

  # MAT's OWN heap. It ships with -Xmx1024m, which is not enough for MAT itself
  # to open even a 1-2 GB dump without an OOM. We raise it to half of machine RAM
  # (at least 2 GB, at most 8 GB). Rule of thumb: MAT's -Xmx should be at least
  # HALF the dump size; if you are opening an 8 GB dump, raise this line by hand.
  if [ -f "$TOOLS/mat/MemoryAnalyzer.ini" ]; then
    MATMB=$(awk '/^MemTotal:/{m=int($2/1024/2); if(m<2048)m=2048; if(m>8192)m=8192; print m}' /proc/meminfo 2>/dev/null)
    MATMB="${MATMB:-4096}"
    if grep -q -- '-Xmx' "$TOOLS/mat/MemoryAnalyzer.ini"; then
      OLD=$(grep -o -- '-Xmx[0-9]*[mMgG]' "$TOOLS/mat/MemoryAnalyzer.ini" | head -1)
      sed -i "s/^-Xmx[0-9]*[mMgG]\$/-Xmx${MATMB}m/" "$TOOLS/mat/MemoryAnalyzer.ini"
      info "MemoryAnalyzer.ini -> -Xmx${MATMB}m instead of ${OLD} (should be ~half the dump size)"
    else
      printf '%s\n' "-Xmx${MATMB}m" >> "$TOOLS/mat/MemoryAnalyzer.ini"
      info "MemoryAnalyzer.ini -> added -Xmx${MATMB}m"
    fi
  fi
fi

# ==================================================== VISUALVM PLUGINS
# VisualVM does NOT ship VisualGC, MBeans, Buffer Monitor, Threads Inspector,
# Startup Profiler or Tracer - every one of them is a separate plugin that is
# normally downloaded from the internet. Since there is no internet, the .nbm
# files live in the package.
#
# How they are installed: we unpack the netbeans/ tree inside each NBM into a
# separate "cluster" directory and hand that directory to VisualVM. That way the
# plugins are ENABLED ON FIRST LAUNCH - no wizard, no restart, no internet.
VVM_PLUGIN_SRC="$HERE/plugins/visualvm"
VVM_CLUSTER="$TOOLS/visualvm-plugins"

install_plugins() {
  [ -d "$VVM_PLUGIN_SRC" ] || { warn "plugin directory missing: $VVM_PLUGIN_SRC"; return 0; }
  local nbms=() f
  for f in "$VVM_PLUGIN_SRC"/*.nbm; do [ -f "$f" ] && nbms+=("$f"); done
  [ ${#nbms[@]} -gt 0 ] || { warn "no .nbm files to install"; return 0; }

  # Skip re-unpacking when the source has not changed
  local stamp="$VVM_CLUSTER/.source-stamp" now
  now=$(cd "$VVM_PLUGIN_SRC" && ls -la *.nbm | sha256sum | cut -c1-16)
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$now" ]; then
    info "VisualVM plugins up to date (${#nbms[@]} of them), skipping"
    return 0
  fi

  info "unpacking VisualVM plugins (${#nbms[@]} of them)..."
  rm -rf "$VVM_CLUSTER"; mkdir -p "$VVM_CLUSTER"
  local stage="$TMP/nbm"
  for f in "${nbms[@]}"; do
    rm -rf "$stage"; mkdir -p "$stage"
    if ! unzip_to "$f" "$stage" >/dev/null 2>&1; then
      warn "  could not unpack: $(basename "$f")"; continue
    fi
    if [ -d "$stage/netbeans" ]; then
      ( shopt -s dotglob nullglob; cp -r "$stage/netbeans/"* "$VVM_CLUSTER"/ )
      printf '   + %s\n' "$(basename "$f" .nbm)"
    else
      warn "  expected netbeans/ tree missing: $(basename "$f")"
    fi
  done
  rm -rf "$stage"
  # NetBeans identifies a cluster by its timestamp file
  touch "$VVM_CLUSTER/.lastModified"
  mkdir -p "$VVM_CLUSTER/update_tracking"
  echo "$now" > "$stamp"
  local n; n=$(find "$VVM_CLUSTER/config/Modules" -name '*.xml' 2>/dev/null | wc -l)
  info "$n plugin modules enabled (cluster: $VVM_CLUSTER)"
}

# JMC plugins (p2). The Adoptium build ALREADY bundles JOverflow, the JMX Console
# and the JMC Agent. Even so, if a p2 archive is dropped in we install it.
JMC_PLUGIN_SRC="$HERE/plugins/jmc"
install_jmc_plugins() {
  [ -d "$JMC_PLUGIN_SRC" ] || return 0
  local zips=() f
  for f in "$JMC_PLUGIN_SRC"/*.zip; do [ -f "$f" ] && zips+=("$f"); done
  [ ${#zips[@]} -gt 0 ] || return 0
  [ -x "$TOOLS/jmc/jmc" ] || { warn "JMC is not unpacked, cannot install plugins"; return 0; }
  for f in "${zips[@]}"; do
    info "installing JMC p2 plugin: $(basename "$f")"
    "$TOOLS/jmc/jmc" -nosplash -consoleLog \
      -application org.eclipse.equinox.p2.director \
      -repository "jar:file:$f!/" \
      -installIU "$(basename "$f" .zip)" \
      -destination "$TOOLS/jmc" -profile DefaultProfile 2>&1 | sed 's/^/    /' \
      || warn "  install failed (the IU name may differ from the zip name): $(basename "$f")"
  done
}

if [ "$VERIFY_ONLY" = "0" ] && [ "$PLUGINS" = "1" ]; then
  install_plugins
  install_jmc_plugins
fi

# ============================================================ VERIFICATION
echo
printf '%s--- VERIFICATION ---%s\n' "$B" "$Z"
PROBLEMS=0
check() { # check <label> <path> [must-be-executable]
  local label="$1" path="$2" exe="${3:-0}"
  if [ ! -e "$path" ]; then printf '  %s[MISSING]%s %-24s %s\n' "$R" "$Z" "$label" "$path"; PROBLEMS=$((PROBLEMS+1)); return; fi
  if [ "$exe" = "1" ] && [ ! -x "$path" ]; then
    printf '  %s[NOEXEC ]%s %-24s not executable\n' "$Y" "$Z" "$label"; PROBLEMS=$((PROBLEMS+1)); return
  fi
  printf '  %s[ok     ]%s %-24s\n' "$G" "$Z" "$label"
}
check "JDK 21 (java)"      "$TOOLS/jdk21/bin/java"            1
check "JDK 21 (jfr CLI)"   "$TOOLS/jdk21/bin/jfr"             1
check "async-profiler"     "$TOOLS/async-profiler/bin/asprof" 1
check "JMC launcher"       "$TOOLS/jmc/jmc"                   1
check "JMC jmc.ini"        "$TOOLS/jmc/jmc.ini"
check "MAT launcher"       "$TOOLS/mat/MemoryAnalyzer"        1
check "MAT headless"       "$TOOLS/mat/ParseHeapDump.sh"      1
check "VisualVM launcher"  "$TOOLS/visualvm/bin/visualvm"     1
check "SpotBugs"           "$TOOLS/spotbugs/bin/spotbugs"     1
check "PMD"                "$TOOLS/pmd/bin/pmd"               1

# The SpotBugs rule packs are NOT unpacked: static-scan.sh hands the jars to
# SpotBugs with -pluginList, and in IntelliJ you add the same jars from disk.
NPACKS=$(find "$HERE/spotbugs-rule-packs" -maxdepth 1 -name '*.jar' 2>/dev/null | wc -l)
if [ "$NPACKS" -gt 0 ]; then
  printf '  %s[ok     ]%s %-24s %s jar(s)\n' "$G" "$Z" "SpotBugs rule packs" "$NPACKS"
else
  printf '  %s[  -    ]%s %-24s none found in spotbugs-rule-packs/\n' "$Y" "$Z" "SpotBugs rule packs"
fi

# Did the -vm line actually land? This is where people get stuck most often.
verify_vm() { # verify_vm <ini> <label>
  local ini="$1" label="$2"
  [ -f "$ini" ] || return 0
  local line; line=$(grep -n -x -- '-vm' "$ini" | head -1 | cut -d: -f1)
  if [ -z "$line" ]; then
    printf '  %s[BROKEN ]%s %-24s no -vm line -> will try to start with system JDK 11\n' "$R" "$Z" "$label"
    PROBLEMS=$((PROBLEMS+1)); return
  fi
  local path; path=$(sed -n "$((line+1))p" "$ini")
  local vmargs; vmargs=$(grep -n -x -- '-vmargs' "$ini" | head -1 | cut -d: -f1)
  if [ -n "$vmargs" ] && [ "$line" -gt "$vmargs" ]; then
    printf '  %s[BROKEN ]%s %-24s -vm comes AFTER -vmargs -> Eclipse ignores it\n' "$R" "$Z" "$label"
    PROBLEMS=$((PROBLEMS+1)); return
  fi
  if [ ! -x "$path" ]; then
    printf '  %s[BROKEN ]%s %-24s -vm path does not run: %s\n' "$R" "$Z" "$label" "$path"
    PROBLEMS=$((PROBLEMS+1)); return
  fi
  # If JAVA_TOOL_OPTIONS/_JAVA_OPTIONS is set, java prints "Picked up ..." first;
  # the version line follows those.
  local ver; ver=$("$path" -version 2>&1 | grep -v '^Picked up ' | head -1)
  printf '  %s[ok     ]%s %-24s %s\n' "$G" "$Z" "$label" "$ver"
}
verify_vm "$TOOLS/jmc/jmc.ini"            "JMC -> JDK 21"
verify_vm "$TOOLS/mat/MemoryAnalyzer.ini" "MAT -> JDK 21"

if [ -d "$VVM_CLUSTER/config/Modules" ]; then
  N=$(find "$VVM_CLUSTER/config/Modules" -name '*.xml' 2>/dev/null | wc -l)
  printf '  %s[ok     ]%s %-24s %s modules\n' "$G" "$Z" "VisualVM plugins" "$N"
else
  printf '  %s[  -    ]%s %-24s not installed (--no-plugins?)\n' "$Y" "$Z" "VisualVM plugins"
fi

# The system java version - this is where people see WHY JMC would not start.
SYSJAVA=$(command -v java 2>/dev/null || true)
if [ -n "$SYSJAVA" ]; then
  SYSVER=$("$SYSJAVA" -version 2>&1 | grep -v '^Picked up ' | head -1)
  printf '  %s[info   ]%s system java: %s\n' "$B" "$Z" "$SYSVER"
  printf '            JMC/MAT do NOT use this one - they use the JDK 21 above.\n'
fi

echo
if [ "$PROBLEMS" -gt 0 ]; then
  printf '%s%d problem(s).%s If it persists: ./scripts/00-setup.sh --reset\n' "$R$B" "$PROBLEMS" "$Z"
else
  printf '%sEverything is ready.%s Tools: %s\n' "$G$B" "$Z" "$TOOLS"
fi
cat <<'DONE'

Now:
  source scripts/env.sh          # puts asprof, pmd, spotbugs, jmc, mat, visualvm in reach

Then:
  ./scripts/diagnose.sh <pid>    # full diagnosis in one command (terminal)
  ./scripts/jmc-open.sh          # JMC (opens correctly, with JDK 21)
  ./scripts/visualvm-open.sh     # VisualVM (plugins already installed)
DONE
