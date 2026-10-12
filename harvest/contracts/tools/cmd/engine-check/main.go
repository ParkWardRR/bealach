// Command engine-check runs the formula-language vectors of contracts/engine/v1
// against this repository's independent Go implementation.
//
//	engine-check                              # ../contracts/engine/v1/vectors/expr.txt
//	engine-check path/to/expr.txt
//	engine-check -v                           # list every vector as it passes
//
// Why a third implementation: the language already has the firmware's Rust generator
// and its C evaluator. Those two were written together, so agreeing proves they were
// written together. This one was written from contracts/engine/v1/spec.md, and it is
// the independent consumer that contract's README names as its gate for leaving draft.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/enginelang"
)

func main() {
	verbose := flag.Bool("v", false, "print every vector, not only the failures")
	flag.Parse()

	path := filepath.Join("..", "contracts", "engine", "v1", "vectors", "expr.txt")
	if flag.NArg() > 0 {
		path = flag.Arg(0)
	}

	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "engine-check:", err)
		os.Exit(2)
	}
	defer f.Close()

	vectors, err := enginelang.ParseVectors(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "engine-check: %s: %v\n", path, err)
		os.Exit(2)
	}

	counts := map[enginelang.Kind]int{}
	failed := 0
	for _, v := range vectors {
		counts[v.Kind]++
		if why := v.Run(); why != "" {
			failed++
			fmt.Printf("FAIL %s line %d: %s\n", v.Kind, v.Line, why)
		} else if *verbose {
			fmt.Printf("ok   %s line %d\n", v.Kind, v.Line)
		}
	}

	fmt.Printf("engine-check: %d vectors (%d evaluate, %d reject, %d bytecode), %d failed\n",
		len(vectors), counts[enginelang.KindEval], counts[enginelang.KindReject],
		counts[enginelang.KindByte], failed)
	if failed > 0 {
		os.Exit(1)
	}
}
