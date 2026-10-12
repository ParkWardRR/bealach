// Command uplink-vectors writes contracts/uplink/v1/vectors/vectors.json.
//
//	go run ./cmd/uplink-vectors [path]    default ../contracts/uplink/v1/vectors/vectors.json
//
// The output is deterministic; a test fails if the checked-in file differs from it.
package main

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/uplinkvectors"
)

func main() {
	path := "../contracts/uplink/v1/vectors/vectors.json"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if err := os.WriteFile(path, uplinkvectors.JSON(uplinkvectors.Build()), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "uplink-vectors:", err)
		os.Exit(2)
	}
	fmt.Println("uplink-vectors: wrote", path)
}
