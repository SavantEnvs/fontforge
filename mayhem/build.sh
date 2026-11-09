#!/usr/bin/env bash
#
# mayhem/build.sh — build FontForge's fuzz harnesses and its (normal-flags) test binary.
#
# Runs in the commit image as `mayhem` in /mayhem. Every dependency comes from apt packages installed
# in the Dockerfile, so re-running this offline works. Build trees live in build/ (gitignored upstream).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_DIR="$SRC/build/fuzz"
TEST_DIR="$SRC/build/test"

CMAKE_COMMON=(-G Ninja
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DENABLE_GUI=OFF -DENABLE_PYTHON_SCRIPTING=OFF -DENABLE_PYTHON_EXTENSION=OFF
  -DENABLE_DOCS=OFF -DENABLE_LIBREADLINE=OFF -DBUILD_SHARED_LIBS=OFF)

# CMake drops its command-line -D options when it notices the compiler path changed (the image build runs
# under ccache's PATH, a later re-run does not), so start from an empty tree in that case.
for dir in "$TEST_DIR" "$FUZZ_DIR"; do
  if [ -f "$dir/CMakeCache.txt" ] && ! grep -qx "CMAKE_C_COMPILER:[A-Z]*=$(command -v "$CC")" "$dir/CMakeCache.txt"; then
    rm -rf "$dir"
  fi
done

# 1) The test binary: the project's NORMAL flags, built first into its own tree.
cmake -S . -B "$TEST_DIR" "${CMAKE_COMMON[@]}" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS" --target fontforgeexe

# 2) The library under test: sanitized, DWARF 3, SanCov on the library code itself.
# Relaxed UBSan checks: Type 1 eexec decryption (parsepfa.c) overflows a signed int by design on every
# PostScript font, the PDF reader does null+0 pointer arithmetic on empty buffers, and the getc()-based readers
# shift a negative EOF (-1<<8) on every truncated file; all three flood.
UBSAN_RELAX="-fno-sanitize=signed-integer-overflow,pointer-overflow,shift-base"
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B "$FUZZ_DIR" "${CMAKE_COMMON[@]}" -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target fontforgeexe

# Reuse the project's own compile flags (include dirs, defines) and link line for the harnesses.
COMPILE_CMDS="$(cd "$FUZZ_DIR" && ninja -t commands lib/libfontforge.a)"
CC_LINE="$(sed -n '/scripting\.c\.o/{s/ -o .*//;p;q}' <<< "$COMPILE_CMDS")"
eval "CC_TOK=($CC_LINE)"
HARNESS_INC=()
for ((i = 0; i < ${#CC_TOK[@]}; i++)); do
  case "${CC_TOK[i]}" in
    -I*|-D*) HARNESS_INC+=("${CC_TOK[i]}") ;;
    -isystem) HARNESS_INC+=(-isystem "${CC_TOK[i + 1]}") ;;
  esac
done
LINK_CMDS="$(cd "$FUZZ_DIR" && ninja -t commands fontforgeexe)"
read -r -a LINK_TOK <<< "$(tail -n1 <<< "$LINK_CMDS")"
HARNESS_LIBS=()
for tok in "${LINK_TOK[@]}"; do
  case "$tok" in
    lib/libfontforge.a) HARNESS_LIBS+=("$FUZZ_DIR/$tok") ;;
    *.so|*.a) HARNESS_LIBS+=("$tok") ;;
  esac
done
HARNESS_LIBS+=(-lm)

# 3) Harness objects shared by every target.
HOBJ="$SRC/build/harness"
mkdir -p "$HOBJ"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$HOBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$HOBJ/lsan_off.o"

# 4) One binary per file-format family; FF_EXT picks the extension-driven reader FontForge falls back to.
build_target() {
  local name="$1" ext="$2"
  local obj="$HOBJ/${name}.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -DFF_EXT="\"$ext\"" \
    "${HARNESS_INC[@]}" -c "$SRC/mayhem/fuzz_load.c" -o "$obj"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$obj" "$HOBJ/lsan_off.o" "${HARNESS_LIBS[@]}" \
    -o "/mayhem/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$obj" "$HOBJ/standalone_main.o" "$HOBJ/lsan_off.o" "${HARNESS_LIBS[@]}" \
    -o "/mayhem/$name-standalone"
}

build_target fuzz_macfont    .dfont
