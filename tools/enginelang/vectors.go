package enginelang

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// The vector file format of contracts/engine/v1/vectors/expr.txt. Blank lines and
// lines starting with `#` are comments. Fields are separated by `;` and trimmed.
//
//	E ; nbytes ; expression ; A B C D ; expected ; bytecode-hex
//	X ; nbytes ; expression ; text the rejection must mention
//	B ; bytecode-hex ; A B C D ; expected | ERR_*
//
// E pins compilation AND evaluation: an implementation must emit exactly that bytecode
// and get exactly that value. X pins rejection, by substring so the wording can improve
// without breaking the vector. B pins the evaluator alone on bytecode no compiler emits,
// which is the only way to reach the runtime errors.

// Kind is which of the three line types a vector is.
type Kind string

const (
	KindEval   Kind = "E"
	KindReject Kind = "X"
	KindByte   Kind = "B"
)

// Vector is one parsed line.
type Vector struct {
	Kind Kind
	Line int

	NBytes   int
	Expr     string
	Input    [4]byte
	Expected int32
	Bytecode string

	// Want, for X lines: a substring the rejection message must contain.
	Want string
	// Err, for B lines: the expected ERR_* name, empty when a value is expected.
	Err string
}

// ParseVectors reads a vector file.
func ParseVectors(r io.Reader) ([]Vector, error) {
	var out []Vector
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for line := 1; sc.Scan(); line++ {
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		f := strings.Split(text, ";")
		for i := range f {
			f[i] = strings.TrimSpace(f[i])
		}
		v := Vector{Line: line, Kind: Kind(f[0])}
		var err error
		switch v.Kind {
		case KindEval:
			if len(f) != 6 {
				err = fmt.Errorf("an E line has 6 fields, got %d", len(f))
				break
			}
			if v.NBytes, err = strconv.Atoi(f[1]); err != nil {
				break
			}
			v.Expr = f[2]
			if v.Input, err = parseInput(f[3]); err != nil {
				break
			}
			var n int64
			if n, err = strconv.ParseInt(f[4], 10, 32); err != nil {
				break
			}
			v.Expected = int32(n)
			v.Bytecode = f[5]
		case KindReject:
			if len(f) != 4 {
				err = fmt.Errorf("an X line has 4 fields, got %d", len(f))
				break
			}
			if v.NBytes, err = strconv.Atoi(f[1]); err != nil {
				break
			}
			v.Expr, v.Want = f[2], f[3]
			if v.Want == "" {
				err = fmt.Errorf("an X line must say what the rejection mentions")
			}
		case KindByte:
			if len(f) != 4 {
				err = fmt.Errorf("a B line has 4 fields, got %d", len(f))
				break
			}
			v.Bytecode = f[1]
			if v.Input, err = parseInput(f[2]); err != nil {
				break
			}
			if strings.HasPrefix(f[3], "ERR_") {
				v.Err = f[3]
			} else {
				var n int64
				if n, err = strconv.ParseInt(f[3], 10, 32); err != nil {
					break
				}
				v.Expected = int32(n)
			}
		default:
			err = fmt.Errorf("unknown vector kind %q (expected E, X or B)", f[0])
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", line, err)
		}
		out = append(out, v)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no vectors found")
	}
	return out, nil
}

// parseInput reads up to four space-separated byte values. Absent bytes are 0, which is
// also what an evaluator sees for a variable the PID does not return.
func parseInput(s string) ([4]byte, error) {
	var in [4]byte
	if strings.TrimSpace(s) == "" {
		return in, nil
	}
	parts := strings.Fields(s)
	if len(parts) > 4 {
		return in, fmt.Errorf("at most four input bytes, got %d", len(parts))
	}
	for i, p := range parts {
		n, err := strconv.ParseUint(p, 10, 8)
		if err != nil {
			return in, fmt.Errorf("input byte %d: %w", i+1, err)
		}
		in[i] = byte(n)
	}
	return in, nil
}

// Run checks one vector and returns the reason it failed, or "" when it passed.
func (v Vector) Run() string {
	switch v.Kind {
	case KindEval:
		c, err := Compile(v.Expr, v.NBytes)
		if err != nil {
			return fmt.Sprintf("%q should compile for %d byte(s) but was rejected: %v", v.Expr, v.NBytes, err)
		}
		if got := Hex(c.Code); got != v.Bytecode {
			return fmt.Sprintf("%q compiles to %s, the vector says %s", v.Expr, got, v.Bytecode)
		}
		got, err := Eval(c.Code, v.Input)
		if err != nil {
			return fmt.Sprintf("%q on %v failed at run time: %v (an accepted formula must not)", v.Expr, v.Input, err)
		}
		if got != v.Expected {
			return fmt.Sprintf("%q on %v is %d, the vector says %d", v.Expr, v.Input, got, v.Expected)
		}
	case KindReject:
		if _, err := Compile(v.Expr, v.NBytes); err == nil {
			return fmt.Sprintf("%q should be rejected (mentioning %q) but compiled", v.Expr, v.Want)
		} else if !strings.Contains(err.Error(), v.Want) {
			return fmt.Sprintf("%q was rejected as %q, which does not mention %q", v.Expr, err, v.Want)
		}
	case KindByte:
		code, err := FromHex(v.Bytecode)
		if err != nil {
			return fmt.Sprintf("bytecode %s is unreadable: %v", v.Bytecode, err)
		}
		got, err := Eval(code, v.Input)
		if v.Err != "" {
			if err == nil {
				return fmt.Sprintf("bytecode %s on %v should fail with %s but returned %d", v.Bytecode, v.Input, v.Err, got)
			}
			if err.Error() != v.Err {
				return fmt.Sprintf("bytecode %s on %v failed with %s, the vector says %s", v.Bytecode, v.Input, err, v.Err)
			}
			return ""
		}
		if err != nil {
			return fmt.Sprintf("bytecode %s on %v failed with %s, the vector expects %d", v.Bytecode, v.Input, err, v.Expected)
		}
		if got != v.Expected {
			return fmt.Sprintf("bytecode %s on %v is %d, the vector says %d", v.Bytecode, v.Input, got, v.Expected)
		}
	}
	return ""
}
