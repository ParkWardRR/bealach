// Command pin-dashboard regenerates the table of pins in the front door's README from the
// lock files in each repository's main branch.
//
//	go run ./cmd/pin-dashboard --readme ../README.md            rewrite the table
//	go run ./cmd/pin-dashboard --readme ../README.md --check    fail if it is out of date
//
// The "Behind" column counts the releases cut after each pin, read from this repository's
// own tags. It exists because a stale pin is otherwise invisible: the dashboard sat four
// releases behind for days, and nothing in CI could notice, because nothing read its pin.
package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/pindash"
)

const owner = "ParkWardRR"

func get(repo, file string) []byte {
	resp, err := http.Get(fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/main/%s", owner, repo, file))
	if err != nil {
		fmt.Fprintln(os.Stderr, "pin-dashboard:", err)
		os.Exit(2)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode != 200 {
		fmt.Fprintf(os.Stderr, "pin-dashboard: %s/%s: %s\n", repo, file, resp.Status)
		os.Exit(2)
	}
	b, _ := io.ReadAll(resp.Body)
	return b
}

// releases lists the contract releases, oldest first, from the tags of the repository this
// is run in. An empty result is not fatal: Render then omits the column rather than
// claiming every pin is current.
func releases() pindash.Releases {
	out, err := exec.Command("git", "tag", "-l", "contracts-v*").Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "pin-dashboard: cannot read tags, omitting the Behind column:", err)
		return nil
	}
	tags := strings.Fields(string(out))
	// Sort by version, not lexically, or contracts-v0.10.0 would sort before v0.2.0.
	sort.Slice(tags, func(i, j int) bool { return less(tags[i], tags[j]) })
	return tags
}

func less(a, b string) bool {
	x, y := parts(a), parts(b)
	for i := 0; i < 3; i++ {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return a < b
}

func parts(tag string) [3]int {
	var v [3]int
	for i, f := range strings.SplitN(strings.TrimPrefix(tag, "contracts-v"), ".", 3) {
		if i < 3 {
			v[i], _ = strconv.Atoi(f)
		}
	}
	return v
}

func main() {
	readme := flag.String("readme", "../README.md", "the document holding the pins block")
	check := flag.Bool("check", false, "do not write; exit 1 if the block is out of date")
	flag.Parse()

	var repos []pindash.Repo
	for _, r := range []struct{ name, display string }{
		{"cairn-vehicle-server", "cairn-vehicle-server"},
		{"cairn-vehicle-web-dashboard", "cairn-vehicle-web-dashboard"},
		{"cairn-esp32-device-firmware", "cairn-esp32-device-firmware"},
		{"cairn-ios-companion-app", "cairn-ios-companion-app"},
		{"cairn-modules", "cairn-modules"},
	} {
		repos = append(repos, pindash.Repo{
			Name: r.display, URL: "https://github.com/" + owner + "/" + r.name,
			Contracts: get(r.name, "contracts.lock"),
			Server:    get(r.name, "server.lock"),
			Interop:   get(r.name, "interop.lock"),
		})
	}
	table, err := pindash.Render(repos, releases())
	if err != nil {
		fmt.Fprintln(os.Stderr, "pin-dashboard:", err)
		os.Exit(2)
	}
	doc, err := os.ReadFile(*readme)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pin-dashboard:", err)
		os.Exit(2)
	}
	out, changed, err := pindash.Replace(string(doc), table)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pin-dashboard:", err)
		os.Exit(2)
	}
	switch {
	case *check && changed:
		fmt.Fprintln(os.Stderr, "pin-dashboard: the README's pins are out of date; run it without --check")
		os.Exit(1)
	case *check:
		fmt.Println("pin-dashboard: up to date")
	case changed:
		if err := os.WriteFile(*readme, []byte(out), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "pin-dashboard:", err)
			os.Exit(2)
		}
		fmt.Println("pin-dashboard: updated", *readme)
	default:
		fmt.Println("pin-dashboard: already up to date")
	}
}
