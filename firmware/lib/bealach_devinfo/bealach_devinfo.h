/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_devinfo/bealach_devinfo.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * BLE device information and uplink events (contracts/ble/v1/device-info.md, contracts-v0.2.0).
 *
 * `DEVICE_INFO` answers "what are you?" before the phone relies on the dongle: capabilities,
 * firmware, identity, storage, transports, installed engines, boot timing. `UPLINK_EVENT` is
 * the notification the dongle sends before it leaves BLE for a Wi-Fi slot, and again on return.
 *
 * Portable C with no Arduino dependency: the encoder takes a plain struct, so it is checked
 * byte for byte against the contract's vectors on the host, and src/device_info.cpp only has
 * to fill the struct from the live state.
 *
 * The contract is DRAFT in the release this was written against. Nothing here invents a
 * layout: where the spec is silent the code says so. The two rules that matter most for a
 * reader are in the spec and enforced here:
 *   - an unknown record type is skipped by its length, which is how a newer minor version
 *     adds records without breaking an old app;
 *   - a KNOWN type with the wrong length is a malformed value and the whole thing is refused,
 *     rather than half-using a layout that is not understood.
 */

#ifndef BEALACH_DEVINFO_H
#define BEALACH_DEVINFO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BEALACH_DI_VERSION        1
#define BEALACH_DI_MINOR          0
#define BEALACH_DI_MAX_LEN        512
#define BEALACH_DI_HEADER_LEN     8
#define BEALACH_DI_MAX_TRANSPORTS 4
#define BEALACH_DI_MAX_ENGINES    32
#define BEALACH_DI_ENGINE_ID_MAX  32

/* Capability bits (the spec's table). An absent bit means the dongle cannot do it. */
enum {
    BEALACH_CAP_PHONE_GNSS   = 1u << 0,
    BEALACH_CAP_LIVE_OBD     = 1u << 1,
    BEALACH_CAP_OFFLOAD      = 1u << 2,
    BEALACH_CAP_DEVICE_INFO  = 1u << 3,
    BEALACH_CAP_UPLINK_EVENT = 1u << 4,
    BEALACH_CAP_INSTRUCTIONS = 1u << 5,
    BEALACH_CAP_HOME_TRIGGER = 1u << 6,
    BEALACH_CAP_WIFI         = 1u << 7,
    BEALACH_CAP_LTE          = 1u << 8,
    BEALACH_CAP_DIGEST       = 1u << 9,
    BEALACH_CAP_CONFIG       = 1u << 10,
    BEALACH_CAP_RESERVED     = 0xFFFFF800u   /* bits 11 to 31: must be 0 when sending */
};

/* Record types. */
enum {
    BEALACH_DI_REC_FIRMWARE  = 0x01,
    BEALACH_DI_REC_IDENTITY  = 0x02,
    BEALACH_DI_REC_STORAGE   = 0x03,
    BEALACH_DI_REC_TRANSPORT = 0x04,
    BEALACH_DI_REC_ENGINE    = 0x05,
    BEALACH_DI_REC_BOOT      = 0x06,
    BEALACH_DI_REC_TRUNCATED = 0x7F
};

/* firmware flags */
enum {
    BEALACH_FW_DIRTY        = 1u << 0,
    BEALACH_FW_RELEASE      = 1u << 1,
    BEALACH_FW_SECURE_BOOT  = 1u << 2,
    BEALACH_FW_FLASH_ENCRYPT = 1u << 3
};

typedef struct {
    uint8_t  major, minor, patch, flags;
    uint8_t  commit[8];         /* first 8 bytes of the git commit; zeros when unknown */
    uint32_t build_unix;
} bealach_di_firmware_t;

typedef struct {
    uint8_t  device_id[16];
    uint8_t  fingerprint[4];
    uint8_t  enrol_state;       /* 0 not enrolled, 1 enrolled, 2 assigned to a vehicle */
    uint32_t storage_key_version;
} bealach_di_identity_t;

typedef struct {
    uint8_t  state;             /* 0 no card, 1 ok, 2 read-only, 3 error */
    uint16_t pending_bundles;
    uint32_t free_mib;          /* 0xFFFFFFFF unknown */
} bealach_di_storage_t;

typedef struct {
    uint8_t  kind;              /* 1 BLE, 2 Wi-Fi, 3 LTE */
    uint8_t  state;             /* b0 hardware present, b1 compiled in, b2 configured, b3 enabled, b4 available now */
    uint16_t last_error;        /* 0 none */
} bealach_di_transport_t;

typedef struct {
    uint16_t profile_version;
    uint8_t  hash[8];           /* first 8 bytes of SHA-256 of the profile's canonical bytes */
    uint8_t  id_len;            /* 1..32 */
    char     id[BEALACH_DI_ENGINE_ID_MAX + 1];
} bealach_di_engine_t;

#define BEALACH_DI_UNKNOWN_MS 0xFFFFFFFFu

typedef struct {
    uint32_t to_ble_ms;         /* power-on to advertising */
    uint32_t to_ready_ms;       /* to able to start a capture */
    uint32_t to_first_fix_ms;   /* BEALACH_DI_UNKNOWN_MS = no fix yet */
    uint8_t  reset_reason;      /* the chip's own code */
} bealach_di_boot_t;

typedef struct {
    uint8_t  version;           /* decode only; the encoder always writes BEALACH_DI_VERSION */
    uint8_t  minor;
    uint32_t capabilities;

    bool                has_firmware, has_identity, has_storage, has_boot;
    bealach_di_firmware_t firmware;
    bealach_di_identity_t identity;
    bealach_di_storage_t  storage;
    bealach_di_boot_t     boot;

    uint8_t              n_transports;
    bealach_di_transport_t transports[BEALACH_DI_MAX_TRANSPORTS];

    uint8_t           n_engines;
    bealach_di_engine_t engines[BEALACH_DI_MAX_ENGINES];

    bool     truncated;         /* the engine list was cut to fit (record 0x7F) */
    uint8_t  unknown_records;   /* decode only: records of an unknown type that were skipped */
} bealach_devinfo_t;

/*
 * Encode. Records in ascending type order; the repeated types keep the caller's order. If the
 * value would exceed 512 bytes, engine records are dropped from the end until it fits and the
 * 0x7F record is appended: nothing else is ever dropped. `info->truncated` set by the caller
 * also emits 0x7F (the list was already cut upstream). Returns the length, or 0 if `cap` is
 * too small for what remains or a field is out of range (a bad engine id, reserved
 * capability bits set).
 */
size_t bealach_devinfo_encode(const bealach_devinfo_t *info, uint8_t *out, size_t cap);

typedef enum {
    BEALACH_DI_OK = 0,
    BEALACH_DI_ERR_SHORT,         /* fewer bytes than the header, or than a record claims */
    BEALACH_DI_ERR_VERSION,       /* an unknown major version */
    BEALACH_DI_ERR_LENGTH,        /* total_len is not the bytes read, or exceeds 512 */
    BEALACH_DI_ERR_RECORD,        /* a known record with the wrong length, or an out-of-order or repeated one */
    BEALACH_DI_ERR_OVERFLOW       /* more transports or engines than this build can hold */
} bealach_di_err_t;

/* Decode as an app must: refuse anything malformed, skip unknown record types. */
bealach_di_err_t bealach_devinfo_decode(bealach_devinfo_t *info, const uint8_t *in, size_t len);

/* ── UPLINK_EVENT ─────────────────────────────────────────────────────────── */

#define BEALACH_UE_LEN 24

enum { BEALACH_UE_LEAVING = 1, BEALACH_UE_RETURNED = 2, BEALACH_UE_ABORTED = 3 };
enum { BEALACH_UE_PATH_WIFI = 2, BEALACH_UE_PATH_LTE = 3 };
enum { BEALACH_UE_REASON_SCHEDULED = 1, BEALACH_UE_REASON_HOME_PHONE = 2, BEALACH_UE_REASON_RETRY = 3,
       BEALACH_UE_REASON_UPLOAD_NOW = 4, BEALACH_UE_REASON_TRIP = 5 };
enum { BEALACH_UE_OUTCOME_DONE = 0, BEALACH_UE_OUTCOME_PARTIAL = 1, BEALACH_UE_OUTCOME_FAILED = 2,
       BEALACH_UE_OUTCOME_NO_NETWORK = 3 };

typedef struct {
    uint8_t  kind, path, reason, outcome;
    uint32_t slot;
    uint16_t max_seconds;       /* LEAVING only */
    uint16_t committed;         /* RETURNED */
    uint16_t failed;            /* RETURNED */
    uint32_t bytes_sent;        /* RETURNED */
    uint32_t duration_ms;       /* RETURNED */
} bealach_uplink_event_t;

/* Always BEALACH_UE_LEN bytes, or 0 if `cap` is short or `kind` is outside 1..3. */
size_t bealach_uplink_event_encode(const bealach_uplink_event_t *e, uint8_t *out, size_t cap);

/* False for a frame that is not exactly 24 bytes, has `kind` outside 1..3 or a non-zero
 * reserved field: the app ignores and counts such frames. */
bool bealach_uplink_event_decode(bealach_uplink_event_t *e, const uint8_t *in, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_DEVINFO_H */
