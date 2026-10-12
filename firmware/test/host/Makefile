# Host builds of the firmware's portable code.
#
# Migrated from cairn-esp32-device-firmware.  The excluded modules (modem,
# uplink, checkin, OTA, digest, usage) are Cairn server/uplink paths and are
# out of Bealach scope.
#
#   conformance  compiles lib/bealach_format against the committed vectors, so
#                this implementation is shown to agree byte-for-byte with the
#                Go and Rust ones.
#   faults       compiles lib/bealach_store and lib/bealach_prune over a POSIX
#                filesystem, then tears files and forges receipts. These are
#                properties about crash and adversarial behaviour; compiling
#                for ESP32 does not test them and neither does a good drive.
#
# Both compile exactly the sources the device runs — no substitutions — reached
# through bealach_fs rather than reimplemented.
#
#   make           build and run both
#   make asan      the same, under AddressSanitizer and UBSan
#   make clean

CC       ?= cc

# The contracts (specs and vectors). CAIRN_CONTRACTS is the contracts directory
# itself (the one that contains format/, sync/, ble/).
CAIRN_CONTRACTS ?= ../../../contracts
FIXTURES        ?= $(CAIRN_CONTRACTS)/format/v3/vectors
ENROLL_VECTORS  ?= $(CAIRN_CONTRACTS)/enrolment/v1/vectors/vectors.json

FORMAT_DIR := ../../lib/bealach_format
STORE_DIR  := ../../lib/bealach_store
FS_DIR     := ../../lib/bealach_fs
INCLUDE_DIR := ../../include
LOG_DIR     := ../../lib/bealach_log
PROV_DIR    := ../../lib/bealach_prov
OFFLOAD_DIR := ../../lib/bealach_offload
BOOTTIME_DIR := ../../lib/bealach_boottime
BLESEC_DIR := ../../lib/bealach_blesec
CONFIG_DIR  := ../../lib/bealach_config
DEVINFO_DIR := ../../lib/bealach_devinfo
INTAKE_DIR  := ../../lib/bealach_intake
BUNDLE_DIR  := ../../lib/bealach_bundle

FORMAT_SRC := $(wildcard $(FORMAT_DIR)/*.c)
STORE_SRC  := $(wildcard $(STORE_DIR)/*.c)
FS_SRC     := $(wildcard $(FS_DIR)/*.c)

# The standby decisions; the execution half is in src/ and Arduino.
POWER_DIR  := ../../lib/bealach_power

# Only the portable application sources; the rest of src/ is Arduino C++.
SRC_DIR    := ../../src
# policy.c and bealach_power.c take their engine-dependent values from the profile, so every
# binary that links them links the engine module too.
ENGINE_DIR := ../../lib/bealach_engine
ENGINE_LIB_SRC := $(ENGINE_DIR)/bealach_engine.c $(ENGINE_DIR)/bealach_expr.c
APP_SRC    := $(SRC_DIR)/preroll.c $(SRC_DIR)/policy.c $(POWER_DIR)/bealach_power.c $(ENGINE_LIB_SRC)

# The conformance runner needs the policy codec, which lives in src/.
BLE_VECTORS     ?= $(CAIRN_CONTRACTS)/ble/v1/vectors/golden/golden-vectors.json
CONFORMANCE_SRC := $(FORMAT_SRC) $(SRC_DIR)/policy.c minijson.c conformance.c
FAULTS_SRC      := $(FORMAT_SRC) $(STORE_SRC) $(FS_SRC) $(APP_SRC) \
                   log_host.c platform_host.c faults.c
BLE_VEC_SRC     := $(FORMAT_SRC) minijson.c ble_vectors.c
# Provisioning needs only the format primitives, its own sources, and the host
# key-value store (so the credential slots run against the real slot code).
PROV_SRC        := $(FORMAT_SRC) $(wildcard $(PROV_DIR)/*.c) $(FS_DIR)/bealach_kv_posix.c minijson.c owner_key_stub.c prov_test.c

# The BLE offload protocol: the module, over the real store and prune code, in
# front of a simulated BLE stack and phone.
OFFLOAD_SRC     := $(FORMAT_SRC) $(STORE_SRC) $(FS_SRC) $(APP_SRC) $(OFFLOAD_DIR)/bealach_offload.c \
                   log_host.c platform_host.c offload_test.c

# A dongle on a pipe, for the Go end-to-end test (server/internal/offloadclient).
OFFLOAD_SIM_SRC := $(FORMAT_SRC) $(STORE_SRC) $(FS_SRC) $(APP_SRC) $(OFFLOAD_DIR)/bealach_offload.c \
                   log_host.c platform_host.c offload_sim.c

CFLAGS  ?= -std=c11 -O1 -g -D_DEFAULT_SOURCE \
           -Wall -Wextra -Werror -Wno-format-truncation \
           -Wshadow -Wpointer-arith -Wcast-qual -Wstrict-prototypes \
           -Wmissing-prototypes -Wno-unused-parameter \
           -I$(FORMAT_DIR) -I$(STORE_DIR) -I$(FS_DIR) -I$(LOG_DIR) -I$(PROV_DIR) -I$(INCLUDE_DIR) -I$(SRC_DIR) -I$(POWER_DIR) -I$(OFFLOAD_DIR) -I$(BOOTTIME_DIR) -I$(CONFIG_DIR) -I$(DEVINFO_DIR) -I$(INTAKE_DIR) -I$(BUNDLE_DIR) -I.

# Every header the sources can include.
HEADERS := $(wildcard $(OFFLOAD_DIR)/*.h $(PROV_DIR)/*.h $(FORMAT_DIR)/*.h $(STORE_DIR)/*.h $(FS_DIR)/*.h $(LOG_DIR)/*.h \
                      $(INCLUDE_DIR)/*.h $(SRC_DIR)/*.h $(POWER_DIR)/*.h $(BOOTTIME_DIR)/*.h $(CONFIG_DIR)/*.h $(DEVINFO_DIR)/*.h $(INTAKE_DIR)/*.h $(BUNDLE_DIR)/*.h *.h)

SAN := -fsanitize=address,undefined -fno-omit-frame-pointer

BUILD := build

# Engine profiles (lib/bealach_engine): see engine.mk.
include engine.mk

.PHONY: all run asan clean conformance faults ble-vectors mtprobe prov offload offload-sim boottime blesec config devinfo nvswipe intake bundle

all: run

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/conformance: $(CONFORMANCE_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(CONFORMANCE_SRC) -o $@

$(BUILD)/faults: $(FAULTS_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(FAULTS_SRC) -o $@

$(BUILD)/ble-vectors: $(BLE_VEC_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(BLE_VEC_SRC) -lm -o $@

conformance: $(BUILD)/conformance
	$(BUILD)/conformance $(FIXTURES)

faults: $(BUILD)/faults
	$(BUILD)/faults

ble-vectors: $(BUILD)/ble-vectors
	$(BUILD)/ble-vectors $(BLE_VECTORS)

$(BUILD)/prov: $(PROV_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(PROV_SRC) -o $@

prov: $(BUILD)/prov
	BEALACH_ENROLL_VECTORS=$(ENROLL_VECTORS) $(BUILD)/prov

$(BUILD)/offload: $(OFFLOAD_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(OFFLOAD_SRC) -o $@

offload: $(BUILD)/offload
	$(BUILD)/offload

$(BUILD)/offload-sim: $(OFFLOAD_SIM_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(OFFLOAD_SIM_SRC) -o $@

offload-sim: $(BUILD)/offload-sim

$(BUILD)/nvswipe: $(FS_DIR)/bealach_nvs_wipe.c nvs_wipe_test.c $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(FS_DIR)/bealach_nvs_wipe.c nvs_wipe_test.c -o $@

nvswipe: $(BUILD)/nvswipe
	$(BUILD)/nvswipe

$(BUILD)/mtprobe: $(SRC_DIR)/mtprobe_parse.c $(HEADERS) mtprobe_parse_test.c | $(BUILD)
	$(CC) $(CFLAGS) $(SRC_DIR)/mtprobe_parse.c mtprobe_parse_test.c -o $@

mtprobe: $(BUILD)/mtprobe
	$(BUILD)/mtprobe

$(BUILD)/boottime: $(BOOTTIME_DIR)/bealach_boottime.c boottime_test.c $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(BOOTTIME_DIR)/bealach_boottime.c boottime_test.c -o $@

boottime: $(BUILD)/boottime
	$(BUILD)/boottime

$(BUILD)/blesec: $(BLESEC_DIR)/bealach_blesec.h blesec_test.c | $(BUILD)
	$(CC) $(CFLAGS) -I$(BLESEC_DIR) blesec_test.c -o $@

blesec: $(BUILD)/blesec
	$(BUILD)/blesec

# The intake client: the module over a simulated server and a simulated card.
# It needs the format primitives for SHA-256 and nothing else.
INTAKE_SRC := $(FORMAT_SRC) $(INTAKE_DIR)/bealach_intake.c log_host.c intake_test.c

$(BUILD)/intake: $(INTAKE_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(INTAKE_SRC) -o $@

intake: $(BUILD)/intake
	$(BUILD)/intake

# The sealed-bundle reader, over the real store and a POSIX card.
BUNDLE_SRC := $(FORMAT_SRC) $(STORE_SRC) $(FS_SRC) \
              $(INTAKE_DIR)/bealach_intake.c $(BUNDLE_DIR)/bealach_bundle.c \
              log_host.c platform_host.c bundle_test.c

$(BUILD)/bundle: $(BUNDLE_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(BUNDLE_SRC) -o $@

bundle: $(BUILD)/bundle
	$(BUILD)/bundle

CONFIG_SRC := $(FORMAT_SRC) $(FS_DIR)/bealach_kv_posix.c $(CONFIG_DIR)/bealach_config.c config_test.c

$(BUILD)/config: $(CONFIG_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(CONFIG_SRC) -o $@

config: $(BUILD)/config
	$(BUILD)/config

# DEVICE_INFO and UPLINK_EVENT against the contract's vectors.
DEVINFO_VECTORS ?= $(CAIRN_CONTRACTS)/ble/v1/vectors/device-info/vectors.json
DEVINFO_SRC     := $(DEVINFO_DIR)/bealach_devinfo.c minijson.c devinfo_test.c
DEVINFO_CFLAGS  := $(CFLAGS) -DMJ_MAX_NODES=2500 -DMJ_MAX_STR=1100

.PHONY: devinfo

$(BUILD)/devinfo: $(DEVINFO_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(DEVINFO_CFLAGS) $(DEVINFO_SRC) -o $@

devinfo: $(BUILD)/devinfo
	$(BUILD)/devinfo $(DEVINFO_VECTORS)

ifneq ($(wildcard $(DEVINFO_VECTORS)),)
run: devinfo
else
$(info device-info vectors not in this contracts pin (needs contracts-v0.2.0): devinfo row skipped)
endif

run: conformance faults ble-vectors mtprobe prov offload boottime blesec config nvswipe intake bundle

asan: | $(BUILD)
	$(CC) $(CFLAGS) $(SAN) $(CONFORMANCE_SRC) -o $(BUILD)/conformance-asan
	$(BUILD)/conformance-asan $(FIXTURES)
	$(CC) $(CFLAGS) $(SAN) $(FAULTS_SRC) -o $(BUILD)/faults-asan
	$(BUILD)/faults-asan
	$(CC) $(CFLAGS) $(SAN) $(BLE_VEC_SRC) -lm -o $(BUILD)/ble-vectors-asan
	$(BUILD)/ble-vectors-asan $(BLE_VECTORS)
	$(CC) $(CFLAGS) $(SAN) $(SRC_DIR)/mtprobe_parse.c mtprobe_parse_test.c -o $(BUILD)/mtprobe-asan
	$(BUILD)/mtprobe-asan
	$(CC) $(CFLAGS) $(SAN) $(PROV_SRC) -o $(BUILD)/prov-asan
	BEALACH_ENROLL_VECTORS=$(ENROLL_VECTORS) $(BUILD)/prov-asan
	$(CC) $(CFLAGS) $(SAN) $(OFFLOAD_SRC) -o $(BUILD)/offload-asan
	$(BUILD)/offload-asan
	$(CC) $(CFLAGS) $(SAN) $(BOOTTIME_DIR)/bealach_boottime.c boottime_test.c -o $(BUILD)/boottime-asan
	$(BUILD)/boottime-asan
	$(CC) $(CFLAGS) $(SAN) $(FS_DIR)/bealach_nvs_wipe.c nvs_wipe_test.c -o $(BUILD)/nvswipe-asan
	$(BUILD)/nvswipe-asan
	$(CC) $(CFLAGS) $(SAN) $(CONFIG_SRC) -o $(BUILD)/config-asan
	$(BUILD)/config-asan
	$(if $(wildcard $(DEVINFO_VECTORS)),$(CC) $(DEVINFO_CFLAGS) $(SAN) $(DEVINFO_SRC) -o $(BUILD)/devinfo-asan && $(BUILD)/devinfo-asan $(DEVINFO_VECTORS))
	$(CC) $(CFLAGS) $(SAN) $(INTAKE_SRC) -o $(BUILD)/intake-asan
	$(BUILD)/intake-asan
	$(CC) $(CFLAGS) $(SAN) $(BUNDLE_SRC) -o $(BUILD)/bundle-asan
	$(BUILD)/bundle-asan

clean:
	rm -rf $(BUILD)

# ── the C writer, for the server's reader ───────────────────────────────────────
INTEROP_OUT    ?= $(BUILD)/interop-out
INTEROP_W_SRC  := $(FORMAT_SRC) $(STORE_SRC) $(FS_SRC) $(APP_SRC) \
                  log_host.c platform_host.c interop_writer.c

.PHONY: interop-writer interop-writer-asan

$(BUILD)/interop-writer: $(INTEROP_W_SRC) $(HEADERS) | $(BUILD)
	$(CC) $(CFLAGS) $(INTEROP_W_SRC) -o $@

interop-writer: $(BUILD)/interop-writer
	rm -rf $(INTEROP_OUT)
	$(BUILD)/interop-writer $(INTEROP_OUT)

interop-writer-asan: | $(BUILD)
	$(CC) $(CFLAGS) $(SAN) $(INTEROP_W_SRC) -o $(BUILD)/interop-writer-asan
	rm -rf $(INTEROP_OUT)-asan
	$(BUILD)/interop-writer-asan $(INTEROP_OUT)-asan

run: interop-writer
asan: interop-writer-asan
