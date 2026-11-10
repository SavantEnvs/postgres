#!/usr/bin/env bash
#
# mayhem/test.sh — RUN PostgreSQL's own regression suite (src/test/regress, `make check`) against the
# normal-flags build that mayhem/build.sh left in mayhem/bld-test. pg_regress runs 240+ SQL scripts
# and diffs each result against upstream's golden expected/*.out, so a server that does nothing,
# or the wrong thing, fails.
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

BLD="$SRC/mayhem/bld-test"
[ -x "$BLD/src/test/regress/pg_regress" ] || { echo "missing $BLD/src/test/regress/pg_regress: mayhem/build.sh did not build the suite" >&2; emit_ctrf "pg_regress" 0 1; exit 1; }
[ -d "$BLD/tmp_install" ] || { echo "missing $BLD/tmp_install: mayhem/build.sh did not stage the install" >&2; emit_ctrf "pg_regress" 0 1; exit 1; }

LOG="$(mktemp "${TMPDIR:-/tmp}/pg-regress.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
# NO_TEMP_INSTALL: reuse the tree build.sh staged, so nothing is compiled or installed here.
make -C "$BLD/src/test/regress" check NO_TEMP_INSTALL=1 >"$LOG" 2>&1
cat "$LOG"

passed=$(grep -cE '^ok [0-9]+ ' "$LOG" || true)
failed=$(grep -cE '^not ok [0-9]+ ' "$LOG" || true)
# A run that executed (almost) nothing, e.g. a neutered server, must not pass: upstream ships 240+ tests.
if [ "$passed" -lt 200 ] || ! grep -qE '^# All [0-9]+ tests passed\.' "$LOG"; then
  [ "$failed" -gt 0 ] || failed=1
fi
emit_ctrf "pg_regress" "$passed" "$failed"
