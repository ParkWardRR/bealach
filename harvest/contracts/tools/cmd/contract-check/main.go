// Command contract-check validates the contracts/ tree (see package contractcheck).
//
//	go run ./cmd/contract-check ../contracts
package main

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/contractcheck"
)

func main() {
	root := "../contracts"
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	probs, err := contractcheck.Check(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "contract-check:", err)
		os.Exit(2)
	}
	if len(probs) > 0 {
		fmt.Fprintf(os.Stderr, "contract-check: %d problem(s) in %s:\n%s", len(probs), root, contractcheck.String(probs))
		os.Exit(1)
	}
	fmt.Printf("contract-check: %s is valid\n", root)
}
