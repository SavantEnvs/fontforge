#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer tests against the pre-built FontForge scripting binary (built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

FF="$SRC/build/test/bin/fontforge"
[ -x "$FF" ] || { echo "missing $FF — mayhem/build.sh should have built it" >&2; emit_ctrf "fontforge-kat" 0 1 0; exit 1; }
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

passed=0 failed=0

# kat <name> <expected KAT lines> <font> <glyph> [<generate-as>]
# Opens <font> through FontForge's loader and compares the KAT lines printed by probe.ff to golden values.
kat() {
  local name="$1" want="$2"; shift 2
  local got
  got="$(cd "$SCRATCH" && "$FF" -lang=ff -script "$SRC/mayhem/probe.ff" "$@" 2>/dev/null | grep -a '^KAT')"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1)); echo "PASS $name"
  else
    failed=$((failed + 1)); echo "FAIL $name"; echo "  want: $(echo "$want" | tr '\n' ';')"; echo "  got:  $(echo "$got" | tr '\n' ';')"
  fi
}

FONTS="$SRC/tests/fonts"
SEEDS="$SRC/mayhem"
BB='KAT font=BoxesAndBounds family=BoxesAndBounds'

kat sfd-load "$BB
KAT glyph=NameMe.1 width=378 bbox=63,57,315,309" "$FONTS/BoxesAndBounds.sfd" NameMe.1

for ext in ttf otf pfa; do
  kat "sfd-to-$ext-roundtrip" "$BB
KAT glyph=NameMe.1 width=378 bbox=63,57,315,309
KAT regen glyph=NameMe.1 width=378 bbox=63,57,315,309" "$FONTS/BoxesAndBounds.sfd" NameMe.1 "$SCRATCH/rt.$ext"
done

kat ttf-load "$BB
KAT glyph=NameMe.2 width=378 bbox=63,57,315,309" "$SEEDS/fuzz_ttf/testsuite/BoxesAndBounds.ttf" NameMe.2
kat woff2-load "KAT font=Cantarell-Regular family=Cantarell
KAT glyph=a width=1069 bbox=123,-20,889,1007" "$SEEDS/fuzz_ttf/testsuite/CantarellMin.woff2" a
kat otf-load "KAT font=ArabicKern family=ArabicKern
KAT glyph=uni0627 width=96 bbox=25,0,71,516" "$SEEDS/fuzz_ttf/testsuite/test1012.otf" uni0627
kat pfa-load "$BB
KAT glyph=NameMe.2 width=378 bbox=63,57,315,309" "$SEEDS/fuzz_postscript/testsuite/BoxesAndBounds.pfa" NameMe.2
kat cff-load "$BB
KAT glyph=NameMe.0 width=378 bbox=63,57,315,309" "$SEEDS/fuzz_cff/testsuite/BoxesAndBounds.cff" NameMe.0
kat svg-load "$BB
KAT glyph=NameMe.1 width=378 bbox=63,57,315,309" "$SEEDS/fuzz_svg/testsuite/BoxesAndBounds.svg" NameMe.1
kat dfont-load "$BB
KAT glyph=NameMe.2 width=378 bbox=63,57,315,309" "$SEEDS/fuzz_macfont/testsuite/BoxesAndBounds.dfont" NameMe.2
kat bdf-load "KAT font=VersionProbemedium family=VersionProbe
KAT glyph=A width=1000 bbox=0,0,0,0" "$SEEDS/fuzz_bitmap/testsuite/font-version.bdf" A

emit_ctrf "fontforge-kat" "$passed" "$failed" 0
