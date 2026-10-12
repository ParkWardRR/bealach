// Package enginelang implements the formula language of `cairn.engine/v1-draft`:
// lexer, parser, static analysis, bytecode compiler and bytecode evaluator.
//
// It exists to be a THIRD implementation. The language already has two — the Rust
// generator (`tools/enginegen` in the firmware repository) and the C evaluator
// (`test/host` there) — and the draft spec names a third, independent consumer as the
// gate before `contracts/engine/v1` can leave draft. Two implementations written from
// one head agree on that head's mistakes; a third, written from the normative text in
// [../../contracts/engine/v1/spec.md] rather than from the Rust, is what makes the
// vectors evidence instead of a recording.
//
// So this package is deliberately NOT a port. It was written from the spec, and where
// it and the Rust disagree the disagreement is a finding, not a bug to paper over.
//
// The language is integer-only, has no state, no loops and no calls out, so evaluation
// always terminates and can execute nothing. Every value is an int32 and every
// operation's result must land in int32 or evaluation fails; nothing wraps. That is why
// C, Go, Rust, Swift and TypeScript can agree exactly.
package enginelang

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Limits from the spec. They are part of the contract, not implementation choices.
const (
	MaxStack     = 16
	MaxSourceLen = 256
	MaxDepth     = 32
	MaxCodeLen   = 255
)

// Opcodes. These numbers are part of the contract; the bytecode vectors pin them.
const (
	OpPushU8  = 0x01
	OpPushU16 = 0x02
	OpPushI32 = 0x03
	OpPushS8  = 0x04
	OpLoadA   = 0x10 // ..0x13 for A..D
	OpAdd     = 0x20
	OpSub     = 0x21
	OpMul     = 0x22
	OpDiv     = 0x23
	OpMod     = 0x24
	OpNeg     = 0x25
	OpAnd     = 0x26
	OpOr      = 0x27
	OpShl     = 0x28
	OpShr     = 0x29
	OpMin     = 0x30
	OpMax     = 0x31
	OpClamp   = 0x32
)

const (
	i32Min = int64(math.MinInt32)
	i32Max = int64(math.MaxInt32)
)

// ── tokens ──────────────────────────────────────────────────────────────────

type tokKind int

const (
	tkInt tokKind = iota
	tkVar
	tkFunc
	tkPlus
	tkMinus
	tkStar
	tkSlash
	tkPercent
	tkAmp
	tkPipe
	tkShl
	tkShr
	tkLParen
	tkRParen
	tkComma
)

type fn int

const (
	fnMin fn = iota
	fnMax
	fnClamp
)

func (f fn) String() string {
	switch f {
	case fnMin:
		return "min"
	case fnMax:
		return "max"
	}
	return "clamp"
}

// arity is how many arguments the function takes.
func (f fn) arity() int {
	if f == fnClamp {
		return 3
	}
	return 2
}

type tok struct {
	kind tokKind
	n    int64 // tkInt
	v    uint8 // tkVar: 0..3 for A..D
	f    fn    // tkFunc
	col  int   // 1-based, for messages
}

// lex turns source into tokens. Whitespace is ignored; everything else is either a
// token or an error, because the language has no identifiers beyond A..D, min, max and
// clamp, and no way to spell a comparison or a float.
func lex(src string) ([]tok, error) {
	if len(src) > MaxSourceLen {
		return nil, fmt.Errorf("expression longer than %d characters", MaxSourceLen)
	}
	var out []tok
	for i := 0; i < len(src); {
		c := src[i]
		col := i + 1
		switch {
		case c == ' ' || c == '\t':
			i++
		case c == '+':
			out, i = append(out, tok{kind: tkPlus, col: col}), i+1
		case c == '-':
			out, i = append(out, tok{kind: tkMinus, col: col}), i+1
		case c == '*':
			out, i = append(out, tok{kind: tkStar, col: col}), i+1
		case c == '/':
			out, i = append(out, tok{kind: tkSlash, col: col}), i+1
		case c == '%':
			out, i = append(out, tok{kind: tkPercent, col: col}), i+1
		case c == '&':
			out, i = append(out, tok{kind: tkAmp, col: col}), i+1
		case c == '|':
			out, i = append(out, tok{kind: tkPipe, col: col}), i+1
		case c == '(':
			out, i = append(out, tok{kind: tkLParen, col: col}), i+1
		case c == ')':
			out, i = append(out, tok{kind: tkRParen, col: col}), i+1
		case c == ',':
			out, i = append(out, tok{kind: tkComma, col: col}), i+1
		case c == '<' || c == '>':
			if i+1 >= len(src) || src[i+1] != c {
				return nil, fmt.Errorf("column %d: only the shifts << and >> are operators; comparisons do not exist", col)
			}
			k := tkShl
			if c == '>' {
				k = tkShr
			}
			out, i = append(out, tok{kind: k, col: col}), i+2
		case c >= '0' && c <= '9':
			n, next, err := lexNumber(src, i)
			if err != nil {
				return nil, err
			}
			out, i = append(out, tok{kind: tkInt, n: n, col: col}), next
		// A..D are variables, but only standing alone: `A` is a variable and `Abs` is
		// an unknown name, not a variable followed by something.
		case c >= 'A' && c <= 'D' && !(i+1 < len(src) && isAlnum(src[i+1])):
			out, i = append(out, tok{kind: tkVar, v: c - 'A', col: col}), i+1
		case isAlpha(c) || c == '_':
			j := i
			for j < len(src) && (isAlnum(src[j]) || src[j] == '_') {
				j++
			}
			word := src[i:j]
			var f fn
			switch word {
			case "min":
				f = fnMin
			case "max":
				f = fnMax
			case "clamp":
				f = fnClamp
			default:
				return nil, fmt.Errorf("column %d: unknown name %q (variables are A B C D; functions are min, max, clamp)", col, word)
			}
			out, i = append(out, tok{kind: tkFunc, f: f, col: col}), j
		default:
			return nil, fmt.Errorf("column %d: unexpected character %q", col, string(c))
		}
	}
	return out, nil
}

func isAlpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isAlnum(c byte) bool { return isAlpha(c) || c >= '0' && c <= '9' }

// lexNumber reads a decimal or 0x-hex literal. A trailing letter, dot or underscore is
// an error rather than the end of a number, so `1.5`, `10kPa` and `1_000` are rejected
// instead of silently becoming 1, 10 and 1.
func lexNumber(src string, i int) (int64, int, error) {
	col := i + 1
	base, start := 10, i
	if src[i] == '0' && i+1 < len(src) && (src[i+1] == 'x' || src[i+1] == 'X') {
		base, start = 16, i+2
	}
	j := start
	for j < len(src) && isDigitIn(src[j], base) {
		j++
	}
	if j == start {
		return 0, 0, fmt.Errorf("column %d: malformed number", col)
	}
	if j < len(src) && (isAlnum(src[j]) || src[j] == '.' || src[j] == '_') {
		return 0, 0, fmt.Errorf("column %d: malformed number (integers only, no suffixes or fractions)", col)
	}
	n, err := strconv.ParseInt(src[start:j], base, 64)
	if err != nil {
		return 0, 0, fmt.Errorf("column %d: number too large", col)
	}
	if n > i32Max {
		return 0, 0, fmt.Errorf("column %d: literal %d exceeds int32", col, n)
	}
	return n, j, nil
}

func isDigitIn(c byte, base int) bool {
	switch {
	case c >= '0' && c <= '9':
		return int(c-'0') < base
	case base == 16 && (c|0x20) >= 'a' && (c|0x20) <= 'f':
		return true
	}
	return false
}

// ── AST ─────────────────────────────────────────────────────────────────────

type binOp int

const (
	opAdd binOp = iota
	opSub
	opMul
	opDiv
	opMod
	opAnd
	opOr
	opShl
	opShr
)

var binCode = map[binOp]byte{
	opAdd: OpAdd, opSub: OpSub, opMul: OpMul, opDiv: OpDiv, opMod: OpMod,
	opAnd: OpAnd, opOr: OpOr, opShl: OpShl, opShr: OpShr,
}

// node is one AST node. Exactly one of the shapes is in use, picked by kind.
type node struct {
	kind nodeKind
	lit  int64
	v    uint8
	op   binOp
	f    fn
	kids []*node
}

type nodeKind int

const (
	nLit nodeKind = iota
	nVar
	nNeg
	nBin
	nCall
)

// ── parser ──────────────────────────────────────────────────────────────────

type parser struct {
	toks  []tok
	pos   int
	depth int
}

// Parse parses an expression. Precedence and associativity are C's, lowest first:
// `|`, `&`, `<< >>`, `+ -`, `* / %`, unary `-`.
func Parse(src string) (*node, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	if len(toks) == 0 {
		return nil, fmt.Errorf("empty expression")
	}
	p := &parser{toks: toks}
	n, err := p.or()
	if err != nil {
		return nil, err
	}
	if p.pos < len(p.toks) {
		return nil, fmt.Errorf("column %d: unexpected trailing input", p.col())
	}
	return n, nil
}

func (p *parser) peek() (tokKind, bool) {
	if p.pos >= len(p.toks) {
		return 0, false
	}
	return p.toks[p.pos].kind, true
}

func (p *parser) col() int {
	if p.pos < len(p.toks) {
		return p.toks[p.pos].col
	}
	if len(p.toks) == 0 {
		return 1
	}
	return p.toks[len(p.toks)-1].col
}

func (p *parser) enter() error {
	p.depth++
	if p.depth > MaxDepth {
		return fmt.Errorf("expression nested deeper than %d", MaxDepth)
	}
	return nil
}

// binLevel parses a left-associative level: one `next` then any number of
// (operator, next) pairs drawn from ops.
func (p *parser) binLevel(ops map[tokKind]binOp, next func() (*node, error)) (*node, error) {
	l, err := next()
	if err != nil {
		return nil, err
	}
	for {
		k, ok := p.peek()
		if !ok {
			return l, nil
		}
		op, ok := ops[k]
		if !ok {
			return l, nil
		}
		p.pos++
		r, err := next()
		if err != nil {
			return nil, err
		}
		l = &node{kind: nBin, op: op, kids: []*node{l, r}}
	}
}

func (p *parser) or() (*node, error) {
	if err := p.enter(); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	return p.binLevel(map[tokKind]binOp{tkPipe: opOr}, p.and)
}

func (p *parser) and() (*node, error) {
	return p.binLevel(map[tokKind]binOp{tkAmp: opAnd}, p.shift)
}

func (p *parser) shift() (*node, error) {
	return p.binLevel(map[tokKind]binOp{tkShl: opShl, tkShr: opShr}, p.add)
}

func (p *parser) add() (*node, error) {
	return p.binLevel(map[tokKind]binOp{tkPlus: opAdd, tkMinus: opSub}, p.mul)
}

func (p *parser) mul() (*node, error) {
	return p.binLevel(map[tokKind]binOp{tkStar: opMul, tkSlash: opDiv, tkPercent: opMod}, p.unary)
}

func (p *parser) unary() (*node, error) {
	if k, ok := p.peek(); ok && k == tkMinus {
		if err := p.enter(); err != nil {
			return nil, err
		}
		p.pos++
		inner, err := p.unary()
		if err != nil {
			return nil, err
		}
		p.depth--
		// A negated literal is a literal, so -127 costs one push and not a push plus a
		// neg. That choice is observable in the bytecode, so the vectors pin it.
		if inner.kind == nLit {
			return &node{kind: nLit, lit: -inner.lit}, nil
		}
		return &node{kind: nNeg, kids: []*node{inner}}, nil
	}
	return p.primary()
}

func (p *parser) primary() (*node, error) {
	if p.pos >= len(p.toks) {
		return nil, fmt.Errorf("expression ends early")
	}
	t := p.toks[p.pos]
	p.pos++
	switch t.kind {
	case tkInt:
		return &node{kind: nLit, lit: t.n}, nil
	case tkVar:
		return &node{kind: nVar, v: t.v}, nil
	case tkLParen:
		e, err := p.or()
		if err != nil {
			return nil, err
		}
		if p.pos >= len(p.toks) || p.toks[p.pos].kind != tkRParen {
			return nil, fmt.Errorf("column %d: expected `)`", p.col())
		}
		p.pos++
		return e, nil
	case tkFunc:
		if p.pos >= len(p.toks) || p.toks[p.pos].kind != tkLParen {
			return nil, fmt.Errorf("column %d: a function name must be followed by `(`", t.col)
		}
		p.pos++
		var args []*node
		for {
			a, err := p.or()
			if err != nil {
				return nil, err
			}
			args = append(args, a)
			if p.pos >= len(p.toks) {
				return nil, fmt.Errorf("column %d: expected `,` or `)`", p.col())
			}
			k := p.toks[p.pos].kind
			p.pos++
			if k == tkComma {
				continue
			}
			if k == tkRParen {
				break
			}
			return nil, fmt.Errorf("column %d: expected `,` or `)`", p.col())
		}
		if len(args) != t.f.arity() {
			return nil, fmt.Errorf("column %d: %s takes %d arguments, got %d", t.col, t.f, t.f.arity(), len(args))
		}
		return &node{kind: nCall, f: t.f, kids: args}, nil
	}
	return nil, fmt.Errorf("column %d: unexpected token", t.col)
}

// ── static analysis ─────────────────────────────────────────────────────────

// Interval is the inclusive range a sub-expression can produce.
type Interval struct{ Lo, Hi int64 }

func fit(iv Interval, what string) (Interval, error) {
	if iv.Lo < i32Min || iv.Hi > i32Max {
		return iv, fmt.Errorf("%s can leave int32 range for some input bytes (%d..%d)", what, iv.Lo, iv.Hi)
	}
	return iv, nil
}

// corners evaluates f at the four endpoint combinations and takes the extremes. Sound
// for the monotone-in-each-argument operations it is used for (×, ÷).
func corners(a, b Interval, f func(x, y int64) int64) Interval {
	v := []int64{f(a.Lo, b.Lo), f(a.Lo, b.Hi), f(a.Hi, b.Lo), f(a.Hi, b.Hi)}
	lo, hi := v[0], v[0]
	for _, x := range v[1:] {
		if x < lo {
			lo = x
		}
		if x > hi {
			hi = x
		}
	}
	return Interval{lo, hi}
}

// maskUp is the smallest 2^k-1 that is >= x, for x >= 0: the loosest bound on `|` that
// holds without knowing which bits are set.
func maskUp(x int64) int64 {
	m := int64(0)
	for m < x {
		m = m<<1 | 1
	}
	return m
}

func minI(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func absI(a int64) int64 {
	if a < 0 {
		return -a
	}
	return a
}

// Analyse returns the range the expression can produce when each of the first nbytes
// variables ranges over 0..255 and the rest are unavailable.
//
// This is the whole safety argument of the language: an expression that passes cannot
// fail at run time on any reply the PID can return. It rejects anything that could
// divide by zero, shift by a non-constant or out-of-range count, or leave int32 — for
// SOME input, not merely for the inputs someone tried.
func Analyse(n *node, nbytes int) (Interval, error) {
	switch n.kind {
	case nLit:
		return Interval{n.lit, n.lit}, nil
	case nVar:
		if int(n.v) >= nbytes {
			return Interval{}, fmt.Errorf("formula uses %c but the PID returns %d data byte(s)", 'A'+n.v, nbytes)
		}
		return Interval{0, 255}, nil
	case nNeg:
		a, err := Analyse(n.kids[0], nbytes)
		if err != nil {
			return Interval{}, err
		}
		return fit(Interval{-a.Hi, -a.Lo}, "negation")
	case nCall:
		v := make([]Interval, len(n.kids))
		for i, k := range n.kids {
			iv, err := Analyse(k, nbytes)
			if err != nil {
				return Interval{}, err
			}
			v[i] = iv
		}
		switch n.f {
		case fnMin:
			return Interval{minI(v[0].Lo, v[1].Lo), minI(v[0].Hi, v[1].Hi)}, nil
		case fnMax:
			return Interval{maxI(v[0].Lo, v[1].Lo), maxI(v[0].Hi, v[1].Hi)}, nil
		}
		// clamp(x, lo, hi) is min(max(x, lo), hi)
		m := Interval{maxI(v[0].Lo, v[1].Lo), maxI(v[0].Hi, v[1].Hi)}
		return Interval{minI(m.Lo, v[2].Lo), minI(m.Hi, v[2].Hi)}, nil
	}

	a, err := Analyse(n.kids[0], nbytes)
	if err != nil {
		return Interval{}, err
	}
	b, err := Analyse(n.kids[1], nbytes)
	if err != nil {
		return Interval{}, err
	}
	switch n.op {
	case opAdd:
		return fit(Interval{a.Lo + b.Lo, a.Hi + b.Hi}, "addition")
	case opSub:
		return fit(Interval{a.Lo - b.Hi, a.Hi - b.Lo}, "subtraction")
	case opMul:
		return fit(corners(a, b, func(x, y int64) int64 { return x * y }), "multiplication")
	case opDiv:
		if b.Lo <= 0 && b.Hi >= 0 {
			return Interval{}, fmt.Errorf("a divisor can be zero for some input bytes (guard it, e.g. max(B, 1))")
		}
		return fit(corners(a, b, func(x, y int64) int64 { return x / y }), "division")
	case opMod:
		if b.Lo <= 0 && b.Hi >= 0 {
			return Interval{}, fmt.Errorf("a modulus can be zero for some input bytes (guard it, e.g. max(B, 1))")
		}
		// |a % b| < max|b|, and the result takes the sign of a (C99 truncation).
		m := maxI(absI(b.Lo), absI(b.Hi)) - 1
		switch {
		case a.Lo >= 0:
			return Interval{0, minI(a.Hi, m)}, nil
		case a.Hi <= 0:
			return Interval{maxI(-m, a.Lo), 0}, nil
		default:
			return Interval{maxI(-m, a.Lo), minI(a.Hi, m)}, nil
		}
	case opAnd:
		// A non-negative operand bounds the result: masking cannot exceed either side.
		switch {
		case a.Lo >= 0 && b.Lo >= 0:
			return Interval{0, minI(a.Hi, b.Hi)}, nil
		case b.Lo >= 0:
			return Interval{0, b.Hi}, nil
		case a.Lo >= 0:
			return Interval{0, a.Hi}, nil
		}
		return Interval{i32Min, i32Max}, nil
	case opOr:
		if a.Lo >= 0 && b.Lo >= 0 {
			return Interval{maxI(a.Lo, b.Lo), maskUp(maxI(a.Hi, b.Hi))}, nil
		}
		return Interval{i32Min, i32Max}, nil
	case opShl, opShr:
		// A variable shift count would make the whole analysis a guess, so the count
		// must be a literal the checker can see.
		if b.Lo != b.Hi || b.Lo < 0 || b.Lo > 31 {
			return Interval{}, fmt.Errorf("a shift count must be a constant in 0..=31")
		}
		k := uint(b.Lo)
		if n.op == opShl {
			return fit(Interval{a.Lo << k, a.Hi << k}, "left shift")
		}
		return Interval{a.Lo >> k, a.Hi >> k}, nil
	}
	return Interval{}, fmt.Errorf("unreachable operator")
}

// ── compiler ────────────────────────────────────────────────────────────────

// emitPush appends the shortest push for n. The choice is observable in the bytecode,
// so it is contract, not optimisation: 0..255 u8, -128..-1 s8, 256..65535 u16, else i32.
func emitPush(code []byte, n int64) []byte {
	switch {
	case n >= 0 && n <= 255:
		return append(code, OpPushU8, byte(n))
	case n >= -128 && n < 0:
		return append(code, OpPushS8, byte(int8(n)))
	case n >= 256 && n <= 65535:
		return append(code, OpPushU16, byte(n&0xff), byte(n>>8))
	}
	v := uint32(int32(n))
	return append(code, OpPushI32, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

type gen struct {
	code  []byte
	depth int
	max   int
}

func (g *gen) push() {
	g.depth++
	if g.depth > g.max {
		g.max = g.depth
	}
}

func (g *gen) emit(n *node) {
	switch n.kind {
	case nLit:
		g.code = emitPush(g.code, n.lit)
		g.push()
	case nVar:
		g.code = append(g.code, OpLoadA+n.v)
		g.push()
	case nNeg:
		g.emit(n.kids[0])
		g.code = append(g.code, OpNeg)
	case nBin:
		g.emit(n.kids[0])
		g.emit(n.kids[1])
		g.code = append(g.code, binCode[n.op])
		g.depth--
	case nCall:
		for _, k := range n.kids {
			g.emit(k)
		}
		switch n.f {
		case fnMin:
			g.code = append(g.code, OpMin)
		case fnMax:
			g.code = append(g.code, OpMax)
		default:
			g.code = append(g.code, OpClamp)
		}
		g.depth -= len(n.kids) - 1
	}
}

// Compiled is an accepted formula: its bytecode and the range it can produce.
type Compiled struct {
	Code  []byte
	Range Interval
}

// Compile parses, statically checks and compiles src for a PID returning nbytes data
// bytes.
func Compile(src string, nbytes int) (*Compiled, error) {
	ast, err := Parse(src)
	if err != nil {
		return nil, err
	}
	iv, err := Analyse(ast, nbytes)
	if err != nil {
		return nil, err
	}
	g := &gen{}
	g.emit(ast)
	if g.max > MaxStack {
		return nil, fmt.Errorf("expression needs a stack of %d, the limit is %d", g.max, MaxStack)
	}
	if len(g.code) > MaxCodeLen {
		return nil, fmt.Errorf("compiled formula longer than %d bytes", MaxCodeLen)
	}
	return &Compiled{Code: g.code, Range: iv}, nil
}

// ── evaluator ───────────────────────────────────────────────────────────────

// EvalError is one of the seven runtime failures the contract names.
type EvalError string

const (
	ErrTrunc    EvalError = "ERR_TRUNC"
	ErrBadOp    EvalError = "ERR_BAD_OP"
	ErrStack    EvalError = "ERR_STACK"
	ErrDivZero  EvalError = "ERR_DIV_ZERO"
	ErrOverflow EvalError = "ERR_OVERFLOW"
	ErrShift    EvalError = "ERR_SHIFT"
	ErrResult   EvalError = "ERR_RESULT"
)

func (e EvalError) Error() string { return string(e) }

// Eval runs bytecode against four data bytes.
//
// A formula that Compile accepted cannot reach any of these errors, so they are
// reachable only through hand-written or corrupt bytecode. They are checked anyway,
// because bytecode in flash is only as trustworthy as the flash.
func Eval(code []byte, in [4]byte) (int32, error) {
	var st [MaxStack]int64
	sp := 0

	push := func(v int64) error {
		if sp >= MaxStack {
			return ErrStack
		}
		st[sp] = v
		sp++
		return nil
	}
	pop := func() (int64, error) {
		if sp == 0 {
			return 0, ErrStack
		}
		sp--
		return st[sp], nil
	}
	// chk enforces that nothing wraps: an operation whose exact result leaves int32 is
	// an error, never a truncation.
	chk := func(v int64) (int64, error) {
		if v < i32Min || v > i32Max {
			return 0, ErrOverflow
		}
		return v, nil
	}

	for pc := 0; pc < len(code); {
		op := code[pc]
		pc++
		switch {
		case op == OpPushU8:
			if pc >= len(code) {
				return 0, ErrTrunc
			}
			if err := push(int64(code[pc])); err != nil {
				return 0, err
			}
			pc++
		case op == OpPushS8:
			if pc >= len(code) {
				return 0, ErrTrunc
			}
			if err := push(int64(int8(code[pc]))); err != nil {
				return 0, err
			}
			pc++
		case op == OpPushU16:
			if pc+2 > len(code) {
				return 0, ErrTrunc
			}
			if err := push(int64(uint16(code[pc]) | uint16(code[pc+1])<<8)); err != nil {
				return 0, err
			}
			pc += 2
		case op == OpPushI32:
			if pc+4 > len(code) {
				return 0, ErrTrunc
			}
			u := uint32(code[pc]) | uint32(code[pc+1])<<8 | uint32(code[pc+2])<<16 | uint32(code[pc+3])<<24
			if err := push(int64(int32(u))); err != nil {
				return 0, err
			}
			pc += 4
		case op >= OpLoadA && op <= OpLoadA+3:
			if err := push(int64(in[op-OpLoadA])); err != nil {
				return 0, err
			}
		case op == OpNeg:
			a, err := pop()
			if err != nil {
				return 0, err
			}
			v, err := chk(-a)
			if err != nil {
				return 0, err
			}
			if err := push(v); err != nil {
				return 0, err
			}
		case op == OpClamp:
			hi, err := pop()
			if err != nil {
				return 0, err
			}
			lo, err := pop()
			if err != nil {
				return 0, err
			}
			x, err := pop()
			if err != nil {
				return 0, err
			}
			if err := push(minI(maxI(x, lo), hi)); err != nil {
				return 0, err
			}
		default:
			v, err := binary(op, pop, chk)
			if err != nil {
				return 0, err
			}
			if err := push(v); err != nil {
				return 0, err
			}
		}
	}
	if sp != 1 {
		return 0, ErrResult
	}
	return int32(st[0]), nil
}

// binary pops b then a and returns a op b, or ErrBadOp for an unknown opcode.
func binary(op byte, pop func() (int64, error), chk func(int64) (int64, error)) (int64, error) {
	switch op {
	case OpAdd, OpSub, OpMul, OpDiv, OpMod, OpAnd, OpOr, OpShl, OpShr, OpMin, OpMax:
	default:
		return 0, ErrBadOp
	}
	b, err := pop()
	if err != nil {
		return 0, err
	}
	a, err := pop()
	if err != nil {
		return 0, err
	}
	switch op {
	case OpAdd:
		return chk(a + b)
	case OpSub:
		return chk(a - b)
	case OpMul:
		return chk(a * b)
	case OpDiv:
		if b == 0 {
			return 0, ErrDivZero
		}
		// Go and C99 both truncate toward zero, so no adjustment is needed.
		return chk(a / b)
	case OpMod:
		if b == 0 {
			return 0, ErrDivZero
		}
		// Takes the sign of the dividend in both Go and C99. Cannot leave int32.
		return a % b, nil
	case OpAnd:
		return a & b, nil
	case OpOr:
		return a | b, nil
	case OpShl:
		if b < 0 || b > 31 {
			return 0, ErrShift
		}
		return chk(a << uint(b))
	case OpShr:
		if b < 0 || b > 31 {
			return 0, ErrShift
		}
		// Arithmetic in Go for signed values, as the contract requires: it floors.
		return a >> uint(b), nil
	case OpMin:
		return minI(a, b), nil
	}
	return maxI(a, b), nil
}

// ── hex ─────────────────────────────────────────────────────────────────────

// Hex renders bytecode as lowercase hex, the form the vectors use.
func Hex(code []byte) string {
	var b strings.Builder
	b.Grow(len(code) * 2)
	const digits = "0123456789abcdef"
	for _, c := range code {
		b.WriteByte(digits[c>>4])
		b.WriteByte(digits[c&0xf])
	}
	return b.String()
}

// FromHex parses bytecode hex, ignoring whitespace.
func FromHex(s string) ([]byte, error) {
	var clean []byte
	for i := 0; i < len(s); i++ {
		if c := s[i]; c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			clean = append(clean, c)
		}
	}
	if len(clean)%2 != 0 {
		return nil, fmt.Errorf("odd number of hex digits")
	}
	out := make([]byte, len(clean)/2)
	for i := range out {
		v, err := strconv.ParseUint(string(clean[2*i:2*i+2]), 16, 8)
		if err != nil {
			return nil, fmt.Errorf("bad hex digit")
		}
		out[i] = byte(v)
	}
	return out, nil
}
