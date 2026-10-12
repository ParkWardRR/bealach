// Command module-check validates contracts/module/v1 against its own vectors, and
// checks that its engine-field vocabulary still matches contracts/engine/v1.
//
//	module-check                 # ../contracts
//	module-check ../contracts
//	module-check -v
//
// Without this, module/v1's vectors are assertions rather than checks: the interesting
// rules of a module manifest are the ones a JSON Schema cannot state, and the two most
// valuable — that a required column exists in store/v1, and that the engine-field enum
// has not drifted from engine/v1 — can only be checked with the whole contracts tree in
// hand, which is exactly what this repository has.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/modulecheck"
)

func main() {
	verbose := flag.Bool("v", false, "print every vector, not only the failures")
	flag.Parse()

	root := filepath.Join("..", "contracts")
	if flag.NArg() > 0 {
		root = flag.Arg(0)
	}

	moduleSchema := filepath.Join(root, "module", "v1", "module.schema.json")
	engineSchema := filepath.Join(root, "engine", "v1", "acquisition.schema.json")
	storeSchema := filepath.Join(root, "store", "v1", "schema.json")
	vectorDir := filepath.Join(root, "module", "v1", "vectors")

	failed := 0
	fail := func(f string, a ...any) {
		failed++
		fmt.Printf("FAIL "+f+"\n", a...)
	}

	// The vocabulary check first: if the two enums have drifted, every engine-field
	// result below is suspect.
	for _, err := range modulecheck.CheckVocabulary(moduleSchema, engineSchema) {
		fail("vocabulary: %v", err)
	}

	store, err := modulecheck.LoadStore(storeSchema)
	if err != nil {
		fmt.Fprintln(os.Stderr, "module-check:", err)
		os.Exit(2)
	}
	fields, err := modulecheck.EngineFields(engineSchema)
	if err != nil {
		fmt.Fprintln(os.Stderr, "module-check:", err)
		os.Exit(2)
	}
	env := modulecheck.Env{Store: store, EngineFields: fields}

	vectors, err := modulecheck.LoadVectors(vectorDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "module-check:", err)
		os.Exit(2)
	}

	valid, invalid := 0, 0
	var manifests []*modulecheck.Manifest
	for _, v := range vectors {
		if v.ExpectError == "" {
			valid++
		} else {
			invalid++
		}
		rel, _ := filepath.Rel(root, v.Path)
		if why := v.Run(env); why != "" {
			fail("%s: %s", rel, why)
		} else if *verbose {
			fmt.Printf("ok   %s\n", rel)
		}
		// Every valid manifest also joins the set, so the cross-module rules are
		// exercised on real documents rather than on a fixture written for them.
		if v.ExpectError == "" && !v.IsQueries {
			if m, err := modulecheck.Decode(v.Body); err == nil {
				manifests = append(manifests, m)
			}
		}
	}

	for _, err := range modulecheck.CheckSet(manifests, env) {
		fail("the valid vectors do not form a usable module set: %v", err)
	}

	fmt.Printf("module-check: %d vectors (%d valid, %d invalid), %d modules as a set, %d failed\n",
		len(vectors), valid, invalid, len(manifests), failed)
	if failed > 0 {
		os.Exit(1)
	}
}
