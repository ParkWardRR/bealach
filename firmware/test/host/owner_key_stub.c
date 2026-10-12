/* Minimal owner-key functions for prov_test. Full implementation lives in
 * bealach_store.c (tested in faults.c); this just provides the KV-only
 * subset the prov console protocol calls. */

#include "bealach_store.h"
#include "bealach_kv.h"
#include <string.h>

#define KV_OWNER_ENROLL "owner_enroll"
#define KV_OWNER_ACK    "owner_ack"

static bool all_zero_stub(const uint8_t *b, size_t n)
{
    for (size_t i = 0; i < n; i++) if (b[i] != 0) return false;
    return true;
}

bool bealach_owner_key_set(const uint8_t enroll_pub[32], const uint8_t ack_pub[32])
{
    if (!bealach_kv_begin()) return false;
    return bealach_kv_set_blob(KV_OWNER_ENROLL, enroll_pub, 32) &&
           bealach_kv_set_blob(KV_OWNER_ACK, ack_pub, 32);
}

bool bealach_owner_key_get_enroll(uint8_t out[32])
{
    if (!bealach_kv_begin()) return false;
    return bealach_kv_get_blob(KV_OWNER_ENROLL, out, 32);
}

bool bealach_owner_key_get_ack(uint8_t out[32])
{
    if (!bealach_kv_begin()) return false;
    return bealach_kv_get_blob(KV_OWNER_ACK, out, 32);
}

bool bealach_owner_key_clear(void)
{
    if (!bealach_kv_begin()) return false;
    bealach_kv_erase(KV_OWNER_ENROLL);
    bealach_kv_erase(KV_OWNER_ACK);
    return true;
}

bool bealach_owner_enrolled(void)
{
    uint8_t key[32];
    if (!bealach_owner_key_get_ack(key)) return false;
    return !all_zero_stub(key, 32);
}
