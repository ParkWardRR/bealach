// Command ble-vectors writes contracts/ble/v1/vectors/device-info/vectors.json.
//
//	go run ./cmd/ble-vectors [path]
package main

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/blevectors"
)

func main() {
	path := "../contracts/ble/v1/vectors/device-info/vectors.json"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if err := os.WriteFile(path, blevectors.JSON(blevectors.Build()), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "ble-vectors:", err)
		os.Exit(2)
	}
	fmt.Println("ble-vectors: wrote", path)
}
