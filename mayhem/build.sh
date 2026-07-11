#!/usr/bin/env bash
#
# mxj/mayhem/build.sh — build clbanning/mxj's OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_go_fuzzer.
#
# OSS-Fuzz target (projects/mxj/build.sh):
#   compile_go_fuzzer . FuzzMapXml fuzz_map_xml gofuzz
# i.e. the LEGACY go-fuzz harness `func FuzzMapXml(data []byte) int` (mayhem/fuzz_map_xml.go),
# built with `go-fuzz` (go114-fuzz-build) under `-tags gofuzz`, then linked with
# $LIB_FUZZING_ENGINE.
#
# The harness parses arbitrary bytes as XML into an mxj.Map (NewMapXml) and re-serialises
# (Map.Xml). The fuzzed surface is mxj's XML decoder + map->XML encoder.
#
# We produce:
#   /mayhem/fuzz_map_xml   — OSS-Fuzz target (mxj.FuzzMapXml, go-fuzz -tags gofuzz, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# DWARF debug-info flags (§6.2 item 10): force DWARF-3 on the C shim compilation unit so the
# linked fuzz ELF carries DWARF < 4. go-fuzz-build emits DWARF on its own terms (DWARF 5 from
# the Go toolchain); the C/C++ link step is our control point. Thread GO_DEBUG_FLAGS into CGO
# so any cgo code also picks them up, and pass them explicitly on the final clang++ link.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain is at a fixed prefix (/opt/toolchains) so PATCH re-runs find the same cache
# regardless of $HOME. §6.2 item 8. Offline-first GOPROXY: file:// resolves from the in-image
# module cache, network fallback only for cache-misses on the first online build. §6.5.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOROOT="${GOROOT:-/opt/toolchains/go}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
mkdir -p "$GOPATH" "$GOCACHE"
# The go-fuzz / go-118-fuzz-build tools live on PATH via /opt/toolchains/go-path/bin.
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$GOPATH/bin:$PATH"

cd "$SRC"
go version

# The OSS-Fuzz harness (func FuzzMapXml) is part of package mxj (the repo-root package). OSS-Fuzz
# COPYs fuzz.go into the repo root; replicate that so go-fuzz sees FuzzMapXml in the mxj pkg.
# It is gated behind `//go:build gofuzz`, so it only compiles under -tags gofuzz and never affects
# the normal `go test ./...` suite.
cp "$SRC/mayhem/fuzz_map_xml.go" "$SRC/fuzz_map_xml.go"

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: mxj.FuzzMapXml via go-fuzz (LEGACY []byte harness), -tags gofuzz ───────────
#     Replica of `compile_go_fuzzer . FuzzMapXml fuzz_map_xml gofuzz`. The module path is
#     github.com/clbanning/mxj/v2 (versioned); pass it to go-fuzz so it resolves the repo-root pkg.
echo "=== building fuzz_map_xml (mxj.FuzzMapXml, go-fuzz -tags gofuzz) ==="
go-fuzz -tags gofuzz -func FuzzMapXml -o "$SRC/mayhem-build/fuzz_map_xml.a" \
    github.com/clbanning/mxj/v2
# Pass $GO_DEBUG_FLAGS on the final link so the C shim compilation unit carries DWARF-3 (§6.2 item 10).
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_map_xml.a" -o /mayhem/fuzz_map_xml
echo "built /mayhem/fuzz_map_xml"

echo "build.sh complete:"
ls -la /mayhem/fuzz_map_xml 2>&1 || true
