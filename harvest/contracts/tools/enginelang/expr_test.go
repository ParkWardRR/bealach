package enginelang

import (
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// vectorPath is the contract's own vector file, read from this repository.
func vectorPath(t *testing.T) string {
	t.Helper()
	p := filepath.Join("..", "..", "contracts", "engine", "v1", "vectors", "expr.txt")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("the contract's vectors are missing at %s: %v", p, err)
	}
	return p
}

func loadVectors(t *testing.T) []Vector {
	t.Helper()
	f, err := os.Open(vectorPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	v, err := ParseVectors(f)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// TestContractVectors is the contract check itself: every committed vector, run against
// this implementation. It is the same thing cmd/engine-check does, here so that
// `go test ./...` covers it too.
func TestContractVectors(t *testing.T) {
	vectors := loadVectors(t)
	if len(vectors) < 50 {
		t.Fatalf("only %d vectors; the file looks truncated", len(vectors))
	}
	for _, v := range vectors {
		if why := v.Run(); why != "" {
			t.Errorf("%s line %d: %s", v.Kind, v.Line, why)
		}
	}
}

// formulas returns every distinct (expression, nbytes) the E vectors accept. These are
// the real formulas the shipped engine profiles use, plus the semantic cases.
func formulas(t *testing.T) map[[2]string]int {
	t.Helper()
	out := map[[2]string]int{}
	for _, v := range loadVectors(t) {
		if v.Kind == KindEval {
			out[[2]string{v.Expr, string(rune('0' + v.NBytes))}] = v.NBytes
		}
	}
	return out
}

// TestAcceptedFormulasNeverFailAtRuntime is the language's central safety claim: an
// expression the static checker accepts cannot fail at run time on ANY reply the PID
// can return. If this ever fails, the interval analysis is unsound and a formula that
// passed review could error in the car.
//
// Exhaustive for one and two data bytes (256 and 65,536 inputs); sampled above that,
// because 2^32 cases is not a unit test.
func TestAcceptedFormulasNeverFailAtRuntime(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for key, nbytes := range formulas(t) {
		expr := key[0]
		c, err := Compile(expr, nbytes)
		if err != nil {
			t.Errorf("%q (%d bytes) is in an E vector but does not compile: %v", expr, nbytes, err)
			continue
		}
		each(nbytes, rng, func(in [4]byte) bool {
			got, err := Eval(c.Code, in)
			if err != nil {
				t.Errorf("%q accepted but failed on %v: %v", expr, in[:nbytes], err)
				return false
			}
			// And the declared range must actually hold, which is what lets a profile's
			// `range` be trusted by everything downstream.
			if int64(got) < c.Range.Lo || int64(got) > c.Range.Hi {
				t.Errorf("%q on %v is %d, outside the analysed range %d..%d",
					expr, in[:nbytes], got, c.Range.Lo, c.Range.Hi)
				return false
			}
			return true
		})
	}
}

// each calls f over every input for nbytes <= 2, or 20,000 random ones above that.
// Returning false from f stops the sweep, so one broken formula reports once.
func each(nbytes int, rng *rand.Rand, f func([4]byte) bool) {
	var in [4]byte
	switch nbytes {
	case 1:
		for a := 0; a < 256; a++ {
			in = [4]byte{byte(a)}
			if !f(in) {
				return
			}
		}
	case 2:
		for a := 0; a < 256; a++ {
			for b := 0; b < 256; b++ {
				in = [4]byte{byte(a), byte(b)}
				if !f(in) {
					return
				}
			}
		}
	default:
		for i := 0; i < 20000; i++ {
			for j := 0; j < nbytes; j++ {
				in[j] = byte(rng.Intn(256))
			}
			if !f(in) {
				return
			}
		}
	}
}

// TestCompileIsDeterministic: the same source must always give the same bytes. The
// vectors pin exact bytecode, so any nondeterminism (map iteration, say) would make
// them flaky rather than wrong.
func TestCompileIsDeterministic(t *testing.T) {
	for key, nbytes := range formulas(t) {
		first, err := Compile(key[0], nbytes)
		if err != nil {
			continue
		}
		for i := 0; i < 8; i++ {
			again, err := Compile(key[0], nbytes)
			if err != nil {
				t.Fatalf("%q compiled then did not: %v", key[0], err)
			}
			if Hex(again.Code) != Hex(first.Code) {
				t.Fatalf("%q compiles differently between runs: %s then %s",
					key[0], Hex(first.Code), Hex(again.Code))
			}
		}
	}
}

// TestPushEncodingIsShortest pins the encoding choice at each boundary. It is part of
// the contract rather than an optimisation, because the E vectors compare exact bytes.
func TestPushEncodingIsShortest(t *testing.T) {
	cases := []struct {
		expr string
		hex  string
	}{
		{"0", "0100010020"},       // u8  zero
		{"255", "01ff010020"},     // u8  top
		{"256", "020001010020"},   // u16 bottom
		{"65535", "02ffff010020"}, // u16 top
		{"-1", "04ff010020"},      // s8  top
		{"-128", "0480010020"},    // s8  bottom
		{"-129", "037fffffff010020"},
		{"65536", "0300000100010020"},
	}
	for _, c := range cases {
		// `+0` keeps the expression a single literal while giving every case the same
		// shape, so the literal's own encoding is what differs.
		got, err := Compile(c.expr+"+0", 1)
		if err != nil {
			t.Errorf("%q: %v", c.expr, err)
			continue
		}
		if Hex(got.Code) != c.hex {
			t.Errorf("%q compiles to %s, want %s", c.expr, Hex(got.Code), c.hex)
		}
	}
}

// TestNegatedLiteralIsOnePush: `-127` must be a single push, not a push and a neg.
// Observable in the bytecode, so it is contract.
func TestNegatedLiteralIsOnePush(t *testing.T) {
	c, err := Compile("-127", 1)
	if err != nil {
		t.Fatal(err)
	}
	if h := Hex(c.Code); h != "0481" {
		t.Fatalf("-127 compiles to %s, want 0481 (one s8 push)", h)
	}
	// But negating something that is not a literal does emit neg.
	c, err = Compile("-A", 1)
	if err != nil {
		t.Fatal(err)
	}
	if h := Hex(c.Code); h != "1025" {
		t.Fatalf("-A compiles to %s, want 1025 (load then neg)", h)
	}
}

// TestLimitsAreEnforced covers the three structural limits, which no E or X vector in
// the contract currently reaches.
func TestLimitsAreEnforced(t *testing.T) {
	long := "A" + strings.Repeat("+A", MaxSourceLen) // longer than 256 characters
	if _, err := Compile(long, 1); err == nil || !strings.Contains(err.Error(), "longer than") {
		t.Errorf("an over-long expression was not refused: %v", err)
	}
	deep := strings.Repeat("(", MaxDepth+2) + "A" + strings.Repeat(")", MaxDepth+2)
	if _, err := Compile(deep, 1); err == nil || !strings.Contains(err.Error(), "nested deeper") {
		t.Errorf("an over-nested expression was not refused: %v", err)
	}
	// A stack deeper than 16 needs a right-leaning chain: each `+(` holds one operand.
	var sb strings.Builder
	for i := 0; i < MaxStack+2; i++ {
		sb.WriteString("A+(")
	}
	sb.WriteString("A")
	sb.WriteString(strings.Repeat(")", MaxStack+2))
	if _, err := Compile(sb.String(), 1); err == nil {
		t.Error("an expression needing a deeper stack than 16 was accepted")
	} else if !strings.Contains(err.Error(), "stack") && !strings.Contains(err.Error(), "nested") {
		t.Errorf("refused for the wrong reason: %v", err)
	}
}

// TestEvalRejectsDeepBytecode: the evaluator must refuse a stack overflow from raw
// bytecode, since such bytecode cannot come from the compiler but can come from flash.
func TestEvalRejectsDeepBytecode(t *testing.T) {
	var code []byte
	for i := 0; i < MaxStack+1; i++ {
		code = append(code, OpPushU8, 1)
	}
	if _, err := Eval(code, [4]byte{}); err != ErrStack {
		t.Fatalf("17 pushes gave %v, want ERR_STACK", err)
	}
}

// TestDivisionTruncatesTowardZero pins the one place where languages differ most, and
// where a wrong answer would be a plausible-looking number rather than an error.
func TestDivisionTruncatesTowardZero(t *testing.T) {
	cases := []struct {
		expr string
		in   byte
		want int32
	}{
		{"(A-10)/4", 1, -2}, // -9/4 = -2, not -3
		{"(A-10)%4", 1, -1}, // sign of the dividend
		{"(A-10)/4", 19, 2}, // 9/4 = 2
		{"(A-10)%4", 19, 1}, //
		{"(A-9)>>1", 0, -5}, // arithmetic shift floors: -9>>1 = -5
		{"(A-9)/2", 0, -4},  // but division truncates: -9/2 = -4
	}
	for _, c := range cases {
		got, err := Compile(c.expr, 1)
		if err != nil {
			t.Errorf("%q: %v", c.expr, err)
			continue
		}
		v, err := Eval(got.Code, [4]byte{c.in})
		if err != nil {
			t.Errorf("%q on %d: %v", c.expr, c.in, err)
			continue
		}
		if v != c.want {
			t.Errorf("%q on %d is %d, want %d", c.expr, c.in, v, c.want)
		}
	}
}

// TestHexRoundTrip: Hex and FromHex must be inverses, since the vectors are hex.
func TestHexRoundTrip(t *testing.T) {
	for key, nbytes := range formulas(t) {
		c, err := Compile(key[0], nbytes)
		if err != nil {
			continue
		}
		back, err := FromHex(Hex(c.Code))
		if err != nil {
			t.Fatalf("%q: %v", key[0], err)
		}
		if Hex(back) != Hex(c.Code) {
			t.Fatalf("%q does not round-trip through hex", key[0])
		}
	}
	if _, err := FromHex("abc"); err == nil {
		t.Error("odd-length hex was accepted")
	}
	if _, err := FromHex("zz"); err == nil {
		t.Error("non-hex was accepted")
	}
	// Whitespace is ignored, which is what lets the vectors group bytes for reading.
	a, err := FromHex("0107 0108 20")
	if err != nil {
		t.Fatal(err)
	}
	if Hex(a) != "0107010820" {
		t.Fatalf("grouped hex read as %s", Hex(a))
	}
}

// TestVectorFileRejectsMalformedLines: the parser must not silently skip a line it
// does not understand, or a vector could be deleted by a typo.
func TestVectorFileRejectsMalformedLines(t *testing.T) {
	for _, bad := range []string{
		"Q ; 1 ; A ; 0 ; 0 ; 10", // unknown kind
		"E ; 1 ; A ; 0 ; 0",      // too few fields
		"X ; 1 ; A",              // too few fields
		"X ; 1 ; A ; ",           // no expected text
		"B ; 10 ; 0",             // too few fields
		"E ; x ; A ; 0 ; 0 ; 10", // nbytes not a number
		"B ; 10 ; 0 1 2 3 4 ; 0", // too many input bytes
	} {
		if _, err := ParseVectors(strings.NewReader(bad)); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	if _, err := ParseVectors(strings.NewReader("# only a comment\n\n")); err == nil {
		t.Error("a file with no vectors was accepted")
	}
}
