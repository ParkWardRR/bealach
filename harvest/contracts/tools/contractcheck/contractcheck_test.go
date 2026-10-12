package contractcheck

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, root, rel, content string, mode os.FileMode) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// a minimal tree that passes
func good(t *testing.T) string {
	root := t.TempDir()
	write(t, root, "README.md", "| `format` | v3 |\n| `store` | v1 |\n", 0o644)
	write(t, root, "CHANGELOG.md", "x\n", 0o644)
	write(t, root, "format/v3/README.md", "- **Status:** stable.\n- **Support window:** as long as firmware.\n", 0o644)
	write(t, root, "format/v3/spec.md", "spec\n", 0o644)
	write(t, root, "format/v3/vectors/README.md", "## THESE ARE PUBLIC TEST KEYS\n", 0o644)
	write(t, root, "format/v3/vectors/valid/expected.json", `{"verdict":"ok"}`, 0o644)
	write(t, root, "store/v1/README.md", "- **Status:** draft.\n", 0o644)
	write(t, root, "store/v1/schema.json", goodSchema, 0o644)
	return root
}

const goodSchema = `{"contract":"store/v1","store_contract":"store/v1.0",
 "tables":{"gap":{"columns":[{"name":"vehicle_id","type":"VARCHAR"},{"name":"n","type":"INTEGER"}]}},
 "views":{"v_gap":{"columns":[{"name":"vehicle_id","type":"VARCHAR"}]}},
 "macros":{"m":{"parameters":["a","b"],"columns":[{"name":"vehicle_id","type":"VARCHAR"}]}}}`

// schema writes goodSchema with one replacement applied, so each case names its one fault
func schema(t *testing.T, root, old, repl string) {
	if !strings.Contains(goodSchema, old) {
		t.Fatalf("goodSchema has no %q to replace", old)
	}
	write(t, root, "store/v1/schema.json", strings.Replace(goodSchema, old, repl, 1), 0o644)
}

func problems(t *testing.T, root string) string {
	t.Helper()
	ps, err := Check(root)
	if err != nil {
		t.Fatal(err)
	}
	return String(ps)
}

func TestAValidTreePasses(t *testing.T) {
	if got := problems(t, good(t)); got != "" {
		t.Fatalf("a valid tree reported problems:\n%s", got)
	}
}

func TestEachRuleCanFire(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(root string)
		want   string
	}{
		{"no status", func(r string) { write(t, r, "store/v1/README.md", "nothing here\n", 0o644) }, "does not declare a Status"},
		{"stable without a support window", func(r string) { write(t, r, "format/v3/README.md", "- **Status:** stable.\n", 0o644) }, "no support window"},
		{"stable without a spec", func(r string) { os.Remove(filepath.Join(r, "format/v3/spec.md")) }, "spec.md"},
		{"a vector with no verdict", func(r string) { write(t, r, "format/v3/vectors/bare/segment.bin", "x", 0o644) }, "no expected.json"},
		{"invalid JSON", func(r string) { write(t, r, "format/v3/vectors/valid/expected.json", `{nope`, 0o644) }, "not valid JSON"},
		{"a private key", func(r string) { write(t, r, "format/v3/notes.md", "-----BEGIN EC PRIVATE KEY-----\n", 0o644) }, "PEM private key"},
		{"an executable", func(r string) { write(t, r, "format/v3/run.sh", "#!/bin/sh\n", 0o755) }, "executable"},
		{"the public-key warning is gone", func(r string) { write(t, r, "format/v3/vectors/README.md", "keys\n", 0o644) }, "public test keys"},
		{"no changelog", func(r string) { os.Remove(filepath.Join(r, "CHANGELOG.md")) }, "CHANGELOG.md"},
		{"a version missing from the index", func(r string) { write(t, r, "README.md", "| `format` | v3 |\n", 0o644) }, "not listed in contracts/README.md"},
		{"a protocol with no version", func(r string) { write(t, r, "share/README.md", "x\n", 0o644) }, "no vN version directory"},
		{"no store schema", func(r string) { os.Remove(filepath.Join(r, "store/v1/schema.json")) }, "schema.json: missing"},
		{"a schema of the wrong shape", func(r string) { write(t, r, "store/v1/schema.json", `{"contract":"store/v1","tables":[]}`, 0o644) }, "does not have the schema.json shape"},
		{"a schema with an unknown field", func(r string) { schema(t, r, `"views"`, `"extra":1,"views"`) }, "does not have the schema.json shape"},
		{"a schema for another contract", func(r string) { schema(t, r, `"contract":"store/v1"`, `"contract":"store/v2"`) }, `contract is "store/v2"`},
		{"a schema with no store_contract", func(r string) { schema(t, r, `"store_contract":"store/v1.0"`, `"store_contract":""`) }, "is not store/v1.N"},
		{"a schema with no views", func(r string) {
			write(t, r, "store/v1/schema.json", `{"contract":"store/v1","store_contract":"store/v1.0","tables":{"gap":{"columns":[{"name":"vehicle_id","type":"X"}]}},"views":{}}`, 0o644)
		}, "must list tables and views"},
		{"a table without vehicle_id", func(r string) { schema(t, r, `{"name":"vehicle_id","type":"VARCHAR"},{"name":"n"`, `{"name":"n"`) }, "table gap has no vehicle_id"},
		{"a column with no type", func(r string) { schema(t, r, `"type":"INTEGER"`, `"type":""`) }, "no name or no type"},
		{"a duplicated column", func(r string) {
			schema(t, r, `{"name":"n","type":"INTEGER"}`, `{"name":"VEHICLE_ID","type":"INTEGER"}`)
		}, "lists column VEHICLE_ID twice"},
		{"an object that is a table and a view", func(r string) { schema(t, r, `"v_gap"`, `"gap"`) }, "both a table and a view"},
		{"a macro that is also a view", func(r string) { schema(t, r, `"m":`, `"v_gap":`) }, "both a view and a macro"},
		{"a macro that is also a table", func(r string) { schema(t, r, `"m":`, `"gap":`) }, "both a table and a macro"},
		{"a macro with no parameters", func(r string) { schema(t, r, `"parameters":["a","b"]`, `"parameters":[]`) }, "macro m has no parameters"},
		{"a macro with a repeated parameter", func(r string) { schema(t, r, `"parameters":["a","b"]`, `"parameters":["a","A"]`) }, "empty or repeated parameter"},
		{"a macro without vehicle_id", func(r string) {
			schema(t, r, `{"name":"vehicle_id","type":"VARCHAR"}]}}}`, `{"name":"n","type":"INTEGER"}]}}}`)
		}, "macro m has no vehicle_id"},
		{"no README for a version", func(r string) { os.Remove(filepath.Join(r, "store/v1/README.md")) }, "README.md"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := good(t)
			c.mutate(root)
			if got := problems(t, root); !strings.Contains(got, c.want) {
				t.Fatalf("want a problem mentioning %q, got:\n%s", c.want, got)
			}
		})
	}
}
