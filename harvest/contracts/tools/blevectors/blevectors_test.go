package blevectors

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"os"
	"testing"
)

const vectorsPath = "../../contracts/ble/v1/vectors/device-info/vectors.json"

func TestVectorsFileIsCurrent(t *testing.T) {
	got, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatalf("%v (generate it: go run ./cmd/ble-vectors)", err)
	}
	if !bytes.Equal(got, JSON(Build())) {
		t.Fatal("the checked-in vectors differ from the generator's output; run: go run ./cmd/ble-vectors")
	}
}

func unhex(t *testing.T, s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDeviceInfoCases(t *testing.T) {
	for _, c := range Build().DeviceInfo {
		b := unhex(t, c.Hex)
		in, err := Decode(b)
		if c.Error {
			if err == nil {
				t.Errorf("%s: accepted", c.Name)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.Name, err)
			continue
		}
		if len(b) > MaxInfoLen {
			t.Errorf("%s: %d bytes exceeds %d", c.Name, len(b), MaxInfoLen)
		}
		// decode then encode must give the same bytes (unknown records are not re-emitted,
		// so skip that case)
		if len(in.Unknown) == 0 {
			if !bytes.Equal(Encode(in), b) {
				t.Errorf("%s: re-encoding differs", c.Name)
			}
		}
	}
}

func TestTruncationAndUnknownRecords(t *testing.T) {
	var many, fut *Info
	for _, c := range Build().DeviceInfo {
		decoded, err := Decode(unhex(t, c.Hex))
		if err != nil {
			continue
		}
		in := decoded
		switch c.Name[:6] {
		case "twenty":
			many = &in
		case "a newe":
			fut = &in
		}
	}
	if many == nil || !many.Truncated || len(many.Engines) == 0 || len(many.Engines) >= 20 {
		t.Fatalf("truncation case: %+v", many)
	}
	if fut == nil || len(fut.Unknown) != 1 || fut.Unknown[0].Type != 0x42 || fut.Firmware == nil || len(fut.Engines) != 2 {
		t.Fatalf("unknown-record case: %+v", fut)
	}
}

func TestUplinkEventAndHomeTrigger(t *testing.T) {
	f := Build()
	for _, c := range f.UplinkEvents {
		b := unhex(t, c.Hex)
		e, err := DecodeUplinkEvent(b)
		if c.Note == "must be rejected" {
			if err == nil {
				t.Errorf("%s: accepted", c.Name)
			}
			continue
		}
		if err != nil || !bytes.Equal(e.Encode(), b) {
			t.Errorf("%s: %v", c.Name, err)
		}
	}
	for _, c := range f.HomeTriggers {
		b := unhex(t, c.Hex)
		h, err := DecodeHomeTrigger(b)
		if c.Note == "must be rejected" {
			if err == nil {
				t.Errorf("%s: accepted", c.Name)
			}
			continue
		}
		if err != nil || !bytes.Equal(h.Encode(), b) {
			t.Errorf("%s: %v", c.Name, err)
		}
	}
}

func TestInstructionCases(t *testing.T) {
	f := Build()
	priv, dev := TestKeys()
	pub := priv.Public().(ed25519.PublicKey)
	for _, c := range f.Instructions {
		frame := unhex(t, c.Frame)
		st, fl, _ := Check(frame, dev, pub, c.FloorBefore)
		if st != c.WantStatus || fl != c.WantFloor {
			t.Errorf("%s: status %d floor %d, want %d and %d", c.Name, st, fl, c.WantStatus, c.WantFloor)
		}
		typ := byte(0)
		if len(frame) > 1 {
			typ = frame[1]
		}
		if hex.EncodeToString(Result(st, typ, fl)) != c.WantResult {
			t.Errorf("%s: result frame differs", c.Name)
		}
	}
}

// Statuses must cover the spec's list, and an applied instruction is the only way the floor moves.
func TestFloorOnlyMovesWhenApplied(t *testing.T) {
	priv, dev := TestKeys()
	pub := priv.Public().(ed25519.PublicKey)
	for _, c := range Build().Instructions {
		if c.WantStatus != StApplied && c.WantFloor != c.FloorBefore {
			t.Errorf("%s: refused but the floor moved", c.Name)
		}
	}
	// a signature cannot be reused for another purpose: the same bytes are not a uplink-v1 request
	frame := Instruction{InstUploadNow, 1, nil}.Sign(priv, dev)
	if st, _, _ := Check(frame, dev, pub, 0); st != StApplied {
		t.Fatal(st)
	}
}
