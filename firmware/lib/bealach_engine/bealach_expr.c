/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_engine/bealach_expr.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "bealach_expr.h"

static int fits32(int64_t v)
{
    return v >= (int64_t)INT32_MIN && v <= (int64_t)INT32_MAX;
}

const char *bealach_expr_status_name(bealach_expr_status_t s)
{
    switch (s) {
    case BEALACH_EXPR_OK:           return "OK";
    case BEALACH_EXPR_ERR_TRUNC:    return "ERR_TRUNC";
    case BEALACH_EXPR_ERR_BAD_OP:   return "ERR_BAD_OP";
    case BEALACH_EXPR_ERR_STACK:    return "ERR_STACK";
    case BEALACH_EXPR_ERR_DIV_ZERO: return "ERR_DIV_ZERO";
    case BEALACH_EXPR_ERR_OVERFLOW: return "ERR_OVERFLOW";
    case BEALACH_EXPR_ERR_SHIFT:    return "ERR_SHIFT";
    case BEALACH_EXPR_ERR_RESULT:   return "ERR_RESULT";
    case BEALACH_EXPR_ERR_ARG:      return "ERR_ARG";
    default:                      return "ERR_?";
    }
}

bealach_expr_status_t bealach_expr_eval(const uint8_t *code, size_t len,
                                    const uint8_t in[4], int32_t *out)
{
    int64_t st[BEALACH_EXPR_MAX_STACK];
    size_t  sp = 0;
    size_t  pc = 0;

    if (in == NULL || out == NULL || (code == NULL && len != 0)) {
        return BEALACH_EXPR_ERR_ARG;
    }

#define PUSH(v)                                                               \
    do {                                                                      \
        if (sp >= BEALACH_EXPR_MAX_STACK) return BEALACH_EXPR_ERR_STACK;          \
        st[sp++] = (v);                                                       \
    } while (0)
#define NEED(n)                                                               \
    do {                                                                      \
        if (sp < (n)) return BEALACH_EXPR_ERR_STACK;                            \
    } while (0)
#define CHECKED(v)                                                            \
    do {                                                                      \
        int64_t r_ = (v);                                                     \
        if (!fits32(r_)) return BEALACH_EXPR_ERR_OVERFLOW;                      \
        st[sp++] = r_;                                                        \
    } while (0)

    while (pc < len) {
        uint8_t op = code[pc++];

        switch (op) {
        case BEALACH_OP_PUSH_U8:
            if (pc + 1 > len) return BEALACH_EXPR_ERR_TRUNC;
            PUSH((int64_t)code[pc]);
            pc += 1;
            break;
        case BEALACH_OP_PUSH_S8:
            if (pc + 1 > len) return BEALACH_EXPR_ERR_TRUNC;
            PUSH((int64_t)(int8_t)code[pc]);
            pc += 1;
            break;
        case BEALACH_OP_PUSH_U16:
            if (pc + 2 > len) return BEALACH_EXPR_ERR_TRUNC;
            PUSH((int64_t)((uint32_t)code[pc] | ((uint32_t)code[pc + 1] << 8)));
            pc += 2;
            break;
        case BEALACH_OP_PUSH_I32: {
            uint32_t u;
            if (pc + 4 > len) return BEALACH_EXPR_ERR_TRUNC;
            u = (uint32_t)code[pc] | ((uint32_t)code[pc + 1] << 8) |
                ((uint32_t)code[pc + 2] << 16) | ((uint32_t)code[pc + 3] << 24);
            /* Via uint32 so the conversion is defined for every bit pattern. */
            PUSH((int64_t)(u >= 0x80000000u ? (int64_t)u - 0x100000000LL : (int64_t)u));
            pc += 4;
            break;
        }
        case 0x10: case 0x11: case 0x12: case 0x13:
            PUSH((int64_t)in[op - BEALACH_OP_LOAD_A]);
            break;
        case BEALACH_OP_NEG: {
            int64_t a;
            NEED(1);
            a = st[--sp];
            CHECKED(-a);
            break;
        }
        case BEALACH_OP_CLAMP: {
            int64_t x, lo, hi;
            NEED(3);
            hi = st[--sp];
            lo = st[--sp];
            x  = st[--sp];
            if (x < lo) x = lo;
            if (x > hi) x = hi;
            st[sp++] = x;
            break;
        }
        case BEALACH_OP_ADD: case BEALACH_OP_SUB: case BEALACH_OP_MUL:
        case BEALACH_OP_DIV: case BEALACH_OP_MOD: case BEALACH_OP_AND:
        case BEALACH_OP_OR:  case BEALACH_OP_SHL: case BEALACH_OP_SHR:
        case BEALACH_OP_MIN: case BEALACH_OP_MAX: {
            int64_t a, b;
            NEED(2);
            b = st[--sp];
            a = st[--sp];
            switch (op) {
            case BEALACH_OP_ADD: CHECKED(a + b); break;
            case BEALACH_OP_SUB: CHECKED(a - b); break;
            case BEALACH_OP_MUL: CHECKED(a * b); break; /* int32 x int32 fits int64 */
            case BEALACH_OP_DIV:
                if (b == 0) return BEALACH_EXPR_ERR_DIV_ZERO;
                CHECKED(a / b);
                break;
            case BEALACH_OP_MOD:
                if (b == 0) return BEALACH_EXPR_ERR_DIV_ZERO;
                CHECKED(a % b);
                break;
            case BEALACH_OP_AND: CHECKED(a & b); break;
            case BEALACH_OP_OR:  CHECKED(a | b); break;
            case BEALACH_OP_SHL:
                if (b < 0 || b > 31) return BEALACH_EXPR_ERR_SHIFT;
                /* A multiplication, not <<, which is undefined on negative values. */
                CHECKED(a * ((int64_t)1 << (int)b));
                break;
            case BEALACH_OP_SHR:
                if (b < 0 || b > 31) return BEALACH_EXPR_ERR_SHIFT;
                /* Floor division by 2^b, spelled so it does not rely on how the
                 * compiler defines >> for negative values. */
                CHECKED(a >= 0 ? (a >> (int)b) : ~((~a) >> (int)b));
                break;
            case BEALACH_OP_MIN: CHECKED(a < b ? a : b); break;
            default:           CHECKED(a > b ? a : b); break; /* BEALACH_OP_MAX */
            }
            break;
        }
        default:
            return BEALACH_EXPR_ERR_BAD_OP;
        }
    }

#undef PUSH
#undef NEED
#undef CHECKED

    if (sp != 1) return BEALACH_EXPR_ERR_RESULT;
    *out = (int32_t)st[0];
    return BEALACH_EXPR_OK;
}
