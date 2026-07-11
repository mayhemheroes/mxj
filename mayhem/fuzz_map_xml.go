// OSS-Fuzz harness for clbanning/mxj (OSS-Fuzz project "mxj", target FuzzMapXml).
//
// This is a LEGACY go-fuzz harness:
//   func FuzzMapXml(data []byte) int   -> built with go114-fuzz-build (`go-fuzz`).
//
// It mirrors OSS-Fuzz's projects/mxj/fuzz.go exactly: parse arbitrary bytes as XML
// into an mxj.Map via NewMapXml, then re-serialise the map back to XML with Map.Xml().
// The fuzzed surface is the XML decoder (NewMapXml -> xmlToMapParser in xml.go) and the
// map->XML encoder (Map.Xml -> mapToXmlIndent). err returns are treated as
// uninteresting (return 0); a clean round-trip scores 1.
//
// It lives in package mxj (the repo-root package, same as OSS-Fuzz which COPYs fuzz.go
// into the repo root) and is gated behind the `gofuzz` build tag — matching OSS-Fuzz's
// `compile_go_fuzzer . FuzzMapXml fuzz_map_xml gofuzz` — so it only compiles for the
// fuzz build and never pollutes the normal `go test ./...` suite.

//go:build gofuzz
// +build gofuzz

package mxj

func FuzzMapXml(data []byte) int {
	m, err := NewMapXml(data)
	if err != nil {
		return 0
	}

	_, err = m.Xml()
	if err != nil {
		return 0
	}

	return 1
}
