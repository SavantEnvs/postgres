#!/usr/bin/env bash
#
# mayhem/build.sh — build PostgreSQL twice, out of tree (upstream's own VPATH configure build):
#   mayhem/bld-fuzz  sanitized + SanCov-instrumented backend objects, linked into the fuzz harnesses
#   mayhem/bld-test  the project's normal flags, for the regression suite that mayhem/test.sh runs
# Both directories are gitignored (mayhem/.gitignore), so a `git clean -ffdX` removes them and this
# script rebuilds from committed content only; nothing is fetched.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"
M="$SRC/mayhem"
HARNESSES="json_parser_fuzzer simple_query_fuzzer type_input_fuzzer"

# configure probes run sanitized test programs; leak reports there would fail the probes.
export ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
CONFIGURE_OPTS="--without-icu --without-readline --without-zlib --disable-nls"

# 1) Sanitized backend. -fsanitize=fuzzer-no-link adds SanCov to the project itself.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
mkdir -p "$M/bld-fuzz"
cd "$M/bld-fuzz"
[ -f GNUmakefile ] || ../../configure CC="$CC" CFLAGS="$FUZZ_CFLAGS" $CONFIGURE_OPTS >/dev/null
make -j"$MAYHEM_JOBS" submake-generated-headers >/dev/null
make -j"$MAYHEM_JOBS" -C src/backend submake-libpgport >/dev/null
make -j"$MAYHEM_JOBS" -C src/backend postgres >/dev/null

# 2) Harnesses: every backend object except main.o's `main`, which is renamed so libFuzzer's own
#    main() is used while main.o's other definitions (progname, ...) stay available.
OBJS=$(cat src/backend/*/objfiles.txt src/timezone/objfiles.txt | tr ' ' '\n' | grep -v '^src/backend/main/main.o$' | grep . | sort -u)
$CC $FUZZ_CFLAGS -D_GNU_SOURCE -Dmain=postgres_backend_main_unused -I src/include -I ../../src/include \
    -c ../../src/backend/main/main.c -o main_renamed.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.cc" -o lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o standalone_main.o

for h in $HARNESSES; do
    $CC $FUZZ_CFLAGS -D_GNU_SOURCE -I src/include -I ../../src/include -c "$M/harnesses/$h.c" -o "$h.o"
    LIBS="src/common/libpgcommon_srv.a src/port/libpgport_srv.a -lpthread -ldl -lrt -lm"
    $CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE "$h.o" main_renamed.o lsan_off.o $OBJS $LIBS -o "$SRC/$h"
    $CC $FUZZ_CFLAGS "$h.o" standalone_main.o main_renamed.o lsan_off.o $OBJS $LIBS -o "$SRC/$h-standalone"
done

# 3) Regression suite build with the project's normal flags (no sanitizer, no DWARF pinning).
mkdir -p "$M/bld-test"
cd "$M/bld-test"
[ -f GNUmakefile ] || (env -u CFLAGS -u LDFLAGS ../../configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" $CONFIGURE_OPTS >/dev/null)
make -j"$MAYHEM_JOBS" all >/dev/null
make -j"$MAYHEM_JOBS" -C src/test/regress all >/dev/null
make -j"$MAYHEM_JOBS" temp-install >/dev/null
