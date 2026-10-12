// Command link-check rewrites or checks the relative links in a repository's markdown.
//
//	link-check --root . --check                          # every relative link resolves?
//	link-check --root . --move old=new --move ... --write  # a set of moves already made with git mv
//
// With --write, every tracked text file is updated: markdown links are recomputed (both
// for links TO moved files and for links INSIDE moved files) and mentions of moved
// repo-root paths in any text are replaced.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ParkWardRR/cairn-driving-log-selfhosted/tools/links"
)

type moveFlags []string

func (m *moveFlags) String() string     { return strings.Join(*m, ",") }
func (m *moveFlags) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	root := flag.String("root", ".", "repository root")
	check := flag.Bool("check", false, "only report broken relative links")
	write := flag.Bool("write", false, "apply the rewrite")
	skip := flag.String("skip", "", "with --check: do not check markdown under this repo-relative directory (templates whose links resolve only in the repository they are written into)")
	var mv moveFlags
	flag.Var(&mv, "move", "old=new path move (repeatable); files or directories, repo-relative")
	flag.Parse()

	moves := links.Moves{}
	for _, s := range mv {
		kv := strings.SplitN(s, "=", 2)
		if len(kv) != 2 {
			fmt.Fprintln(os.Stderr, "bad --move", s)
			os.Exit(2)
		}
		moves[strings.TrimSuffix(kv[0], "/")] = strings.TrimSuffix(kv[1], "/")
	}

	out, err := exec.Command("git", "-C", *root, "ls-files", "-z").Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "git ls-files:", err)
		os.Exit(2)
	}
	var files, md []string
	for _, f := range bytes.Split(out, []byte{0}) {
		if len(f) == 0 {
			continue
		}
		p := string(f)
		files = append(files, p)
		if strings.HasSuffix(p, ".md") && (*skip == "" || !strings.HasPrefix(p, strings.TrimSuffix(*skip, "/")+"/")) {
			md = append(md, p)
		}
	}

	if *write {
		changed := 0
		for _, f := range files {
			abs := filepath.Join(*root, f)
			b, err := os.ReadFile(abs)
			if err != nil || bytes.IndexByte(b, 0) >= 0 || len(b) > 4<<20 {
				continue // missing (staged delete), binary, or huge
			}
			s := string(b)
			n := s
			if strings.HasSuffix(f, ".md") {
				n = links.Rewrite(n, moves.Old(f), f, moves)
			}
			n = links.ReplacePaths(n, moves)
			if n != s {
				if err := os.WriteFile(abs, []byte(n), 0o644); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(2)
				}
				changed++
				fmt.Println("rewrote", f)
			}
		}
		fmt.Printf("%d file(s) rewritten\n", changed)
	}

	if *check || *write {
		bad, err := links.Check(*root, md)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		for _, b := range bad {
			fmt.Println("BROKEN", b)
		}
		fmt.Printf("%d markdown file(s) checked, %d broken relative link(s)\n", len(md), len(bad))
		if len(bad) > 0 {
			os.Exit(1)
		}
	}
}
