/*
 * PIRMatmulStubs.h
 *
 * Stub declarations for SIMD matrix multiplication functions.
 * These stubs satisfy linker requirements for iOS client builds.
 */

#ifndef PIRMatmulStubs_h
#define PIRMatmulStubs_h

#include <stdint.h>
#include <stddef.h>

void matMulVecPacked(uint32_t *out, const uint32_t *a, const uint32_t *b,
    size_t aRows, size_t aCols);

void matMulVecPacked2(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols);

void matMulVecPacked4(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols);

void matMulVecPacked8(uint32_t *out, const uint32_t *a, const uint32_t *b_full,
    size_t aRows, size_t aCols);

#endif /* PIRMatmulStubs_h */
