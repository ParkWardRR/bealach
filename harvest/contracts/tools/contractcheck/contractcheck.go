// Package contractcheck validates the contracts/ tree of the front door: that every
// protocol version states what it is, that its machine-readable parts parse, and that
// nothing secret slipped into a directory whose whole purpose is to be copied around.
//
// It checks what is objectively checkable. That a vector is CORRECT is not decided here:
// that is what the independent implementations (Go, Rust, C) do against it in their own
// repositories.
package contractcheck

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var storeContractRe = regexp.MustCompile(`^store/v1\.\d+$`)

var statusRe = regexp.MustCompile(`(?i)status[^a-z]{0,6}.*?\b(stable|draft|reserved|deprecated)\b`)

// Problem is one thing wrong, with where.
type Problem struct{ Path, Msg string }

func (p Problem) String() string { return p.Path + ": " + p.Msg }

// Check validates the contracts directory at root and returns every problem found.
func Check(root string) ([]Problem, error) {
	var out []Problem
	add := func(p, m string) { out = append(out, Problem{p, m}) }

	for _, f := range []string{"README.md", "CHANGELOG.md"} {
		if _, err := os.Stat(filepath.Join(root, f)); err != nil {
			add(f, "missing")
		}
	}
	readme, _ := os.ReadFile(filepath.Join(root, "README.md"))

	protos, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, p := range protos {
		if !p.IsDir() {
			continue
		}
		vers, err := os.ReadDir(filepath.Join(root, p.Name()))
		if err != nil {
			return nil, err
		}
		found := false
		for _, v := range vers {
			if !v.IsDir() || !regexp.MustCompile(`^v\d+$`).MatchString(v.Name()) {
				continue
			}
			found = true
			rel := p.Name() + "/" + v.Name()
			out = append(out, checkVersion(root, rel, string(readme))...)
		}
		if !found {
			add(p.Name(), "a protocol directory with no vN version directory")
		}
	}

	// nothing in the tree may carry private key material, public test keys excepted:
	// those are raw hex in JSON, never a PEM block
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if info, e := d.Info(); e == nil && info.Mode()&0o111 != 0 {
			add(rel, "is executable; contracts hold data and documents, not programs")
		}
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		if strings.Contains(string(b), "PRIVATE KEY-----") {
			add(rel, "contains a PEM private key")
		}
		if strings.HasSuffix(path, ".json") {
			var v any
			if e := json.Unmarshal(b, &v); e != nil {
				add(rel, "is not valid JSON: "+e.Error())
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path+out[i].Msg < out[j].Path+out[j].Msg })
	return out, nil
}

func checkVersion(root, rel, rootReadme string) []Problem {
	var out []Problem
	add := func(p, m string) { out = append(out, Problem{rel + p, m}) }
	dir := filepath.Join(root, filepath.FromSlash(rel))

	b, err := os.ReadFile(filepath.Join(dir, "README.md"))
	if err != nil {
		add("/README.md", "missing: every protocol version states its status and support window")
		return out
	}
	text := string(b)
	m := statusRe.FindStringSubmatch(text)
	if m == nil {
		add("/README.md", "does not declare a Status (stable, draft, reserved or deprecated)")
		return out
	}
	status := strings.ToLower(m[1])
	if status == "stable" && !strings.Contains(strings.ToLower(text), "support window") {
		add("/README.md", "is stable but states no support window")
	}
	if status == "stable" || status == "deprecated" {
		if _, err := os.Stat(filepath.Join(dir, "spec.md")); err != nil {
			add("/spec.md", "missing: a "+status+" protocol needs its normative spec")
		}
	}
	if !strings.Contains(rootReadme, rel) && !strings.Contains(rootReadme, strings.ReplaceAll(rel, "/", "` / `")) {
		// the protocol table names versions in a few shapes; accept the protocol and version
		parts := strings.SplitN(rel, "/", 2)
		if !strings.Contains(rootReadme, "`"+parts[0]+"`") || !strings.Contains(rootReadme, parts[1]) {
			add("", "is not listed in contracts/README.md")
		}
	}

	// the bundle-format vectors: one directory per case, each with its verdict
	if rel == "format/v3" {
		vec := filepath.Join(dir, "vectors")
		cases, err := os.ReadDir(vec)
		if err != nil {
			add("/vectors", "missing")
			return out
		}
		n := 0
		for _, c := range cases {
			if !c.IsDir() {
				continue
			}
			n++
			if _, err := os.Stat(filepath.Join(vec, c.Name(), "expected.json")); err != nil {
				add("/vectors/"+c.Name(), "has no expected.json: a vector without a verdict defines nothing")
			}
		}
		if n == 0 {
			add("/vectors", "has no vector directories")
		}
		vr, _ := os.ReadFile(filepath.Join(vec, "README.md"))
		if !strings.Contains(string(vr), "PUBLIC TEST KEYS") {
			add("/vectors/README.md", "must carry the warning that the keys in the vectors are public test keys")
		}
	}
	if rel == "store/v1" {
		out = append(out, checkStoreSchema(rel, filepath.Join(dir, "schema.json"))...)
	}
	return out
}

type storeColumns struct {
	Columns []struct{ Name, Type string } `json:"columns"`
}

// storeMacro is a table macro (store/v1.1 on): its parameter names in order, and the columns
// it returns.
type storeMacro struct {
	Parameters []string `json:"parameters"`
	storeColumns
}

// checkStoreSchema validates the shape of store/v1/schema.json: not whether the server
// still produces it (the server's CI compares its native schema with this file), only that
// the file is something such a comparison can be run against.
func checkStoreSchema(rel, path string) []Problem {
	var out []Problem
	add := func(m string) { out = append(out, Problem{rel + "/schema.json", m}) }

	b, err := os.ReadFile(path)
	if err != nil {
		add("missing: store/v1 is described by a machine-checked schema")
		return out
	}
	var s struct {
		Contract      string                  `json:"contract"`
		StoreContract string                  `json:"store_contract"`
		Tables        map[string]storeColumns `json:"tables"`
		Views         map[string]storeColumns `json:"views"`
		Macros        map[string]storeMacro   `json:"macros"`
	}
	dec := json.NewDecoder(strings.NewReader(string(b)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		add("does not have the schema.json shape: " + err.Error())
		return out
	}
	if s.Contract != "store/v1" {
		add(fmt.Sprintf("contract is %q, want \"store/v1\"", s.Contract))
	}
	if !storeContractRe.MatchString(s.StoreContract) {
		add(fmt.Sprintf("store_contract %q is not store/v1.N", s.StoreContract))
	}
	if len(s.Tables) == 0 || len(s.Views) == 0 {
		add("must list tables and views: a schema that requires nothing cannot fail")
	}
	check := func(kind, name string, o storeColumns) {
		if len(o.Columns) == 0 {
			add(kind + " " + name + " has no columns")
		}
		seen := map[string]bool{}
		for _, c := range o.Columns {
			if c.Name == "" || c.Type == "" {
				add(kind + " " + name + " has a column with no name or no type")
			}
			if seen[strings.ToLower(c.Name)] {
				add(kind + " " + name + " lists column " + c.Name + " twice")
			}
			seen[strings.ToLower(c.Name)] = true
		}
		// the README's rule: every table and view carries vehicle_id, so no query can
		// reach one vehicle's rows through another's
		if !seen["vehicle_id"] {
			add(kind + " " + name + " has no vehicle_id column")
		}
	}
	for n, t := range s.Tables {
		if _, dup := s.Views[n]; dup {
			add(n + " is listed as both a table and a view")
		}
		check("table", n, t)
	}
	for n, v := range s.Views {
		check("view", n, v)
	}
	for n, m := range s.Macros {
		if _, dup := s.Tables[n]; dup {
			add(n + " is listed as both a table and a macro")
		}
		if _, dup := s.Views[n]; dup {
			add(n + " is listed as both a view and a macro")
		}
		if len(m.Parameters) == 0 {
			add("macro " + n + " has no parameters: a view would do")
		}
		seen := map[string]bool{}
		for _, p := range m.Parameters {
			if p == "" || seen[strings.ToLower(p)] {
				add("macro " + n + " has an empty or repeated parameter name")
			}
			seen[strings.ToLower(p)] = true
		}
		check("macro", n, m.storeColumns)
	}
	return out
}

// String renders problems for a terminal.
func String(ps []Problem) string {
	var b strings.Builder
	for _, p := range ps {
		fmt.Fprintln(&b, " ", p)
	}
	return b.String()
}
