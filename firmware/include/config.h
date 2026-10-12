/* Provenance: cairn-esp32-device-firmware @ ead3532, include/config.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * Build-time configuration, with placeholders when secrets.h is absent.
 *
 * The repository is public, so every value here is either a placeholder or a
 * policy constant. Real hostnames, credentials and the pinned server key live
 * in src/secrets.h, which is gitignored.
 */

#ifndef BEALACH_CONFIG_H
#define BEALACH_CONFIG_H

#if __has_include("secrets.h")
#include "secrets.h"
#endif

/*
 * The phone over BLE is the everyday path, and the only one that needs nothing
 * from this file (contracts/ble/v1/offload.md). Since the uplink schedule entered
 * the production build, Wi-Fi mTLS and LTE are compiled in too, so the device
 * does hold transport credentials: an SSID and PSK, a server address, a CA, a
 * client certificate and its key. Every one of them has a fail-closed default
 * below, because this header's promise is that the project builds without a
 * secrets.h at all — a fresh clone and CI both rely on it.
 *
 * Pinned server enrolment public key (X25519, 32 bytes, hex). The device seals
 * its storage root to this key, so the all-zero placeholder makes it REFUSE to
 * produce an enrolment blob rather than seal to a key nobody holds. Get the real
 * value from `cairn-server -print-enroll-key` and put it in secrets.h.
 */
#ifndef BEALACH_SERVER_ENROLL_PUBKEY_HEX
#define BEALACH_SERVER_ENROLL_PUBKEY_HEX \
    "0000000000000000000000000000000000000000000000000000000000000000"
#endif

/*
 * An all-zero key verifies nothing, so an unconfigured device hands bundles
 * off but never prunes. That is the correct failure direction: a full card loses nothing,
 * while a wrongly authorized prune loses a trip permanently.
 */
#ifndef BEALACH_SERVER_RECEIPT_KEY_HEX
#define BEALACH_SERVER_RECEIPT_KEY_HEX \
    "0000000000000000000000000000000000000000000000000000000000000000"
#endif

/*
 * ── transport credentials ─────────────────────────────────────────────────────
 *
 * BEALACH_WIFI_UPLINK and BEALACH_LTE_UPLINK are both on in the production build, so
 * wifi_link.cpp and lte_link.cpp need these to compile. Real values belong in
 * secrets.h, which is gitignored; the repository is public, so nothing real may
 * appear here.
 *
 * Every default fails closed, in the same direction as the receipt key above: an
 * unconfigured device cannot reach a server and cannot verify one, so a bundle
 * stays on the card. A full card loses nothing; an upload to an unverified peer
 * would.
 *
 *   - An empty CA cannot be parsed, so TLS verification cannot succeed.
 *   - An empty client certificate and key cannot satisfy an mTLS handshake.
 *   - `.invalid` is reserved by RFC 2606 and never resolves.
 *   - Port 0 is not a connectable port.
 *   - No network is named `cairn-unconfigured`.
 *
 * So the defaults are not merely placeholders that compile: each one makes the
 * path it belongs to refuse rather than reach somewhere unintended.
 */
#ifndef BEALACH_WIFI_SSID
#define BEALACH_WIFI_SSID "cairn-unconfigured"
#endif
#ifndef BEALACH_WIFI_PSK
#define BEALACH_WIFI_PSK ""
#endif
#ifndef BEALACH_SERVER_HOST
#define BEALACH_SERVER_HOST "cairn.invalid"
#endif
#ifndef BEALACH_SERVER_PORT
#define BEALACH_SERVER_PORT 0
#endif
#ifndef BEALACH_LTE_SERVER_HOST
#define BEALACH_LTE_SERVER_HOST "cairn.invalid"
#endif
#ifndef BEALACH_LTE_SERVER_PORT
#define BEALACH_LTE_SERVER_PORT 0
#endif
#ifndef BEALACH_SERVER_CA_PEM
#define BEALACH_SERVER_CA_PEM ""
#endif
#ifndef BEALACH_CLIENT_CERT_PEM
#define BEALACH_CLIENT_CERT_PEM ""
#endif
#ifndef BEALACH_CLIENT_KEY_PEM
#define BEALACH_CLIENT_KEY_PEM ""
#endif

#ifndef BEALACH_FIRMWARE_VERSION
#define BEALACH_FIRMWARE_VERSION "cairn-v2.0.0-dev"
#endif

/*
 * OTA is enabled only when an update key is pinned at build time. A device that
 * cannot verify an update has no business installing one, so undefined means
 * off. Images arrive from the app over BLE, never from a network the device
 * joins itself.
 */
#ifdef BEALACH_UPDATE_KEY_HEX
#define BEALACH_OTA_AVAILABLE 1
#else
#define BEALACH_OTA_AVAILABLE 0
#endif

/* ── capture policy ───────────────────────────────────────────────────────── */

/*
 * Bumped whenever any threshold below changes. It is recorded in every
 * STATE_TRANSITION and in the manifest, so a decision in the data can always be
 * explained by the policy that was actually in force — rather than by whatever
 * the thresholds happen to be when the data is read back.
 */
#define BEALACH_POLICY_VERSION 1

/*
 * Event-adaptive sampling (§4.9.1). The nominal cadences below become upper
 * bounds during a trip rather than fixed rates: faster when the vehicle is
 * doing something worth resolving, never slower. Adaptation can only add
 * detail, so a reader's floor of one record per nominal period still holds.
 */
#define BEALACH_ADAPTIVE_SAMPLING 1

/*
 * Nominal sampling cadences, milliseconds.
 *
 * These are not all limited by the same thing, and conflating them wastes
 * effort. Measured on the 2026-10-03 drive:
 *
 *   IMU   — limited only by storage. The accelerometer is read locally over
 *           I2C and summarised, so the cost of a faster window is bytes.
 *   GNSS  — limited by the receiver's own update rate. Polling faster than it
 *           produces fixes yields nothing new; sensors_read_gnss already
 *           refuses to re-report an unchanged timestamp, so an over-fast poll
 *           is merely wasted, never fabricated.
 *   OBD   — limited by the vehicle bus, not by us. Every PID is a separate
 *           request down the co-processor link and back from the ECU, and that
 *           round trip measured 110..140 ms with no observed variance across
 *           4263 requests. That is a hard ceiling of roughly eight PIDs per
 *           second no matter how much card is free, which is why the PID set
 *           below is tiered rather than simply polled harder.
 */
#define BEALACH_GNSS_PERIOD_MS      200
#define BEALACH_IMU_WINDOW_MS       100
/* Device defaults. The active engine profile (engines/, lib/bealach_engine) supplies
 * the OBD cadence, engine-on voltage and the standby and drive-confirmation dwells below;
 * these are what a profile that marks a value `unknown` falls back to, and the host test
 * test/host/engine_test.c asserts the N20 profile equals them. */
#define BEALACH_OBD_PERIOD_MS       1200
#define BEALACH_OBD_BATCH_PERIOD_MS 200

/*
 * A GNSS poll that outruns the receiver is not a gap.
 *
 * The task used to report FACT_GNSS_NO_FIX whenever a read returned nothing,
 * which conflated two unrelated states: the receiver having no fix, and the
 * receiver simply not having produced a new one yet. At a 1000 ms poll against
 * a 1 Hz module, timing jitter alone manufactured gaps — the 2026-10-03 drive
 * recorded 211 of them against 393 samples — and at a 200 ms poll it would
 * invent four per second.
 *
 * So a gap is now reported only once the newest fix is genuinely stale, and no
 * more often than GAP_REPORT_MS while an outage persists.
 */
#define BEALACH_GNSS_STALE_MS       3000
#define BEALACH_GNSS_GAP_REPORT_MS  2000

/*
 * PID validation build. Prints the Mode 01 support bitmaps and, for every PID
 * the firmware reads, the raw ECU reply beside the library's converted value —
 * the only way to check a conversion rather than reason about it. Capture is
 * unaffected, so one drive yields the diagnostic and a usable bundle.
 */
#ifndef BEALACH_PIDTEST
#define BEALACH_PIDTEST 0
#endif
#define BEALACH_PIDTEST_PERIOD_MS 5000

/*
 * Manual-transmission probe. A discovery build, not a capture format: it asks
 * the car for everything that might describe a gearbox and logs the raw answers
 * to the SD log tree, so a drive says what this DME will and will not tell us
 * before anything is built on an assumption. See src/mtprobe.cpp.
 *
 * Capture is unchanged; the probe rides on the bus time the production polling
 * leaves free, and only runs while the controller has the bus open.
 */
#ifndef BEALACH_MTPROBE
#define BEALACH_MTPROBE 0
#endif

/* Gap between probe requests. The production batch already runs every 200 ms,
 * so this is what is added on top of it. */
#define BEALACH_MTPROBE_PERIOD_MS        300

/* Rounds in which every candidate is asked regardless of what the support
 * bitmaps claim, because the bitmaps are the ECU's word and this exists to test
 * that. After this, a PID that never answered is retried only occasionally. */
#define BEALACH_MTPROBE_DISCOVERY_TRIES  2
#define BEALACH_MTPROBE_RETRY_MS         300000

/*
 * Passive CAN sniff windows. Compiled in only when BEALACH_MTPROBE_SNIFF is set,
 * because it takes the OBD link out of request mode for the window and the
 * recovery path has not met this adapter yet. The window stays under the GNSS
 * staleness limit so it cannot manufacture a gap by itself.
 */
#ifndef BEALACH_MTPROBE_SNIFF
#define BEALACH_MTPROBE_SNIFF 0
#endif
#define BEALACH_MTPROBE_SNIFF_FIRST_MS   20000
#define BEALACH_MTPROBE_SNIFF_EVERY_MS   90000
#define BEALACH_MTPROBE_SNIFF_WINDOW_MS  2000
#define BEALACH_MTPROBE_SNIFF_MAX_CHUNKS 80

/*
 * Allow the MTPROBE build to pass engine_gate() for stub engines (engines whose
 * profile has no PID table). The probe runs in a restricted, read-only mode: it
 * sends standard Mode 01 requests and logs responses, but no production OBD data
 * is captured because there are no PIDs to poll. This flag is rejected in non-
 * MTPROBE builds — it exists solely for first-contact discovery on a new engine.
 */
#ifndef BEALACH_MTPROBE_ALLOW_STUB
#define BEALACH_MTPROBE_ALLOW_STUB 0
#endif
#if BEALACH_MTPROBE_ALLOW_STUB && !BEALACH_MTPROBE
#error "BEALACH_MTPROBE_ALLOW_STUB requires BEALACH_MTPROBE"
#endif

#define BEALACH_HEALTH_PERIOD_MS    30000

/*
 * Trip start and stop use separate thresholds with a dwell requirement, so a
 * single noisy sample cannot start or end a trip. Scores are hundredths, to
 * match the STATE_TRANSITION payload's start_score_e2 / stop_score_e2 fields.
 */
#define BEALACH_START_SCORE_THRESHOLD_E2  150  /* 1.50 */
#define BEALACH_STOP_SCORE_THRESHOLD_E2   40   /* 0.40 */
#define BEALACH_START_DWELL_MS            3000
#define BEALACH_STOP_DWELL_MS             120000 /* 2 min of stillness ends a trip */

/* Motion evidence thresholds. */
#define BEALACH_MOTION_ACCEL_RMS_MG   120
#define BEALACH_MOTION_SPEED_CMPS     280  /* ~10 km/h */

/*
 * Pre-trip ring: samples captured before a trip is declared are kept and
 * written with BEALACH_FLAG_PRETRIP, so the beginning of a drive is not lost to
 * the dwell requirement. The flag matters — these samples are real data, but
 * they were recorded before the device had decided a trip was underway.
 *
 * Sized for 45 s of pre-roll. The ring holds every record type the capture
 * chain carries, so the budget is the sum of their rates rather than GNSS
 * alone: GNSS at 1 Hz, IMU summaries at 1 Hz and OBD at 0.5 Hz comes to 2.5
 * records per second, so 45 s needs about 113 slots. 128 gives headroom for a
 * faster cadence without re-deriving this.
 *
 * At 40 bytes per entry that is ~5 KB of RAM held permanently. Worth it: the
 * first seconds of a drive are the hardest part to reconstruct afterwards, and
 * 5 KB of a 320 KB budget is cheap insurance.
 */
#define BEALACH_PREROLL_WINDOW_MS     45000
#define BEALACH_PREROLL_RING_SAMPLES  128

/* ── power management ─────────────────────────────────────────────────────── */

/*
 * How long the vehicle must be at rest before the device stands by. Longer than
 * the trip-stop dwell on purpose: sealing a trip and immediately sleeping would
 * miss a driver who stopped to post a letter.
 */
#define BEALACH_STANDBY_IDLE_MS 300000  /* 5 minutes */

/*
 * Voltage that means the engine is running, from the v1 firmware's measured
 * value. A resting battery sits near 12.4 V and an alternator pushes well above
 * 13 V, so this is a wide margin rather than a fine one.
 */
#define BEALACH_ENGINE_ON_MV 13200

/*
 * Dwell required before local evidence is accepted as a started drive.
 *
 * Both signals are bus-silent, which is the point: they let the device decide a
 * drive has begun without transmitting anything the vehicle network can see.
 * See the parked-silence invariant in bealach_power.h.
 *
 * The dwells reject the things that look momentarily like a drive — a door
 * slam, a tow nudge, someone leaning on the car, a central-locking actuator
 * twitching the supply rail. Either signal on its own has to persist; both
 * together are accepted promptly, since a lifted rail and sustained movement at
 * the same time is not something a parked car does.
 */
#define BEALACH_DRIVE_VOLTAGE_DWELL_MS 15000
#define BEALACH_DRIVE_MOTION_DWELL_MS  10000
#define BEALACH_DRIVE_BOTH_DWELL_MS    2000

/*
 * How often the controller samples the supply rail while awake.
 *
 * Not taken from DEVICE_HEALTH, which arrives every 30 s — too coarse to open
 * the bus promptly after an engine start, which would leave the first half
 * minute of OBD missing from every trip. Two seconds costs co-processor link
 * traffic, internal to the dongle, and nothing on the vehicle bus.
 */
#define BEALACH_BATTERY_POLL_MS 2000

/* Poll interval while standing by. The core light-sleeps in between. */
#define BEALACH_STANDBY_POLL_MS 1000

/*
 * A standby this long emits a health record anyway, so a parked device stays
 * distinguishable from a dead one.
 */
#define BEALACH_STANDBY_HEARTBEAT_MS 21600000  /* 6 hours */

/*
 * How long to stay awake after a heartbeat wake before standing by again.
 *
 * The co-processor needs roughly fifteen seconds after leaving low-power mode
 * before it will report a supply voltage — measured from the card, where the
 * health record written straight after a resume says "battery unknown". Since
 * recording that voltage is the heartbeat's only purpose, it has to wait for it.
 */
#define BEALACH_HEARTBEAT_SETTLE_MS 20000

/* Clock to drop to while standing by. 80 MHz is the lowest frequency that
 * keeps the Wi-Fi and I2C peripherals usable without re-initialisation. */
#define BEALACH_STANDBY_CPU_MHZ 80

/* ── task stacks ──────────────────────────────────────────────────────────── */

/*
 * The Arduino loop task runs the transition controller, and therefore runs the
 * seal: Merkle tree over up to BEALACH_MAX_MEMBERS members, a deterministic CBOR
 * manifest, and an Ed25519 signature. The deepest locals on that path are
 * bealach_member_t sorted[16] and signing[512] in cf_manifest.c, on top of
 * TweetNaCl's nested gf and i64[64] working arrays.
 *
 * Arduino's default is 8192, and that is not enough: the first seal attempted on
 * real hardware tripped the stack canary in loopTask and panicked, which on a
 * firmware that resumes its capture at boot turns into a reboot loop that
 * re-appends frames every cycle. Measured headroom is logged at the end of the
 * seal (see log_stack_headroom), so this number can be checked rather than
 * trusted.
 */
#define BEALACH_LOOP_STACK_BYTES 16384

/* Warn below this much free stack. Roughly a quarter of the total: enough slack
 * that the warning arrives before the canary does. */
#define BEALACH_STACK_WARN_BYTES 4096

/* ── BLE companion ───────────────────────────────────────────────────────── */

#ifndef BEALACH_BLE_COMPANION
#define BEALACH_BLE_COMPANION 0
#endif
#define BEALACH_BLE_NAME "Cairn"
#ifndef BEALACH_PHONE_GNSS_STALE_MS
#define BEALACH_PHONE_GNSS_STALE_MS 3000
#endif

/* ── hand-off policy ──────────────────────────────────────────────────────── */

/*
 * Recount sealed-but-unreceipted bundles only while stopped. It is cheap, but
 * the card is shared with capture and nothing about this is time-critical.
 */
#define BEALACH_PENDING_MIN_IDLE_MS 10000

/*
 * Its own timer, not idle_since_ms. Sharing that one would let every recount
 * reset the standby dwell and the device would never sleep.
 */
#define BEALACH_PENDING_REFRESH_MS 60000

/* ── uplink schedule ──────────────────────────────────────────────────────── */

/*
 * How long a Wi-Fi slot may last.
 *
 * Measured rather than guessed, which the uplink module's own notes asked for
 * (issue #19). Cellular moves about 3 KB/s on this hardware and Wi-Fi rather
 * more, so a typical ~230 KB bundle needs on the order of 80 seconds over the
 * slower path. A slot shorter than that would abort every bundle it started
 * and make progress only through resume, which is wasteful when the device is
 * parked anyway. Four minutes leaves room for a handful.
 */
#define BEALACH_UPLINK_SLOT_MAX_MS 240000u

/*
 * How often a source that has the time repeats its observation.
 *
 * Two minutes: often enough that a trip carries a series rather than a single
 * point -- which is what makes drift visible and lets a consumer compare sources
 * -- and rare enough that it costs 16 bytes per source per two minutes against a
 * bundle measured in megabytes. The first observation from each source is always
 * posted immediately, because on a cold start that is the moment the trip becomes
 * datable at all.
 */
#define BEALACH_TIME_OBS_PERIOD_MS 120000u

/*
 * The earliest wall clock any source is allowed to claim: 2020-01-01T00:00:00Z.
 *
 * Checked once, where an observation is turned into the bundle's time basis,
 * rather than three times in three source drivers that can drift apart. Every
 * clock on this device can lie in a way that parses:
 *
 *   - the SIM7600 answers AT+CCLK? with its build default in 1980 before the
 *     network has told it anything
 *   - a GNSS receiver can report a date before it has a fix, and the two-digit
 *     year means yy=00 reads as a perfectly valid 2000-01-01
 *   - a phone with no clock, or a malformed 8-byte write, is whatever those
 *     bytes happen to say
 *
 * A plausible wrong date is worse than an admitted absence, because it becomes
 * the basis every sample in the bundle is timed against and nothing downstream
 * can tell. DEGRADED_TIME and a 1970 date are at least honest.
 */
#define BEALACH_TIME_PLAUSIBLE_FLOOR_MS 1577836800000ULL

/* Associating is bounded separately: a network that is not there should cost
 * seconds, not the whole slot. */
#define BEALACH_UPLINK_ASSOCIATE_MS 25000u

/*
 * An LTE send is given longer than a Wi-Fi slot because the link is slower and
 * the attach alone can take 20 s from cold.
 *
 * Sized on measurement, not estimate. The 2026-10-07 test drive sealed a
 * 1,295,714-byte bundle and it took 386 s to deliver over cellular — 3.35 KB/s,
 * 0.23% protocol overhead. The previous 300 s limit was therefore below the cost
 * of one real bundle: the slot aborted mid-transfer every time, and progress came
 * only through resume, which pays the attach again for nothing.
 *
 * 15 minutes covers the attach plus roughly 2.5 MB, so a bundle from an ordinary
 * drive finishes inside one slot. Anything larger still completes across slots —
 * the abort is checked between chunks, so it is always resume-safe — but that is
 * now the exception rather than every single transfer.
 */
#define BEALACH_UPLINK_LTE_LIMIT_MS 900000u

/* Bundles attempted per slot. Bounded so one enormous backlog cannot hold the
 * radio for an unbounded time; the rest wait for the next parked session. */
#define BEALACH_UPLINK_BUNDLES_PER_SLOT 4u

/*
 * How long after a trip ends before cellular is considered.
 *
 * The point of waiting is that the phone usually appears first — it is free,
 * and BLE is already up — so paying for cellular immediately would spend the
 * owner's data on bundles that were about to leave for nothing.
 */
#define BEALACH_UPLINK_LTE_AFTER_TRIP_MS 600000u

/*
 * Supply floor for radio work, in millivolts.
 *
 * A resting car battery sits near 12.4 V. This is below that and well above
 * the point where starting becomes doubtful: the device must never be the
 * reason a car will not start, but it also must not refuse to upload on a
 * perfectly healthy battery.
 */
#define BEALACH_UPLINK_BATTERY_FLOOR_MV 11800u

/*
 * Accelerometer RMS, in milli-g, that aborts a transfer in progress.
 *
 * Above the noise floor measured on this unit (under 2 mg RMS at rest, per
 * docs/flashing-and-testing.md) by a wide margin, so a passing lorry does not
 * cancel an upload, while a car actually being driven away does.
 */
#define BEALACH_UPLINK_ABORT_RMS_MG 60u

#endif /* BEALACH_CONFIG_H */
