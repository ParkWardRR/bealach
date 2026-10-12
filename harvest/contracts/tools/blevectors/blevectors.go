// Package blevectors encodes, decodes and checks the frames of contracts/ble/v1/device-info.md
// and checkin.md, and produces their golden vectors. It is the reference for those layouts.
//
// Everything is little-endian. Every key is derived from a published label and protects
// nothing. Ed25519 is deterministic, so every signature is "must equal".
package blevectors

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
)

const Unknown32 = 0xFFFFFFFF

// ---- DEVICE_INFO ---------------------------------------------------------------------

const (
	RecFirmware  = 0x01
	RecIdentity  = 0x02
	RecStorage   = 0x03
	RecTransport = 0x04
	RecEngine    = 0x05
	RecBoot      = 0x06
	RecTruncated = 0x7F

	MaxInfoLen = 512
)

// Capability bits.
const (
	CapGNSS        = 1 << 0
	CapOBDLive     = 1 << 1
	CapOffload     = 1 << 2
	CapDeviceInfo  = 1 << 3
	CapUplinkEvent = 1 << 4
	CapInstruct    = 1 << 5
	CapHomeTrigger = 1 << 6
	CapWiFi        = 1 << 7
	CapLTE         = 1 << 8
	CapDigest      = 1 << 9
	CapConfig      = 1 << 10
)

type Firmware struct {
	Major, Minor, Patch, Flags uint8
	Commit                     [8]byte
	BuildUnix                  uint32
}

type Identity struct {
	DeviceID          [16]byte
	Fingerprint       [4]byte
	EnrolState        uint8
	StorageKeyVersion uint32
}

type Storage struct {
	State          uint8
	PendingBundles uint16
	FreeMiB        uint32
}

type Transport struct {
	Kind      uint8
	State     uint8
	LastError uint16
}

type Engine struct {
	ProfileVersion uint16
	Hash           [8]byte
	ID             string
}

type Boot struct {
	ToBLEms, ToReadyMs, ToFirstFixMs uint32
	ResetReason                      uint8
}

// Info is a decoded DEVICE_INFO value. Unknown records are kept in Unknown, in order.
type Info struct {
	Version, Minor uint8
	Capabilities   uint32
	Firmware       *Firmware
	Identity       *Identity
	Storage        *Storage
	Transports     []Transport
	Engines        []Engine
	Boot           *Boot
	Truncated      bool
	Unknown        []Record
}

type Record struct {
	Type  uint8
	Value []byte
}

func le32(b []byte, v uint32) []byte { return binary.LittleEndian.AppendUint32(b, v) }
func le16(b []byte, v uint16) []byte { return binary.LittleEndian.AppendUint16(b, v) }

func rec(out *bytes.Buffer, t uint8, v []byte) {
	if len(v) > 255 {
		panic("record too long")
	}
	out.WriteByte(t)
	out.WriteByte(byte(len(v)))
	out.Write(v)
}

// Encode produces the DEVICE_INFO value. Records are in ascending type order; the repeated
// ones (transport, engine) keep their given order. If the whole would exceed MaxInfoLen, engine
// records are dropped from the end and a TRUNCATED record is appended.
func Encode(in Info) []byte {
	build := func(engines []Engine, truncated bool) []byte {
		var body bytes.Buffer
		if f := in.Firmware; f != nil {
			v := []byte{f.Major, f.Minor, f.Patch, f.Flags}
			v = append(v, f.Commit[:]...)
			rec(&body, RecFirmware, le32(v, f.BuildUnix))
		}
		if i := in.Identity; i != nil {
			v := append(append([]byte{}, i.DeviceID[:]...), i.Fingerprint[:]...)
			v = append(v, i.EnrolState)
			rec(&body, RecIdentity, le32(v, i.StorageKeyVersion))
		}
		if s := in.Storage; s != nil {
			v := le16([]byte{s.State, 0}, s.PendingBundles)
			rec(&body, RecStorage, le32(v, s.FreeMiB))
		}
		for _, t := range in.Transports {
			rec(&body, RecTransport, le16([]byte{t.Kind, t.State}, t.LastError))
		}
		for _, e := range engines {
			v := le16(nil, e.ProfileVersion)
			v = append(v, e.Hash[:]...)
			v = append(v, byte(len(e.ID)))
			rec(&body, RecEngine, append(v, e.ID...))
		}
		if b := in.Boot; b != nil {
			v := le32(le32(le32(nil, b.ToBLEms), b.ToReadyMs), b.ToFirstFixMs)
			rec(&body, RecBoot, append(v, b.ResetReason, 0, 0, 0))
		}
		if truncated {
			rec(&body, RecTruncated, nil)
		}
		h := []byte{in.Version, in.Minor}
		h = le16(h, uint16(8+body.Len()))
		h = le32(h, in.Capabilities)
		return append(h, body.Bytes()...)
	}
	engines := in.Engines
	out := build(engines, in.Truncated)
	for len(out) > MaxInfoLen && len(engines) > 0 {
		engines = engines[:len(engines)-1]
		out = build(engines, true)
	}
	return out
}

var ErrInfo = errors.New("malformed DEVICE_INFO")

// Decode parses a DEVICE_INFO value. Unknown record types are skipped (kept in Unknown); a
// known record whose length is not what its type requires is an error, because a layout the
// reader does not understand must not be half used.
func Decode(b []byte) (Info, error) {
	var in Info
	if len(b) < 8 {
		return in, fmt.Errorf("%w: shorter than the 8-byte header", ErrInfo)
	}
	in.Version, in.Minor = b[0], b[1]
	if in.Version != 1 {
		return in, fmt.Errorf("%w: unknown major version %d", ErrInfo, in.Version)
	}
	total := int(binary.LittleEndian.Uint16(b[2:]))
	if total != len(b) || total > MaxInfoLen {
		return in, fmt.Errorf("%w: total_len %d, have %d bytes", ErrInfo, total, len(b))
	}
	in.Capabilities = binary.LittleEndian.Uint32(b[4:])
	for p := 8; p < len(b); {
		if p+2 > len(b) {
			return in, fmt.Errorf("%w: record header cut off", ErrInfo)
		}
		t, n := b[p], int(b[p+1])
		if p+2+n > len(b) {
			return in, fmt.Errorf("%w: record %#x overruns the value", ErrInfo, t)
		}
		v := b[p+2 : p+2+n]
		p += 2 + n
		bad := func(want string) error {
			return fmt.Errorf("%w: record %#x has length %d, want %s", ErrInfo, t, n, want)
		}
		switch t {
		case RecFirmware:
			if n != 16 {
				return in, bad("16")
			}
			f := &Firmware{Major: v[0], Minor: v[1], Patch: v[2], Flags: v[3], BuildUnix: binary.LittleEndian.Uint32(v[12:])}
			copy(f.Commit[:], v[4:12])
			in.Firmware = f
		case RecIdentity:
			if n != 25 {
				return in, bad("25")
			}
			i := &Identity{EnrolState: v[20], StorageKeyVersion: binary.LittleEndian.Uint32(v[21:])}
			copy(i.DeviceID[:], v[:16])
			copy(i.Fingerprint[:], v[16:20])
			in.Identity = i
		case RecStorage:
			if n != 8 {
				return in, bad("8")
			}
			in.Storage = &Storage{State: v[0], PendingBundles: binary.LittleEndian.Uint16(v[2:]), FreeMiB: binary.LittleEndian.Uint32(v[4:])}
		case RecTransport:
			if n != 4 {
				return in, bad("4")
			}
			in.Transports = append(in.Transports, Transport{Kind: v[0], State: v[1], LastError: binary.LittleEndian.Uint16(v[2:])})
		case RecEngine:
			if n < 12 || n != 11+int(v[10]) || v[10] < 1 || v[10] > 32 {
				return in, bad("11 + id_len, with id_len 1..32")
			}
			e := Engine{ProfileVersion: binary.LittleEndian.Uint16(v), ID: string(v[11:])}
			copy(e.Hash[:], v[2:10])
			in.Engines = append(in.Engines, e)
		case RecBoot:
			if n != 16 {
				return in, bad("16")
			}
			in.Boot = &Boot{binary.LittleEndian.Uint32(v), binary.LittleEndian.Uint32(v[4:]), binary.LittleEndian.Uint32(v[8:]), v[12]}
		case RecTruncated:
			if n != 0 {
				return in, bad("0")
			}
			in.Truncated = true
		default:
			in.Unknown = append(in.Unknown, Record{t, append([]byte{}, v...)})
		}
	}
	return in, nil
}

// ---- UPLINK_EVENT and HOME_TRIGGER ----------------------------------------------------

const (
	EvLeaving, EvReturned, EvAborted = 1, 2, 3
)

type UplinkEvent struct {
	Kind, Path, Reason, Outcome uint8
	Slot                        uint32
	MaxSeconds                  uint16
	Committed, Failed           uint16
	BytesSent, DurationMs       uint32
}

func (e UplinkEvent) Encode() []byte {
	b := []byte{e.Kind, e.Path, e.Reason, e.Outcome}
	b = le32(b, e.Slot)
	b = le16(b, e.MaxSeconds)
	b = le16(b, e.Committed)
	b = le16(b, e.Failed)
	b = le16(b, 0)
	b = le32(b, e.BytesSent)
	return le32(b, e.DurationMs)
}

func DecodeUplinkEvent(b []byte) (UplinkEvent, error) {
	if len(b) != 24 {
		return UplinkEvent{}, fmt.Errorf("UPLINK_EVENT is 24 bytes, got %d", len(b))
	}
	if b[0] < EvLeaving || b[0] > EvAborted || binary.LittleEndian.Uint16(b[14:]) != 0 {
		return UplinkEvent{}, errors.New("UPLINK_EVENT: unknown kind or non-zero reserved")
	}
	return UplinkEvent{b[0], b[1], b[2], b[3], binary.LittleEndian.Uint32(b[4:]), binary.LittleEndian.Uint16(b[8:]),
		binary.LittleEndian.Uint16(b[10:]), binary.LittleEndian.Uint16(b[12:]), binary.LittleEndian.Uint32(b[16:]), binary.LittleEndian.Uint32(b[20:])}, nil
}

// HomeTrigger is the phone-asserted "you may use Wi-Fi now" (6 bytes).
type HomeTrigger struct {
	Home         bool
	ValidSeconds uint16
	Seq          uint16
}

const MaxHomeSeconds = 900

func (h HomeTrigger) Encode() []byte {
	f := byte(0)
	if h.Home {
		f = 1
	}
	return le16(le16([]byte{f, 0}, h.ValidSeconds), h.Seq)
}

// DecodeHomeTrigger returns an error (the firmware answers with an ATT error and counts it)
// for a wrong length, reserved bits set, or valid_seconds above the cap.
func DecodeHomeTrigger(b []byte) (HomeTrigger, error) {
	if len(b) != 6 || b[0]&^1 != 0 || b[1] != 0 {
		return HomeTrigger{}, errors.New("HOME_TRIGGER: want 6 bytes with only bit 0 of flags and a zero reserved byte")
	}
	h := HomeTrigger{Home: b[0] == 1, ValidSeconds: binary.LittleEndian.Uint16(b[2:]), Seq: binary.LittleEndian.Uint16(b[4:])}
	if h.ValidSeconds > MaxHomeSeconds {
		return HomeTrigger{}, fmt.Errorf("HOME_TRIGGER: valid_seconds %d above %d", h.ValidSeconds, MaxHomeSeconds)
	}
	return h, nil
}

// ---- INSTRUCTION ----------------------------------------------------------------------

const (
	InstUploadNow  = 0x01
	InstStopTrying = 0x02
	InstConfig     = 0x03
	InstClearStop  = 0x04

	MaxInstruction = 512
	instHeader     = 8
	sigLen         = 64
)

// Result statuses (INSTRUCTION_RESULT byte 0).
const (
	StApplied            = 0
	StBadSignature       = 1
	StReplay             = 2
	StUnknownType        = 3
	StBadLength          = 4
	StRateLimited        = 5
	StTripActive         = 6
	StEncryptionRequired = 7
	StOutOfRange         = 8
)

// Instruction is an unsigned instruction; Sign produces the wire frame.
type Instruction struct {
	Type    uint8
	Counter uint32
	Body    []byte
}

func signedBytes(deviceID [16]byte, head []byte) []byte {
	return append(append([]byte("CAIRN-INSTR-V1\x00"), deviceID[:]...), head...)
}

// Sign builds the frame: u8 version=1, u8 type, u16 body_len, u32 counter, body, sig[64], where
// sig is Ed25519 over "CAIRN-INSTR-V1" 0x00 device_id frame[0 : 8+body_len].
func (i Instruction) Sign(priv ed25519.PrivateKey, deviceID [16]byte) []byte {
	f := le32(le16([]byte{1, i.Type}, uint16(len(i.Body))), i.Counter)
	f = append(f, i.Body...)
	return append(f, ed25519.Sign(priv, signedBytes(deviceID, f))...)
}

// Check is the dongle's decision for one frame: the status, the new counter floor, and (when
// applied) the decoded instruction. floor is the highest counter already accepted. The order
// is the spec's: length, signature, type, counter, range.
func Check(frame []byte, deviceID [16]byte, pub ed25519.PublicKey, floor uint32) (status uint8, newFloor uint32, inst *Instruction) {
	if len(frame) < instHeader+sigLen || len(frame) > MaxInstruction || frame[0] != 1 {
		return StBadLength, floor, nil
	}
	n := int(binary.LittleEndian.Uint16(frame[2:]))
	if len(frame) != instHeader+n+sigLen {
		return StBadLength, floor, nil
	}
	head := frame[:instHeader+n]
	if !ed25519.Verify(pub, signedBytes(deviceID, head), frame[instHeader+n:]) {
		return StBadSignature, floor, nil
	}
	t, ctr, body := frame[1], binary.LittleEndian.Uint32(frame[4:]), frame[instHeader:instHeader+n]
	switch t {
	case InstUploadNow, InstClearStop:
		if n != 0 {
			return StBadLength, floor, nil
		}
	case InstStopTrying:
		if n != 2 {
			return StBadLength, floor, nil
		}
	case InstConfig:
		if n == 0 {
			return StBadLength, floor, nil
		}
	default:
		return StUnknownType, floor, nil
	}
	if ctr <= floor {
		return StReplay, floor, nil
	}
	if t == InstStopTrying {
		if h := binary.LittleEndian.Uint16(body); h < 1 || h > 168 {
			return StOutOfRange, floor, nil
		}
	}
	return StApplied, ctr, &Instruction{t, ctr, append([]byte{}, body...)}
}

// Result encodes INSTRUCTION_RESULT: u8 status, u8 type, u16 reserved=0, u32 counter_floor.
func Result(status, typ uint8, floor uint32) []byte {
	return le32(le16([]byte{status, typ}, 0), floor)
}

// ---- the vectors ----------------------------------------------------------------------

func label(s string) []byte { h := sha256.Sum256([]byte(s)); return h[:] }

// TestKeys returns the public test server (instruction) key and the test device id.
func TestKeys() (priv ed25519.PrivateKey, deviceID [16]byte) {
	priv = ed25519.NewKeyFromSeed(label("cairn/ble-v1/test-instruction-key-seed"))
	copy(deviceID[:], label("cairn/ble-v1/test-device-id"))
	return
}

type InfoCase struct {
	Name    string          `json:"name"`
	Hex     string          `json:"hex"`
	Decoded json.RawMessage `json:"decoded,omitempty"`
	Error   bool            `json:"must_be_rejected,omitempty"`
}

type FrameCase struct {
	Name string `json:"name"`
	Hex  string `json:"hex"`
	Note string `json:"note,omitempty"`
}

type InstructionCase struct {
	Name        string `json:"name"`
	Frame       string `json:"frame"`
	FloorBefore uint32 `json:"counter_floor_before"`
	WantStatus  uint8  `json:"want_status"`
	WantFloor   uint32 `json:"want_counter_floor_after"`
	WantResult  string `json:"want_result"`
	SignedBytes string `json:"signed_bytes,omitempty"`
	Description string `json:"description"`
}

type File struct {
	Description     string            `json:"description"`
	InstructionKey  string            `json:"instruction_public_key"`
	InstructionSeed string            `json:"instruction_seed"`
	DeviceID        string            `json:"device_id"`
	DeviceInfo      []InfoCase        `json:"device_info"`
	UplinkEvents    []FrameCase       `json:"uplink_event"`
	HomeTriggers    []FrameCase       `json:"home_trigger"`
	Instructions    []InstructionCase `json:"instruction"`
}

func h(b []byte) string { return hex.EncodeToString(b) }

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func sha8(s string) (o [8]byte) { copy(o[:], label(s)[:8]); return }

func sampleInfo() Info {
	var fw Firmware
	fw = Firmware{0, 3, 1, 0b1100, sha8("commit"), 1790000000}
	copy(fw.Commit[:], []byte{0xab, 0xc1, 0x23, 0x45, 0x67, 0x89, 0xde, 0xf0})
	var id Identity
	_, dev := TestKeys()
	id = Identity{DeviceID: dev, EnrolState: 2, StorageKeyVersion: 1}
	copy(id.Fingerprint[:], label("cairn/ble-v1/test-device-pub")[:4])
	return Info{
		Version: 1, Minor: 0,
		Capabilities: CapGNSS | CapOBDLive | CapOffload | CapDeviceInfo | CapUplinkEvent | CapInstruct | CapHomeTrigger | CapWiFi,
		Firmware:     &fw, Identity: &id,
		Storage:    &Storage{State: 1, PendingBundles: 3, FreeMiB: 29876},
		Transports: []Transport{{1, 0b11111, 0}, {2, 0b11111, 0}, {3, 0b00011, 0}},
		Engines: []Engine{
			{1, sha8("bmw-n20 profile v1"), "bmw-n20"},
			{1, sha8("bmw-b58 profile v1"), "bmw-b58"},
		},
		Boot: &Boot{ToBLEms: 820, ToReadyMs: 2310, ToFirstFixMs: Unknown32, ResetReason: 1},
	}
}

// Build produces the whole vectors file.
func Build() File {
	priv, dev := TestKeys()
	pub := priv.Public().(ed25519.PublicKey)
	f := File{
		Description:    "Cairn BLE v1 device information, uplink events, home trigger and signed instructions (DRAFT). Every key here is a PUBLIC TEST KEY derived from a published label; none protects anything. Ed25519 signatures are deterministic: must equal.",
		InstructionKey: h(pub), InstructionSeed: h(priv.Seed()), DeviceID: h(dev[:]),
	}

	full := sampleInfo()
	fullB := Encode(full)
	minimal := Info{Version: 1, Capabilities: CapGNSS}
	minB := Encode(minimal)
	// a future minor version carries a record type this reader does not know: it is skipped
	fut := sampleInfo()
	fut.Minor = 1
	futB := Encode(fut)
	futB = append(futB[:len(futB):len(futB)], 0x42, 3, 1, 2, 3)
	binary.LittleEndian.PutUint16(futB[2:], uint16(len(futB)))
	// many engines: the list is cut and the truncation is flagged
	many := sampleInfo()
	many.Engines = nil
	for i := 0; i < 20; i++ {
		many.Engines = append(many.Engines, Engine{1, sha8(fmt.Sprint("e", i)), fmt.Sprintf("test-engine-%02d-padding-padding", i)})
	}
	manyB := Encode(many)
	badLen := append([]byte{}, fullB...)
	binary.LittleEndian.PutUint16(badLen[2:], uint16(len(badLen)+1))
	badMajor := append([]byte{}, minB...)
	badMajor[0] = 2
	badRec := append([]byte{}, fullB...)
	badRec[8+1]-- // firmware record claims 15 bytes
	dec := func(b []byte) json.RawMessage {
		in, err := Decode(b)
		if err != nil {
			panic(err)
		}
		return mustJSON(in)
	}
	f.DeviceInfo = []InfoCase{
		{Name: "full: two engines, three transports, boot timing", Hex: h(fullB), Decoded: dec(fullB)},
		{Name: "minimal: header only", Hex: h(minB), Decoded: dec(minB)},
		{Name: "a newer minor version with an unknown record type 0x42: skipped, the rest read", Hex: h(futB), Decoded: dec(futB)},
		{Name: "twenty engines do not fit in 512 bytes: the list is cut and TRUNCATED is set", Hex: h(manyB), Decoded: dec(manyB)},
		{Name: "total_len does not match the bytes read", Hex: h(badLen), Error: true},
		{Name: "unknown major version 2", Hex: h(badMajor), Error: true},
		{Name: "a known record with the wrong length", Hex: h(badRec), Error: true},
	}

	ev := []struct {
		n    string
		e    UplinkEvent
		note string
	}{
		{"leaving for Wi-Fi, slot 12, back within 90 s", UplinkEvent{Kind: EvLeaving, Path: 2, Reason: 1, Slot: 12, MaxSeconds: 90}, "reason 1 = scheduled"},
		{"returned after a slot: 2 committed, 1 failed", UplinkEvent{Kind: EvReturned, Path: 2, Reason: 1, Outcome: 1, Slot: 12, Committed: 2, Failed: 1, BytesSent: 1048576, DurationMs: 61400}, "outcome 1 = partial"},
		{"slot aborted because a trip started", UplinkEvent{Kind: EvAborted, Path: 2, Reason: 5, Slot: 13}, "reason 5 = trip started"},
	}
	for _, c := range ev {
		f.UplinkEvents = append(f.UplinkEvents, FrameCase{c.n, h(c.e.Encode()), c.note})
	}
	f.UplinkEvents = append(f.UplinkEvents, FrameCase{"23 bytes: rejected", h(ev[0].e.Encode()[:23]), "must be rejected"})

	f.HomeTriggers = []FrameCase{
		{"home, valid for 600 s, seq 1", h(HomeTrigger{true, 600, 1}.Encode()), ""},
		{"not home (withdraws the permission), seq 2", h(HomeTrigger{false, 0, 2}.Encode()), ""},
		{"valid_seconds 901: rejected", h(HomeTrigger{true, 901, 3}.Encode()), "must be rejected"},
		{"a reserved flag bit set: rejected", "02000000" + "0400", "must be rejected"},
	}

	add := func(name, desc string, frame []byte, floor uint32) {
		st, nf, _ := Check(frame, dev, pub, floor)
		typ := byte(0)
		if len(frame) > 1 {
			typ = frame[1]
		}
		f.Instructions = append(f.Instructions, InstructionCase{Name: name, Description: desc, Frame: h(frame), FloorBefore: floor,
			WantStatus: st, WantFloor: nf, WantResult: h(Result(st, typ, nf))})
	}
	upload := Instruction{InstUploadNow, 7, nil}.Sign(priv, dev)
	stop := Instruction{InstStopTrying, 8, []byte{24, 0}}.Sign(priv, dev)
	cfgBody := bytes.Repeat([]byte{0xC5}, 100) // a stand-in for a config/v1 sealed message: opaque here
	cfg := Instruction{InstConfig, 9, cfgBody}.Sign(priv, dev)
	add("upload now, counter 7", "applies; the floor rises to 7", upload, 0)
	add("stop trying for 24 hours, counter 8", "applies", stop, 7)
	add("config carrying an opaque 100-byte body, counter 9", "applies; the body is handed to config/v1 unread by this layer", cfg, 8)
	add("the same upload-now frame again (counter 7, floor 9)", "replay: refused, floor unchanged", upload, 9)
	add("an old frame with the floor at its own counter", "counter equal to the floor is a replay", stop, 8)
	flipped := append([]byte{}, upload...)
	flipped[len(flipped)-1] ^= 1
	add("one bit of the signature flipped", "refused before anything else is looked at", flipped, 0)
	body := append([]byte{}, stop...)
	body[instHeader] = 25
	add("the body changed after signing (24 h became 25 h)", "signature covers the body", body, 7)
	other := Instruction{InstUploadNow, 7, nil}.Sign(priv, [16]byte{1})
	add("signed for another device id", "the device id is inside the signed bytes", other, 0)
	unk := Instruction{0x7E, 10, nil}.Sign(priv, dev)
	add("a correctly signed instruction of an unknown type 0x7E", "the set is closed: unknown means refused, however well signed", unk, 9)
	range0 := Instruction{InstStopTrying, 11, []byte{0, 0}}.Sign(priv, dev)
	add("stop trying for 0 hours", "out of range 1..168", range0, 10)
	range169 := Instruction{InstStopTrying, 12, []byte{169, 0}}.Sign(priv, dev)
	add("stop trying for 169 hours", "out of range 1..168", range169, 11)
	short := Instruction{InstStopTrying, 13, []byte{24}}.Sign(priv, dev)
	add("stop trying with a one-byte body", "bad length for the type", short, 12)
	add("a frame cut off before its signature ends", "bad length", upload[:len(upload)-1], 0)
	big := Instruction{InstConfig, 14, bytes.Repeat([]byte{1}, 441)}.Sign(priv, dev)
	add("a frame of 513 bytes", "over the 512-byte limit: bad length", big, 13)
	return f
}

func JSON(f File) []byte {
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		panic(err)
	}
	return append(b, '\n')
}
