/*
 * matmul_stubs.c
 *
 * Stub implementations of SIMD matrix multiplication functions.
 * These are normally compiled from matmul.cpp for server builds, but clients
 * don't need the actual implementations (they only do PIR queries, not server-side
 * matrix operations). These stubs exist only to satisfy the linker.
 */

#include <stdint.h>
#include <stddef.h>

void matMulVecPacked(uint32_t *out, const uint32_t *a, const uint32_t *b,
    size_t aRows, size_t aCols) {
    // Stub - not used on iOS client
    (void)out; (void)a; (void)b; (void)aRows; (void)aCols;
}

void matMulVecPacked2(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols) {
    // Stub - not used on iOS client
    (void)out; (void)a; (void)b_full; (void)aRows; (void)aCols;
}

void matMulVecPacked4(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols) {
    // Stub - not used on iOS client
    (void)out; (void)a; (void)b_full; (void)aRows; (void)aCols;
}

void matMulVecPacked8(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols) {
    // Stub - not used on iOS client
    (void)out; (void)a; (void)b_full; (void)aRows; (void)aCols;
}
