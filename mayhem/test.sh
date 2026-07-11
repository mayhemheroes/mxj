#!/usr/bin/env bash
#
# mxj/mayhem/test.sh — RUN clbanning/mxj's OWN Go test suite (`go test ./...`) and emit a
# CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: mxj ships a large behavioural suite (xml_test, xml2_test, xml3_test,
# xmlseq_test, json_test, keyvalues_test, updatevalues_test, leafnode_test, anyxml_test, the
# j2x/ and x2j-wrapper/ subpackages, etc.) that asserts known-answer XML<->map<->JSON results
# (go-cmp / string equality against expected output). They assert BEHAVIOUR, not "exits 0", so a
# no-op / `return nil` patch that breaks the parser FAILS this oracle.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (which is statically linked
# and thus immune to the LD_PRELOAD sabotage mechanism), this script also executes
# /mayhem/fuzz_map_xml (dynamically linked, ASan+libFuzzer) against a known corpus entry and
# asserts specific libFuzzer output strings ("Executed ... in"). When the SABOTAGE MECHANISM
# (LD_PRELOAD _exit(0)) neuters the fuzz binary, it exits silently and the grep fails —
# proving the oracle detects sabotage (not reward-hackable).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

# Run only the packages that actually CONTAIN tests. mxj's examples/ directory is NOT a test
# package — it is a bundle of ~31 standalone `package main` demo programs that each declare their
# own main()/vars, so `go test ./...` fails to even BUILD that directory ("main redeclared").
# That collision is pre-existing and unrelated to our integration (examples/ ships zero _test.go
# files, so it contributes no assertions). Enumerating the test-bearing packages keeps every real
# behavioural package (mxj root, j2x, x2j-wrapper, ...) while skipping the un-buildable demo dir,
# so the oracle stays honest (it still runs all of mxj's known-answer XML<->map<->JSON tests).
echo "=== enumerating packages that contain _test.go ==="
mapfile -t PKGS < <(go list ./... 2>/dev/null | while read -r p; do
  d="${p#github.com/clbanning/mxj/v2}"; d="${d#/}"; d="${d:-.}"
  if ls "$SRC/$d"/*_test.go >/dev/null 2>&1; then echo "$p"; fi
done)
if [ "${#PKGS[@]}" -eq 0 ]; then
  echo "no test packages found" >&2; emit_ctrf "go-test" 0 1 0; exit 1
fi
printf '  %s\n' "${PKGS[@]}"

echo "=== running: go test -count=1 -json <test packages> ==="
# -json gives machine-parseable per-test events; mirror stdout for humans via a separate pass.
# -count=1 bypasses the build cache so tests always re-execute (behavioral oracle, not cached).
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -count=1 -json "${PKGS[@]}" > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test -count=1 "${PKGS[@]}" 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_map_xml binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/fuzz_map_xml IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known corpus entry and assert that libFuzzer emits "Executed" — proving it actually processed
# the input. The sabotage LD_PRELOAD neuters fuzz_map_xml (not in /usr/bin etc.), causing it to
# exit silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/fuzz_map_xml/testsuite/simple.xml"
if [ -x /mayhem/fuzz_map_xml ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzz_map_xml single-shot on known corpus ==="
  PROBE_OUT=$(/mayhem/fuzz_map_xml "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzz_map_xml executed the corpus input (XML parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzz_map_xml produced no 'Executed' output (parser inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
