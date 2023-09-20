#ifndef HASH_H
#define HASH_H
/*
    Use the C functions if you want to prevent heap allocations entirely
    In the C++ interface the returned string is allocated in C it's either the
    internal stack buffer or a provided one

    C interface:
    all functions start with hash_ and structs with Hash_ private classes start with Hash_Private_
    hash_private_ functions are for the implementation and should not be called
    either use the provided functions, all have the same scheme:

        hash_sha256("Hello world", buffer); // returns a const char* (internal buffer if buffer == NULL)
        hash_sha256_file("main.c", "rb", buffer);

        hash_sha256_easy("Hello world"); // returns internal buffer
        hash_sha256_file_easy("main.c", "rb");

        hash_sha256_binary("Hello world", 11, buffer); // the binary function take the size of the string e.g. for binary files

    or if you need to update the hash e.g. while reading chunks from a file (not supported for SHA3, Shake128 and Shake256

        Hash_Sha256 s;
        hash_sha256_init(s);
        hash_sha256_update_binary(s, str, size);
        hash_sha256_finalize(s);
        const char* hash = hash_sha256_hexdigest(s, buffer);

    C++ interface:
    all functions and classes are in the namespace Hash
    either use the provided functions, all have the same scheme:

        Hash::sha256("Hello world"); // returns std::string
        Hash::File::sha256("main.c", std::ios::binary);

    or if you need to update the hash e.g. while reading chunks from a file (not supported for SHA3, Shake128 and Shake256)
        Hash::Sha256 s;
        s.Update("Hello world");
        s.Finalize();
        std::string hash = s.Hexdigest();
*/
#define HASH_ENABLE_MD5    1 // md5
#define HASH_ENABLE_SHA1   1 // sha1
#define HASH_ENABLE_SHA2   1 // sha224, sha256, sha384, sha512, sha512/t
#define HASH_ENABLE_KECCAK 1 // sha3-224, sha3-256, sha3-384, sha3-512, shake128 and shake256
#define HASH_ENABLE_C_FUNCTIONS 1
#define HASH_KECCAK_LITTLE_ENDIAN 1 // true for most systems (windows, linux, macos)
#define HASH_SHAKE_128_MALLOC_LIMIT 64 // if outsizeBytes is greater and no buffer is provided we will heap allocate
#define HASH_SHAKE_256_MALLOC_LIMIT 64 // if outsizeBytes is greater and no buffer is provided we will heap allocate

#ifdef _MSC_VER
#pragma warning( push )
#pragma warning( disable : 4996) // sprintf is deprecated
#endif

#ifdef __cplusplus
#include <string>
#include <locale>
#include <cstdio>
#include <limits>
#include <climits>
#include <cstdint>
#include <cstring>
#include <cassert>
#include <codecvt>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <cinttypes>
#include <type_traits>
#include <string_view>
#define HASH_INLINE inline
#else
#include <stdio.h>
#include <stdint.h>
#include <limits.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>
#define HASH_INLINE static
#endif // __cplusplus

#if HASH_ENABLE_C_FUNCTIONS == 1
// ================================Util====================================
HASH_INLINE void hash_util_char_array_to_hex_string(unsigned char* data, size_t size, char* out)
{
    static const char hex_chars[16] = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
    size_t k = 0;
    for (size_t i = 0; i < size; ++i)
    {
        char const byte = data[i];
        out[k++] = hex_chars[(byte & 0xF0) >> 4];
        out[k++] = hex_chars[(byte & 0x0F) >> 0];
    }
    out[k] = 0;
}

HASH_INLINE char* hash_util_load_file(const char* path, const char* mode, long* fsize)
{
    FILE* f = fopen(path, mode);
    if (f == NULL) return NULL;

    fseek(f, 0, SEEK_END);
    *fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    char* string = (char*)malloc((size_t)*fsize);
    if (string == NULL) return NULL;
    fread(string, *fsize, 1, f);
    fclose(f);
    return string;
}

HASH_INLINE const char* hash_util_hash_file(const char* path, const char* mode, const char* (*hashfunc)(const char*, size_t, char*), char* buffer)
{
    long fsize;
    char* content = hash_util_load_file(path, mode, &fsize);
    if (content == NULL) return "";
    const char* hash = hashfunc(content, fsize, buffer);
    if (content != NULL)
        free(content);
    return hash;
}

#define HASH_DEFINE_UTIL_SWAP_ENDIAN(type) \
    HASH_INLINE type hash_util_swap_endian_##type(type u) \
    { \
        assert(CHAR_BIT == 8 && "CHAR_BIT != 8"); \
 \
        union \
        { \
            type u; \
            unsigned char u8[sizeof(type)]; \
        } source, dest; \
        source.u = u; \
 \
        for (size_t k = 0; k < sizeof(type); k++) \
            dest.u8[k] = source.u8[sizeof(type) - k - 1]; \
 \
        return dest.u; \
    }
HASH_DEFINE_UTIL_SWAP_ENDIAN(uint32_t)
HASH_DEFINE_UTIL_SWAP_ENDIAN(uint64_t)


HASH_INLINE int hash_util_is_little_endian()
{
    int32_t num = 1;
    return *(char*)&num == 1;
}

HASH_INLINE uint32_t hash_util_right_rotate_u32(uint32_t n, unsigned int c)
{
    return (n >> c) | (n << (32 - c));
}

HASH_INLINE uint64_t hash_util_right_rotate_u64(uint64_t n, unsigned int c)
{
    return (n >> c) | (n << (64 - c));
}

HASH_INLINE uint32_t hash_util_left_rotate_u32(uint32_t n, unsigned int c)
{
    return (n << c) | (n >> (32 - c));
}
// ================================Util====================================


#if HASH_ENABLE_SHA2 == 1
// ===============================Hash_Sha256===================================
typedef struct
{
    uint64_t bitlen;
    uint8_t bufferSize;
    uint32_t h[8];
    uint8_t buffer[64];
} Hash_Private_Sha256;
typedef Hash_Private_Sha256 Hash_Sha256[1];


HASH_INLINE void hash_private_sha256_compress(Hash_Sha256 s, const uint32_t* const w)
{
    static const uint32_t k[64] =
    {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    };

    uint32_t a = s->h[0];
    uint32_t b = s->h[1];
    uint32_t c = s->h[2];
    uint32_t d = s->h[3];
    uint32_t e = s->h[4];
    uint32_t f = s->h[5];
    uint32_t g = s->h[6];
    uint32_t h = s->h[7];
    for (size_t i = 0; i < 64; ++i)
    {
        const uint32_t s1 = hash_util_right_rotate_u32(e, 6) ^ hash_util_right_rotate_u32(e, 11) ^ hash_util_right_rotate_u32(e, 25);
        const uint32_t ch = (e & f) ^ (~e & g);
        const uint32_t temp1 = h + s1 + ch + k[i] + w[i];
        const uint32_t s0 = hash_util_right_rotate_u32(a, 2) ^ hash_util_right_rotate_u32(a, 13) ^ hash_util_right_rotate_u32(a, 22);
        const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t temp2 = s0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    s->h[0] += a;
    s->h[1] += b;
    s->h[2] += c;
    s->h[3] += d;
    s->h[4] += e;
    s->h[5] += f;
    s->h[6] += g;
    s->h[7] += h;
}


HASH_INLINE void hash_private_sha256_transform(Hash_Sha256 s)
{
    static uint32_t w[64];
    for (size_t i = 0; i < 16; ++i)
    {
        uint8_t* c = (uint8_t*)&w[i];
        c[0] = s->buffer[4 * i];
        c[1] = s->buffer[4 * i + 1];
        c[2] = s->buffer[4 * i + 2];
        c[3] = s->buffer[4 * i + 3];
        w[i] = hash_util_is_little_endian() ? hash_util_swap_endian_uint32_t(w[i]) : w[i];
    }

    for (size_t i = 16; i < 64; ++i)
    {
        const uint32_t s0 = hash_util_right_rotate_u32(w[i - 15], 7) ^ hash_util_right_rotate_u32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const uint32_t s1 = hash_util_right_rotate_u32(w[i - 2], 17) ^ hash_util_right_rotate_u32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    hash_private_sha256_compress(s, w);
}




HASH_INLINE void hash_sha256_init(Hash_Sha256 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0x6a09e667;
    s->h[1] = 0xbb67ae85;
    s->h[2] = 0x3c6ef372;
    s->h[3] = 0xa54ff53a;
    s->h[4] = 0x510e527f;
    s->h[5] = 0x9b05688c;
    s->h[6] = 0x1f83d9ab;
    s->h[7] = 0x5be0cd19;
};


HASH_INLINE void hash_sha256_update_binary(Hash_Sha256 s, const char* data, size_t size)
{
    const uint8_t* d = (const uint8_t*)data;
    for (size_t i = 0; i < size; ++i)
    {
        s->buffer[s->bufferSize++] = d[i];
        if (s->bufferSize == 64)
        {
            hash_private_sha256_transform(s);
            s->bufferSize = 0;
            s->bitlen += 512;
        }
    }
}

HASH_INLINE void hash_sha256_update(Hash_Sha256 s, const char* data)
{
    hash_sha256_update_binary(s, data, strlen(data));
}

HASH_INLINE void hash_sha256_finalize(Hash_Sha256 s)
{
    uint8_t start = s->bufferSize;
    uint8_t end = s->bufferSize < 56 ? 56 : 64;

    s->buffer[start++] = 0b10000000;
    memset(&s->buffer[start], 0, end - start);

    if (s->bufferSize >= 56)
    {
        hash_private_sha256_transform(s);
        memset(s->buffer, 0, 56);
    }

    s->bitlen += s->bufferSize * 8;
    uint64_t* const size = (uint64_t*)&s->buffer[64 - 8];
    *size = hash_util_is_little_endian() ? hash_util_swap_endian_uint64_t(s->bitlen) : s->bitlen;
    hash_private_sha256_transform(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least 65 (Null term char)
HASH_INLINE const char* hash_sha256_hexdigest(const Hash_Sha256 s, char* buffer)
{
    static char hex[65];
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 8; ++i)
    {
        sprintf(&buff[i * 8], "%08" PRIx32, s->h[i]);
    }
    buff[64] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least 65 (Null term char)
HASH_INLINE const char* hash_sha256_binary(const char* str, size_t size, char* buffer)
{
    Hash_Sha256 s;
    hash_sha256_init(s);
    hash_sha256_update_binary(s, str, size);
    hash_sha256_finalize(s);
    return hash_sha256_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha256(const char* str, char* buffer)
{
    return hash_sha256_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha256_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_sha256_binary, buffer);
}

HASH_INLINE const char* hash_sha256_easy(const char* str)
{
    return hash_sha256_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha256_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_sha256_binary, NULL);
}
// ===============================Hash_Sha256===================================


// ===============================Hash_Sha224===================================
typedef Hash_Sha256 Hash_Sha224;

HASH_INLINE void hash_sha224_init(Hash_Sha224 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0xC1059ED8;
    s->h[1] = 0x367CD507;
    s->h[2] = 0x3070DD17;
    s->h[3] = 0xF70E5939;
    s->h[4] = 0xFFC00B31;
    s->h[5] = 0x68581511;
    s->h[6] = 0x64F98FA7;
    s->h[7] = 0xBEFA4FA4;
};


HASH_INLINE void hash_sha224_update_binary(Hash_Sha224 s, const char* data, size_t size)
{
    hash_sha256_update_binary(s, data, size);
}

HASH_INLINE void hash_sha224_update(Hash_Sha224 s, const char* data)
{
    hash_sha224_update_binary(s, data, strlen(data));
}

HASH_INLINE void hash_sha224_finalize(Hash_Sha224 s)
{
    hash_sha256_finalize(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least 57 (Null term char)
HASH_INLINE const char* hash_sha224_hexdigest(const Hash_Sha224 s, char* buffer)
{
    static char hex[57];
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 7; ++i)
    {
        sprintf(&buff[i * 8], "%08" PRIx32, s->h[i]);
    }
    buff[56] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least 65 (Null term char)
HASH_INLINE const char* hash_sha224_binary(const char* str, size_t size, char* buffer)
{
    Hash_Sha224 s;
    hash_sha224_init(s);
    hash_sha224_update_binary(s, str, size);
    hash_sha224_finalize(s);
    return hash_sha224_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha224(const char* str, char* buffer)
{
    return hash_sha224_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha224_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_sha224_binary, buffer);
}

HASH_INLINE const char* hash_sha224_easy(const char* str)
{
    return hash_sha224_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha224_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_sha224_binary, NULL);
}
// ===============================Hash_Sha224===================================


// ===============================Hash_Sha512===================================
typedef struct
{
    uint64_t bitlen;
    uint8_t bufferSize;
    uint64_t h[8];
    uint8_t buffer[128];
    size_t t; // only use for sha512t
} Hash_Private_Sha512;
typedef Hash_Private_Sha512 Hash_Sha512[1];


HASH_INLINE void hash_private_sha512_compress(Hash_Sha512 s, const uint64_t* const w)
{
    static const uint64_t k[80] =
    {
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
        0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
        0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
        0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
        0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
        0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
        0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
        0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
        0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817
    };

    uint64_t a = s->h[0];
    uint64_t b = s->h[1];
    uint64_t c = s->h[2];
    uint64_t d = s->h[3];
    uint64_t e = s->h[4];
    uint64_t f = s->h[5];
    uint64_t g = s->h[6];
    uint64_t h = s->h[7];
    for (size_t i = 0; i < 80; ++i)
    {
        const uint64_t s1 = hash_util_right_rotate_u64(e, 14) ^ hash_util_right_rotate_u64(e, 18) ^ hash_util_right_rotate_u64(e, 41);
        const uint64_t ch = (e & f) ^ (~e & g);
        const uint64_t temp1 = h + s1 + ch + k[i] + w[i];
        const uint64_t s0 = hash_util_right_rotate_u64(a, 28) ^ hash_util_right_rotate_u64(a, 34) ^ hash_util_right_rotate_u64(a, 39);
        const uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
        const uint64_t temp2 = s0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    s->h[0] += a;
    s->h[1] += b;
    s->h[2] += c;
    s->h[3] += d;
    s->h[4] += e;
    s->h[5] += f;
    s->h[6] += g;
    s->h[7] += h;
}


HASH_INLINE void hash_private_sha512_transform(Hash_Sha512 s)
{
    static uint64_t w[80];
    for (size_t i = 0; i < 16; ++i)
    {
        uint8_t* c = (uint8_t*)&w[i];
        c[0] = s->buffer[8 * i];
        c[1] = s->buffer[8 * i + 1];
        c[2] = s->buffer[8 * i + 2];
        c[3] = s->buffer[8 * i + 3];
        c[4] = s->buffer[8 * i + 4];
        c[5] = s->buffer[8 * i + 5];
        c[6] = s->buffer[8 * i + 6];
        c[7] = s->buffer[8 * i + 7];
        w[i] = hash_util_is_little_endian() ? hash_util_swap_endian_uint64_t(w[i]) : w[i];
    }

    for (size_t i = 16; i < 80; ++i) // Extend the first 16 words
    {
        const uint64_t s0 = hash_util_right_rotate_u64(w[i - 15], 1) ^ hash_util_right_rotate_u64(w[i - 15], 8) ^ (w[i - 15] >> 7);
        const uint64_t s1 = hash_util_right_rotate_u64(w[i - 2], 19) ^ hash_util_right_rotate_u64(w[i - 2], 61) ^ (w[i - 2] >> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    hash_private_sha512_compress(s, w);
}




HASH_INLINE void hash_sha512_init(Hash_Sha512 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0x6a09e667f3bcc908;
    s->h[1] = 0xbb67ae8584caa73b;
    s->h[2] = 0x3c6ef372fe94f82b;
    s->h[3] = 0xa54ff53a5f1d36f1;
    s->h[4] = 0x510e527fade682d1;
    s->h[5] = 0x9b05688c2b3e6c1f;
    s->h[6] = 0x1f83d9abfb41bd6b;
    s->h[7] = 0x5be0cd19137e2179;
};

HASH_INLINE void hash_sha512_reset(Hash_Sha512 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
}

HASH_INLINE void hash_sha512_update_binary(Hash_Sha512 s, const char* data, size_t size)
{
    const uint8_t* d = (const uint8_t*)data;
    for (size_t i = 0; i < size; ++i)
    {
        s->buffer[s->bufferSize++] = d[i];
        if (s->bufferSize == 128)
        {
            hash_private_sha512_transform(s);
            s->bufferSize = 0;
            s->bitlen += 1024;
        }
    }
}

HASH_INLINE void hash_sha512_update(Hash_Sha512 s, const char* data)
{
    hash_sha512_update_binary(s, data, strlen(data));
}

HASH_INLINE void hash_sha512_finalize(Hash_Sha512 s)
{
    uint8_t start = s->bufferSize;
    uint8_t end = s->bufferSize < 112 ? 120 : 128; // 120 instead of 112 because m_Bitlen is a 64 bit uint

    s->buffer[start++] = 0b10000000;
    memset(&s->buffer[start], 0, end - start);

    if (s->bufferSize >= 112)
    {
        hash_private_sha512_transform(s);
        memset(s->buffer, 0, 120);
    }

    s->bitlen += s->bufferSize * 8;
    uint64_t* const size = (uint64_t*)&s->buffer[128 - 8]; // -8 instead of -16 because we use an uint64 instead of uint128
    *size = hash_util_is_little_endian() ? hash_util_swap_endian_uint64_t(s->bitlen) : s->bitlen;
    hash_private_sha512_transform(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least 129 (Null term char)
HASH_INLINE const char* hash_sha512_hexdigest(const Hash_Sha512 s, char* buffer)
{
    static char hex[129];
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 8; ++i)
    {
        sprintf(&buff[i * 16], "%016" PRIx64, s->h[i]);
    }
    buff[128] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least 129 (Null term char)
HASH_INLINE const char* hash_sha512_binary(const char* str, size_t size, char* buffer)
{
    Hash_Sha512 s;
    hash_sha512_init(s);
    hash_sha512_update_binary(s, str, size);
    hash_sha512_finalize(s);
    return hash_sha512_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha512(const char* str, char* buffer)
{
    return hash_sha512_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha512_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_sha512_binary, buffer);
}

HASH_INLINE const char* hash_sha512_easy(const char* str)
{
    return hash_sha512_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha512_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_sha512_binary, NULL);
}
// ===============================Hash_Sha512===================================


// ===============================Hash_Sha512T==================================
typedef Hash_Sha512 Hash_Sha512T;
HASH_INLINE void hash_sha512t_init(Hash_Sha512T s, size_t t)
{
    assert(t != 384 && "t = 384 is not allowed use Hash_Sha384 instead!");
    assert(t >= 4 && t <= 2048 && "t must satisfy t >= 4 && t <= 2048!");
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0xcfac43c256196cad;
    s->h[1] = 0x1ec20b20216f029e;
    s->h[2] = 0x99cb56d75b315d8e;
    s->h[3] = 0x00ea509ffab89354;
    s->h[4] = 0xf4abf7da08432774;
    s->h[5] = 0x3ea0cd298e9bc9ba;
    s->h[6] = 0xba267c0e5ee418ce;
    s->h[7] = 0xfe4568bcb6db84dc;
    s->t = t;

    char str[13], buff[129];
    memset(str, 0, 13);
    sprintf(str, "SHA-512/%u", (unsigned int)t);

    hash_sha512_update(s, str);
    hash_sha512_finalize(s);
    hash_sha512_hexdigest(s, buff);
    hash_sha512_reset(s);

    size_t k = 0;
    for (size_t i = 0; i < 128; i += 16)
    {
        char hex[17];
        hex[16] = 0;
        memcpy(hex, &buff[i], 16);
        s->h[k++] = strtoull(hex, NULL, 16);
    }
};


HASH_INLINE void hash_sha512t_update_binary(Hash_Sha512T s, const char* data, size_t size)
{
    hash_sha512_update_binary(s, data, size);
}

HASH_INLINE void hash_sha512t_update(Hash_Sha512T s, const char* data)
{
    hash_sha512t_update_binary(s, data, strlen(data));
}

HASH_INLINE void hash_sha512t_finalize(Hash_Sha512T s)
{
    hash_sha512_finalize(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least (t/4)+1 (Null term char)
HASH_INLINE const char* hash_sha512t_hexdigest(const Hash_Sha512T s, char* buffer)
{
    static char hex[513]; // use max allowed size to avoid memory allocation
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 8; ++i)
    {
        sprintf(&buff[i * 16], "%016" PRIx64, s->h[i]);
    }
    buff[s->t / 4] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least (t/4)+1 (Null term char)
HASH_INLINE const char* hash_sha512t_binary(size_t t, const char* str, size_t size, char* buffer)
{
    Hash_Sha512T s;
    hash_sha512t_init(s, t);
    hash_sha512t_update_binary(s, str, size);
    hash_sha512t_finalize(s);
    return hash_sha512t_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha512t(size_t t, const char* str, char* buffer)
{
    return hash_sha512t_binary(t, str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha512t_easy(size_t t, const char* str)
{
    return hash_sha512t_binary(t, str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha512t_file(size_t t, const char* path, const char* mode, char* buffer)
{
    long fsize;
    char* content = hash_util_load_file(path, mode, &fsize);
    if (content == NULL) return "";
    const char* hash = hash_sha512t_binary(t, content, fsize, buffer);
    if (content != NULL) free(content);
    return hash;
}


HASH_INLINE const char* hash_sha512t_file_easy(size_t t, const char* path, const char* mode)
{
    return hash_sha512t_file(t, path, mode, NULL);
}
// ===============================Hash_Sha512T==================================


// ===============================Hash_Sha384===================================
typedef Hash_Sha512 Hash_Sha384;
HASH_INLINE void hash_sha384_init(Hash_Sha384 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0xcbbb9d5dc1059ed8;
    s->h[1] = 0x629a292a367cd507;
    s->h[2] = 0x9159015a3070dd17;
    s->h[3] = 0x152fecd8f70e5939;
    s->h[4] = 0x67332667ffc00b31;
    s->h[5] = 0x8eb44a8768581511;
    s->h[6] = 0xdb0c2e0d64f98fa7;
    s->h[7] = 0x47b5481dbefa4fa4;
};


HASH_INLINE void hash_sha384_update_binary(Hash_Sha384 s, const char* data, size_t size)
{
    hash_sha512_update_binary(s, data, size);
}

HASH_INLINE void hash_sha384_update(Hash_Sha384 s, const char* data)
{
    hash_sha384_update_binary(s, data, strlen(data));
}

HASH_INLINE void hash_sha384_finalize(Hash_Sha384 s)
{
    hash_sha512_finalize(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least 97 (Null term char)
HASH_INLINE const char* hash_sha384_hexdigest(const Hash_Sha384 s, char* buffer)
{
    static char hex[97]; // use max allowed size to avoid memory allocation
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 6; ++i)
    {
        sprintf(&buff[i * 16], "%016" PRIx64, s->h[i]);
    }
    buff[96] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least 97 (Null term char)
HASH_INLINE const char* hash_sha384_binary(const char* str, size_t size, char* buffer)
{
    Hash_Sha384 s;
    hash_sha384_init(s);
    hash_sha384_update_binary(s, str, size);
    hash_sha384_finalize(s);
    return hash_sha384_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha384(const char* str, char* buffer)
{
    return hash_sha384_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha384_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_sha384_binary, buffer);
}

HASH_INLINE const char* hash_sha384_easy(const char* str)
{
    return hash_sha384_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha384_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_sha384_binary, NULL);
}
// ===============================Hash_Sha384===================================
#endif // HASH_ENABLE_SHA2


#if HASH_ENABLE_SHA1 == 1
// ================================Hash_Sha1====================================
typedef struct
{
    uint64_t bitlen;
    uint8_t bufferSize;
    uint8_t buffer[64];
    uint32_t h[5];
} Hash_Private_Sha1;
typedef Hash_Private_Sha1 Hash_Sha1[1];


HASH_INLINE void hash_private_hash_sha1_transform(Hash_Sha1 s)
{
    uint32_t w[80] = { 0 };
    for (size_t i = 0; i < 16; ++i)
    {
        uint8_t* ptr = (uint8_t*)&w[i];
        ptr[0] = s->buffer[4 * i];
        ptr[1] = s->buffer[4 * i + 1];
        ptr[2] = s->buffer[4 * i + 2];
        ptr[3] = s->buffer[4 * i + 3];
        w[i] = hash_util_is_little_endian() ? hash_util_swap_endian_uint32_t(w[i]) : w[i];
    }

    for (size_t i = 16; i < 80; ++i)
    {
        w[i] = (hash_util_left_rotate_u32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1));
    }

    uint32_t a = s->h[0];
    uint32_t b = s->h[1];
    uint32_t c = s->h[2];
    uint32_t d = s->h[3];
    uint32_t e = s->h[4];
    uint32_t k, f;

    for (size_t i = 0; i <= 79; ++i)
    {
        if (i <= 19)
        {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999;
        }
        else if (i >= 20 && i <= 39)
        {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        }
        else if (i >= 40 && i <= 59)
        {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        }
        else
        {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }

        const uint32_t tmp = hash_util_left_rotate_u32(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = hash_util_left_rotate_u32(b, 30);
        b = a;
        a = tmp;
    }

    s->h[0] = s->h[0] + a;
    s->h[1] = s->h[1] + b;
    s->h[2] = s->h[2] + c;
    s->h[3] = s->h[3] + d;
    s->h[4] = s->h[4] + e;
}




HASH_INLINE void hash_sha1_init(Hash_Sha1 s)
{
    s->bitlen = 0;
    s->bufferSize = 0;
    s->h[0] = 0x67452301;
    s->h[1] = 0xEFCDAB89;
    s->h[2] = 0x98BADCFE;
    s->h[3] = 0x10325476;
    s->h[4] = 0xC3D2E1F0;
}


HASH_INLINE void hash_sha1_update_binary(Hash_Sha1 s, const char* data, size_t size)
{
    const uint8_t* d = (const uint8_t*)data;
    for (size_t i = 0; i < size; ++i)
    {
        s->buffer[s->bufferSize++] = d[i];
        if (s->bufferSize == 64)
        {
            hash_private_hash_sha1_transform(s);
            s->bufferSize = 0;
            s->bitlen += 512;
        }
    }
}


HASH_INLINE void hash_sha1_update(Hash_Sha1 s, const char* data)
{
    hash_sha1_update_binary(s, data, strlen(data));
}


HASH_INLINE void hash_sha1_finalize(Hash_Sha1 s)
{
    uint8_t start = s->bufferSize;
    uint8_t end = s->bufferSize < 56 ? 56 : 64;

    s->buffer[start++] = 0b10000000;
    memset(&s->buffer[start], 0, end - start);

    if (s->bufferSize >= 56)
    {
        hash_private_hash_sha1_transform(s);
        memset(s->buffer, 0, 56);
    }

    s->bitlen += s->bufferSize * 8;
    uint64_t* const size = (uint64_t*)&s->buffer[64 - 8];
    *size = hash_util_is_little_endian() ? hash_util_swap_endian_uint64_t(s->bitlen) : s->bitlen;
    hash_private_hash_sha1_transform(s);
}


// if buffer == NULL returns internal buffer, buffer size must be at least 41 (Null term char)
HASH_INLINE const char* hash_sha1_hexdigest(const Hash_Sha1 s, char* buffer)
{
    static char hex[41]; // use max allowed size to avoid memory allocation
    char* buff = buffer == NULL ? hex : buffer;
    for (size_t i = 0; i < 5; ++i)
    {
        sprintf(&buff[i * 8], "%08" PRIx32, s->h[i]);
    }
    buff[40] = 0;
    return buff;
}

// if buffer == NULL returns internal buffer, buffer size must be at least 41 (Null term char)
HASH_INLINE const char* hash_sha1_binary(const char* str, size_t size, char* buffer)
{
    Hash_Sha1 s;
    hash_sha1_init(s);
    hash_sha1_update_binary(s, str, size);
    hash_sha1_finalize(s);
    return hash_sha1_hexdigest(s, buffer);
}

HASH_INLINE const char* hash_sha1(const char* str, char* buffer)
{
    return hash_sha1_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_sha1_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_sha1_binary, buffer);
}

HASH_INLINE const char* hash_sha1_easy(const char* str)
{
    return hash_sha1_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_sha1_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_sha1_binary, NULL);
}
// ================================Hash_Sha1====================================
#endif // HASH_ENABLE_SHA1


#if HASH_ENABLE_MD5
// =================================Hash_MD5====================================
#define HASH_PRIVATE_MD5_BLOCKSIZE 64
typedef struct
{
    int finalized;
    uint8_t buffer[HASH_PRIVATE_MD5_BLOCKSIZE]; // bytes that didn't fit in last 64 byte chunk
    uint32_t count[2];   // 64bit counter for number of bits (lo, hi)
    uint32_t state[4];   // digest so far
    uint8_t digest[16]; // the result
} Hash_Private_MD5;
typedef Hash_Private_MD5 Hash_MD5[1];


// low level logic operations
///////////////////////////////////////////////
// F, G, H and I are basic Hash_MD5 functions.
HASH_INLINE uint32_t hash_private_md5_F(uint32_t x, uint32_t y, uint32_t z) {
    return x & y | ~x & z;
}

HASH_INLINE uint32_t hash_private_md5_G(uint32_t x, uint32_t y, uint32_t z) {
    return x & z | y & ~z;
}

HASH_INLINE uint32_t hash_private_md5_H(uint32_t x, uint32_t y, uint32_t z) {
    return x ^ y ^ z;
}

HASH_INLINE uint32_t hash_private_md5_I(uint32_t x, uint32_t y, uint32_t z) {
    return y ^ (x | ~z);
}

// rotate_left rotates x left n bits.
HASH_INLINE uint32_t hash_private_md5_rotate_left(uint32_t x, int n) {
    return (x << n) | (x >> (32 - n));
}


// FF, GG, HH, and II transformations for rounds 1, 2, 3, and 4.
// Rotation is separate from addition to prevent recomputation.
HASH_INLINE uint32_t hash_private_md5_FF(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t x, uint32_t s, uint32_t ac) {
    return hash_private_md5_rotate_left(a + hash_private_md5_F(b, c, d) + x + ac, s) + b;
}

HASH_INLINE uint32_t hash_private_md5_GG(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t x, uint32_t s, uint32_t ac) {
    return hash_private_md5_rotate_left(a + hash_private_md5_G(b, c, d) + x + ac, s) + b;
}

HASH_INLINE uint32_t hash_private_md5_HH(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t x, uint32_t s, uint32_t ac) {
    return hash_private_md5_rotate_left(a + hash_private_md5_H(b, c, d) + x + ac, s) + b;
}

HASH_INLINE uint32_t hash_private_md5_II(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t x, uint32_t s, uint32_t ac) {
    return hash_private_md5_rotate_left(a + hash_private_md5_I(b, c, d) + x + ac, s) + b;
}


// decodes input (unsigned char) into output (uint32_t). Assumes len is a multiple of 4.
HASH_INLINE void hash_private_md5_decode(uint32_t output[], const uint8_t input[], uint32_t len)
{
    for (unsigned int i = 0, j = 0; j < len; i++, j += 4)
        output[i] = ((uint32_t)input[j]) | (((uint32_t)input[j + 1]) << 8) |
        (((uint32_t)input[j + 2]) << 16) | (((uint32_t)input[j + 3]) << 24);
}

//////////////////////////////

// encodes input (uint32_t) into output (unsigned char). Assumes len is
// a multiple of 4.
HASH_INLINE void hash_private_md5_encode(uint8_t output[], const uint32_t input[], uint32_t len)
{
    for (uint32_t i = 0, j = 0; j < len; i++, j += 4) {
        output[j] = input[i] & 0xff;
        output[j + 1] = (input[i] >> 8) & 0xff;
        output[j + 2] = (input[i] >> 16) & 0xff;
        output[j + 3] = (input[i] >> 24) & 0xff;
    }
}


// apply Hash_MD5 algo on a block
HASH_INLINE void hash_private_md5_transform(Hash_MD5 m, const uint8_t block[HASH_PRIVATE_MD5_BLOCKSIZE])
{
    // Constants for Hash_MD5Transform routine.
    static const uint32_t S11 = 7;
    static const uint32_t S12 = 12;
    static const uint32_t S13 = 17;
    static const uint32_t S14 = 22;
    static const uint32_t S21 = 5;
    static const uint32_t S22 = 9;
    static const uint32_t S23 = 14;
    static const uint32_t S24 = 20;
    static const uint32_t S31 = 4;
    static const uint32_t S32 = 11;
    static const uint32_t S33 = 16;
    static const uint32_t S34 = 23;
    static const uint32_t S41 = 6;
    static const uint32_t S42 = 10;
    static const uint32_t S43 = 15;
    static const uint32_t S44 = 21;

    uint32_t a = m->state[0], b = m->state[1], c = m->state[2], d = m->state[3], x[16];
    hash_private_md5_decode(x, block, HASH_PRIVATE_MD5_BLOCKSIZE);

    /* Round 1 */
    a = hash_private_md5_FF(a, b, c, d, x[0], S11, 0xd76aa478); /* 1 */
    d = hash_private_md5_FF(d, a, b, c, x[1], S12, 0xe8c7b756); /* 2 */
    c = hash_private_md5_FF(c, d, a, b, x[2], S13, 0x242070db); /* 3 */
    b = hash_private_md5_FF(b, c, d, a, x[3], S14, 0xc1bdceee); /* 4 */
    a = hash_private_md5_FF(a, b, c, d, x[4], S11, 0xf57c0faf); /* 5 */
    d = hash_private_md5_FF(d, a, b, c, x[5], S12, 0x4787c62a); /* 6 */
    c = hash_private_md5_FF(c, d, a, b, x[6], S13, 0xa8304613); /* 7 */
    b = hash_private_md5_FF(b, c, d, a, x[7], S14, 0xfd469501); /* 8 */
    a = hash_private_md5_FF(a, b, c, d, x[8], S11, 0x698098d8); /* 9 */
    d = hash_private_md5_FF(d, a, b, c, x[9], S12, 0x8b44f7af); /* 10 */
    c = hash_private_md5_FF(c, d, a, b, x[10], S13, 0xffff5bb1); /* 11 */
    b = hash_private_md5_FF(b, c, d, a, x[11], S14, 0x895cd7be); /* 12 */
    a = hash_private_md5_FF(a, b, c, d, x[12], S11, 0x6b901122); /* 13 */
    d = hash_private_md5_FF(d, a, b, c, x[13], S12, 0xfd987193); /* 14 */
    c = hash_private_md5_FF(c, d, a, b, x[14], S13, 0xa679438e); /* 15 */
    b = hash_private_md5_FF(b, c, d, a, x[15], S14, 0x49b40821); /* 16 */

    /* Round 2 */
    a = hash_private_md5_GG(a, b, c, d, x[1], S21, 0xf61e2562); /* 17 */
    d = hash_private_md5_GG(d, a, b, c, x[6], S22, 0xc040b340); /* 18 */
    c = hash_private_md5_GG(c, d, a, b, x[11], S23, 0x265e5a51); /* 19 */
    b = hash_private_md5_GG(b, c, d, a, x[0], S24, 0xe9b6c7aa); /* 20 */
    a = hash_private_md5_GG(a, b, c, d, x[5], S21, 0xd62f105d); /* 21 */
    d = hash_private_md5_GG(d, a, b, c, x[10], S22, 0x2441453); /* 22 */
    c = hash_private_md5_GG(c, d, a, b, x[15], S23, 0xd8a1e681); /* 23 */
    b = hash_private_md5_GG(b, c, d, a, x[4], S24, 0xe7d3fbc8); /* 24 */
    a = hash_private_md5_GG(a, b, c, d, x[9], S21, 0x21e1cde6); /* 25 */
    d = hash_private_md5_GG(d, a, b, c, x[14], S22, 0xc33707d6); /* 26 */
    c = hash_private_md5_GG(c, d, a, b, x[3], S23, 0xf4d50d87); /* 27 */
    b = hash_private_md5_GG(b, c, d, a, x[8], S24, 0x455a14ed); /* 28 */
    a = hash_private_md5_GG(a, b, c, d, x[13], S21, 0xa9e3e905); /* 29 */
    d = hash_private_md5_GG(d, a, b, c, x[2], S22, 0xfcefa3f8); /* 30 */
    c = hash_private_md5_GG(c, d, a, b, x[7], S23, 0x676f02d9); /* 31 */
    b = hash_private_md5_GG(b, c, d, a, x[12], S24, 0x8d2a4c8a); /* 32 */

    /* Round 3 */
    a = hash_private_md5_HH(a, b, c, d, x[5], S31, 0xfffa3942); /* 33 */
    d = hash_private_md5_HH(d, a, b, c, x[8], S32, 0x8771f681); /* 34 */
    c = hash_private_md5_HH(c, d, a, b, x[11], S33, 0x6d9d6122); /* 35 */
    b = hash_private_md5_HH(b, c, d, a, x[14], S34, 0xfde5380c); /* 36 */
    a = hash_private_md5_HH(a, b, c, d, x[1], S31, 0xa4beea44); /* 37 */
    d = hash_private_md5_HH(d, a, b, c, x[4], S32, 0x4bdecfa9); /* 38 */
    c = hash_private_md5_HH(c, d, a, b, x[7], S33, 0xf6bb4b60); /* 39 */
    b = hash_private_md5_HH(b, c, d, a, x[10], S34, 0xbebfbc70); /* 40 */
    a = hash_private_md5_HH(a, b, c, d, x[13], S31, 0x289b7ec6); /* 41 */
    d = hash_private_md5_HH(d, a, b, c, x[0], S32, 0xeaa127fa); /* 42 */
    c = hash_private_md5_HH(c, d, a, b, x[3], S33, 0xd4ef3085); /* 43 */
    b = hash_private_md5_HH(b, c, d, a, x[6], S34, 0x4881d05); /* 44 */
    a = hash_private_md5_HH(a, b, c, d, x[9], S31, 0xd9d4d039); /* 45 */
    d = hash_private_md5_HH(d, a, b, c, x[12], S32, 0xe6db99e5); /* 46 */
    c = hash_private_md5_HH(c, d, a, b, x[15], S33, 0x1fa27cf8); /* 47 */
    b = hash_private_md5_HH(b, c, d, a, x[2], S34, 0xc4ac5665); /* 48 */

    /* Round 4 */
    a = hash_private_md5_II(a, b, c, d, x[0], S41, 0xf4292244); /* 49 */
    d = hash_private_md5_II(d, a, b, c, x[7], S42, 0x432aff97); /* 50 */
    c = hash_private_md5_II(c, d, a, b, x[14], S43, 0xab9423a7); /* 51 */
    b = hash_private_md5_II(b, c, d, a, x[5], S44, 0xfc93a039); /* 52 */
    a = hash_private_md5_II(a, b, c, d, x[12], S41, 0x655b59c3); /* 53 */
    d = hash_private_md5_II(d, a, b, c, x[3], S42, 0x8f0ccc92); /* 54 */
    c = hash_private_md5_II(c, d, a, b, x[10], S43, 0xffeff47d); /* 55 */
    b = hash_private_md5_II(b, c, d, a, x[1], S44, 0x85845dd1); /* 56 */
    a = hash_private_md5_II(a, b, c, d, x[8], S41, 0x6fa87e4f); /* 57 */
    d = hash_private_md5_II(d, a, b, c, x[15], S42, 0xfe2ce6e0); /* 58 */
    c = hash_private_md5_II(c, d, a, b, x[6], S43, 0xa3014314); /* 59 */
    b = hash_private_md5_II(b, c, d, a, x[13], S44, 0x4e0811a1); /* 60 */
    a = hash_private_md5_II(a, b, c, d, x[4], S41, 0xf7537e82); /* 61 */
    d = hash_private_md5_II(d, a, b, c, x[11], S42, 0xbd3af235); /* 62 */
    c = hash_private_md5_II(c, d, a, b, x[2], S43, 0x2ad7d2bb); /* 63 */
    b = hash_private_md5_II(b, c, d, a, x[9], S44, 0xeb86d391); /* 64 */

    m->state[0] += a;
    m->state[1] += b;
    m->state[2] += c;
    m->state[3] += d;

    // Zeroize sensitive information.
    memset(x, 0, sizeof x);
}


HASH_INLINE void hash_private_md5_update_binary(Hash_MD5 m, const unsigned char* input, size_t size)
{
    const uint32_t s = (uint32_t)size;
    // compute number of bytes mod 64
    uint32_t index = m->count[0] / 8 % HASH_PRIVATE_MD5_BLOCKSIZE;

    // Update number of bits
    if ((m->count[0] += (s << 3)) < (s << 3))
        m->count[1]++;
    m->count[1] += (s >> 29);

    // number of bytes we need to fill in buffer
    uint32_t firstpart = 64 - index;

    uint32_t i;

    // transform as many times as possible.
    if (s >= firstpart)
    {
        // fill buffer first, transform
        memcpy(&m->buffer[index], input, firstpart);
        hash_private_md5_transform(m, m->buffer);

        // transform chunks of blocksize (64 bytes)
        for (i = firstpart; i + HASH_PRIVATE_MD5_BLOCKSIZE <= s; i += HASH_PRIVATE_MD5_BLOCKSIZE)
            hash_private_md5_transform(m, &input[i]);

        index = 0;
    }
    else
        i = 0;

    // buffer remaining input
    memcpy(&m->buffer[index], &input[i], s - i);
}



HASH_INLINE void hash_md5_init(Hash_MD5 m)
{
    m->finalized = 0;
    m->count[0] = 0;
    m->count[1] = 0;

    // load magic initialization constants.
    m->state[0] = 0x67452301;
    m->state[1] = 0xefcdab89;
    m->state[2] = 0x98badcfe;
    m->state[3] = 0x10325476;
}


HASH_INLINE void hash_md5_update_binary(Hash_MD5 m, const char* data, size_t size)
{
    hash_private_md5_update_binary(m, (const unsigned char*)data, size);
}


HASH_INLINE void hash_md5_update(Hash_MD5 m, const char* data)
{
    hash_md5_update_binary(m, data, strlen(data));
}


// Hash_MD5 finalization. Ends an Hash_MD5 message-digest operation, writing the
// the message digest and zeroizing the context.
HASH_INLINE void  hash_md5_finalize(Hash_MD5 m)
{
    static unsigned char padding[64] = {
      0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    };

    if (!m->finalized) {
        // Save number of bits
        unsigned char bits[8];
        hash_private_md5_encode(bits, m->count, 8);

        // pad out to 56 mod 64.
        uint32_t index = m->count[0] / 8 % 64;
        uint32_t padLen = (index < 56) ? (56 - index) : (120 - index);
        hash_private_md5_update_binary(m, padding, padLen);

        // Append length (before padding)
        hash_private_md5_update_binary(m, bits, 8);

        // Store state in digest
        hash_private_md5_encode(m->digest, m->state, 16);

        // Zeroize sensitive information.
        memset(m->buffer, 0, sizeof m->buffer);
        memset(m->count, 0, sizeof m->count);

        m->finalized = 1;
    }
}


// if buffer == NULL returns internal buffer, buffer size must be at least 33 (Null term char)
HASH_INLINE const char* hash_md5_hexdigest(const Hash_MD5 m, char* buffer)
{
    if (!m->finalized)
        return "";

    static char hex[33];
    char* buf = buffer == NULL ? hex : buffer;
    for (int i = 0; i < 16; i++)
        sprintf(buf + i * 2, "%02x", m->digest[i]);
    buf[32] = 0;
    return buf;
}


// if buffer == NULL returns internal buffer, buffer size must be at least 33 (Null term char)
HASH_INLINE const char* hash_md5_binary(const char* str, size_t size, char* buffer)
{
    Hash_MD5 m;
    hash_md5_init(m);
    hash_md5_update_binary(m, str, size);
    hash_md5_finalize(m);
    return hash_md5_hexdigest(m, buffer);
}

HASH_INLINE const char* hash_md5(const char* str, char* buffer)
{
    return hash_md5_binary(str, strlen(str), buffer);
}

HASH_INLINE const char* hash_md5_file(const char* path, const char* mode, char* buffer)
{
    return hash_util_hash_file(path, mode, hash_md5_binary, buffer);
}

HASH_INLINE const char* hash_md5_easy(const char* str)
{
    return hash_md5_binary(str, strlen(str), NULL);
}

HASH_INLINE const char* hash_md5_file_easy(const char* path, const char* mode)
{
    return hash_util_hash_file(path, mode, hash_md5_binary, NULL);
}
#undef HASH_PRIVATE_MD5_BLOCKSIZE
// =================================Hash_MD5====================================
#endif // HASH_ENABLE_MD5
#endif // HASH_ENABLE_C_FUNCTIONS


#ifdef __cplusplus
namespace Hash
{
    namespace Encode
    {
        // C++11 - 17 only | for u16 or u32 strings/string literals
        template <class String>
        inline std::string ToUtf8String(const String& str)
        {
            // Create a locale that uses the codecvt_utf8 facet
            //std::locale loc(std::locale(), new std::codecvt_utf8<char>());
            // Create a wstring_convert object using the locale
            std::wstring_convert<std::codecvt_utf8<typename String::value_type>, typename String::value_type> convert;
            // Decode the string as a sequence of UTF-8 code points
            return convert.to_bytes(str);
        }


        // only for strings with characters from -127 - 127
        // encode iso-8859-1
        inline std::string Iso88591ToUtf8(const std::string_view& str)
        {
            std::string strOut;
            for (std::string_view::const_iterator it = str.begin(); it != str.end(); ++it)
            {
                uint8_t ch = *it;
                if (ch < 0x80) {
                    strOut.push_back(ch);
                }
                else {
                    strOut.push_back(0xc0 | ch >> 6);
                    strOut.push_back(0x80 | (ch & 0x3f));
                }
            }
            return strOut;
        }
    }


    namespace Util
    {
        inline std::string CharArrayToHexString(unsigned char* data, size_t size)
        {
            static const char hex_chars[16] = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
            std::string string;
            for (size_t i = 0; i < size; ++i)
            {
                char const byte = data[i];

                string += hex_chars[(byte & 0xF0) >> 4];
                string += hex_chars[(byte & 0x0F) >> 0];
            }
            return string;
        }


        inline std::string LoadFile(const char* path, std::ios::openmode flag) // std::ios::binary | std::ios::binary
        {
            std::ifstream infile(path, flag);
            if (!infile.is_open())
                return "";

            infile.seekg(0, std::ios::end);
            size_t size = (size_t)infile.tellg();
            infile.seekg(0, std::ios::beg);

            std::string data(size, ' ');
            infile.read(data.data(), size);
            return data;
        }


        template <typename T>
        constexpr T SwapEndian(T u)
        {
            static_assert (CHAR_BIT == 8, "CHAR_BIT != 8");

            union
            {
                T u;
                unsigned char u8[sizeof(T)];
            } source, dest;
            source.u = u;

            for (size_t k = 0; k < sizeof(T); k++)
                dest.u8[k] = source.u8[sizeof(T) - k - 1];

            return dest.u;
        }


        inline bool IsLittleEndian()
        {
            int32_t num = 1;
            return *(char*)&num == 1;
        }

        template <typename T> constexpr T RightRotate(T n, unsigned int c)
        {
            //const unsigned int mask = (CHAR_BIT * sizeof(n) - 1); // doesn't loose bits
            //c &= mask;
            //return (n >> c) | (n << ((-c) & mask));
            return (n >> c) | (n << (std::numeric_limits<T>::digits - c));
        }

        template <typename T> constexpr T LeftRotate(T n, unsigned int c)
        {
            //const unsigned int mask = (CHAR_BIT * sizeof(n) - 1); // doesn't loose bits
            //c &= mask;
            //return (n << c) | (n >> ((-c) & mask));
            return (n << c) | (n >> (std::numeric_limits<T>::digits - c));
        }
    }

#if HASH_ENABLE_SHA2 == 1
    class Sha256
    {
    private:
        uint64_t m_Bitlen = 0;
        uint8_t m_BufferSize = 0;
        uint8_t m_Buffer[64];
    protected:
        // FracPartsSqareRoots
        uint32_t m_H[8] =
        {
            0x6a09e667,
            0xbb67ae85,
            0x3c6ef372,
            0xa54ff53a,
            0x510e527f,
            0x9b05688c,
            0x1f83d9ab,
            0x5be0cd19
        };
    private:
        // FracPartsCubeRoots
        static constexpr uint32_t s_K[64] =
        {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        };
    private:
        inline void Compress(const uint32_t* const w)
        {
            uint32_t a = m_H[0];
            uint32_t b = m_H[1];
            uint32_t c = m_H[2];
            uint32_t d = m_H[3];
            uint32_t e = m_H[4];
            uint32_t f = m_H[5];
            uint32_t g = m_H[6];
            uint32_t h = m_H[7];
            for (size_t i = 0; i < 64; ++i)
            {
                const uint32_t s1 = Util::RightRotate(e, 6) ^ Util::RightRotate(e, 11) ^ Util::RightRotate(e, 25);
                const uint32_t ch = (e & f) ^ (~e & g);
                const uint32_t temp1 = h + s1 + ch + s_K[i] + w[i];
                const uint32_t s0 = Util::RightRotate(a, 2) ^ Util::RightRotate(a, 13) ^ Util::RightRotate(a, 22);
                const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
                const uint32_t temp2 = s0 + maj;
                h = g;
                g = f;
                f = e;
                e = d + temp1;
                d = c;
                c = b;
                b = a;
                a = temp1 + temp2;
            }
            m_H[0] += a;
            m_H[1] += b;
            m_H[2] += c;
            m_H[3] += d;
            m_H[4] += e;
            m_H[5] += f;
            m_H[6] += g;
            m_H[7] += h;
        }


        inline void Transform()
        {
            static uint32_t w[64];
            for (size_t i = 0; i < 16; ++i)
            {
                uint8_t* c = (uint8_t*)&w[i];
                c[0] = m_Buffer[4 * i];
                c[1] = m_Buffer[4 * i + 1];
                c[2] = m_Buffer[4 * i + 2];
                c[3] = m_Buffer[4 * i + 3];
                w[i] = Util::IsLittleEndian() ? Util::SwapEndian(w[i]) : w[i];
            }

            for (size_t i = 16; i < 64; ++i)
            {
                const uint32_t s0 = Util::RightRotate(w[i - 15], 7) ^ Util::RightRotate(w[i - 15], 18) ^ (w[i - 15] >> 3);
                const uint32_t s1 = Util::RightRotate(w[i - 2], 17) ^ Util::RightRotate(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            }
            Compress(w);
        }
    public:
        Sha256() = default;
        explicit Sha256(uint32_t h0, uint32_t h1, uint32_t h2, uint32_t h3, uint32_t h4, uint32_t h5, uint32_t h6, uint32_t h7) : m_H{ h0, h1, h2, h3, h4, h5, h6, h7 } {}
        virtual ~Sha256() = default;

        inline void Update(const uint8_t* data, std::size_t size)
        {
            for (size_t i = 0; i < size; ++i)
            {
                m_Buffer[m_BufferSize++] = data[i];
                if (m_BufferSize == 64)
                {
                    Transform();
                    m_BufferSize = 0;
                    m_Bitlen += 512;
                }
            }
        }

        inline void Update(const char* data, std::size_t size)
        {
            Update((const uint8_t*)data, size);
        }

        inline void Update(std::string_view data)
        {
            Update((const uint8_t*)data.data(), data.size());
        }


        inline virtual void Finalize()
        {
            uint8_t start = m_BufferSize;
            uint8_t end = m_BufferSize < 56 ? 56 : 64;

            m_Buffer[start++] = 0b10000000;
            std::memset(&m_Buffer[start], 0, end - start);

            if (m_BufferSize >= 56)
            {
                Transform();
                std::memset(m_Buffer, 0, 56);
            }

            m_Bitlen += m_BufferSize * 8;
            uint64_t* const size = (uint64_t*)&m_Buffer[64 - 8];
            *size = Util::IsLittleEndian() ? Util::SwapEndian(m_Bitlen) : m_Bitlen;
            Transform();
        }


        inline virtual std::string Hexdigest() const
        {
            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(8) << m_H[0] << std::setw(8) << m_H[1] << std::setw(8) << m_H[2] << std::setw(8) << m_H[3] << std::setw(8) << m_H[4] << std::setw(8) << m_H[5] << std::setw(8) << m_H[6] << std::setw(8) << m_H[7];
            return stream.str();
        }
    };


    // if you have any kind of unicode string, use the Hash::encode functions beforehand to convert the string
    inline std::string sha256(const char* str, std::size_t size)
    {
        Sha256 s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha256(std::string_view str)
    {
        return sha256(str.data(), str.size());
    }

    namespace File
    {
        inline std::string sha256(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha256(Util::LoadFile(path, flag));
        }

        inline std::string sha256(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha256(Util::LoadFile(path.data(), flag));
        }
    }



    class Sha224 : public Sha256
    {
    public:
        Sha224() : Sha256(0xC1059ED8, 0x367CD507, 0x3070DD17, 0xF70E5939, 0xFFC00B31, 0x68581511, 0x64F98FA7, 0xBEFA4FA4) {}
        inline std::string Hexdigest() const override
        {
            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(8) << m_H[0] << std::setw(8) << m_H[1] << std::setw(8) << m_H[2] << std::setw(8) << m_H[3] << std::setw(8) << m_H[4] << std::setw(8) << m_H[5] << std::setw(8) << m_H[6];
            return stream.str();
        }
    };


    // if you have any kind of unicode string, use the Hash::encode functions beforehand to convert the string
    inline std::string sha224(const char* str, std::size_t size)
    {
        Sha224 s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha224(std::string_view str)
    {
        return sha224(str.data(), str.size());
    }

    namespace File
    {
        inline std::string sha224(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha224(Util::LoadFile(path, flag));
        }

        inline std::string sha224(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha224(Util::LoadFile(path.data(), flag));
        }
    }




    class Sha512
    {
    private:
        uint64_t m_Bitlen = 0;
        uint8_t m_BufferSize = 0;
        uint8_t m_Buffer[128];
    protected:
        uint64_t m_H[8] =
        {
            0x6a09e667f3bcc908,
            0xbb67ae8584caa73b,
            0x3c6ef372fe94f82b,
            0xa54ff53a5f1d36f1,
            0x510e527fade682d1,
            0x9b05688c2b3e6c1f,
            0x1f83d9abfb41bd6b,
            0x5be0cd19137e2179
        };
    private:
        // round constants
        static constexpr uint64_t s_K[80] =
        {
            0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
            0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
            0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
            0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
            0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
            0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
            0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
            0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
            0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
            0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
            0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
            0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
            0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
            0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
            0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
            0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817
        };
    private:
        inline void Compress(const uint64_t* const w)
        {
            uint64_t a = m_H[0];
            uint64_t b = m_H[1];
            uint64_t c = m_H[2];
            uint64_t d = m_H[3];
            uint64_t e = m_H[4];
            uint64_t f = m_H[5];
            uint64_t g = m_H[6];
            uint64_t h = m_H[7];
            for (size_t i = 0; i < 80; ++i)
            {
                const uint64_t s1 = Util::RightRotate(e, 14) ^ Util::RightRotate(e, 18) ^ Util::RightRotate(e, 41);
                const uint64_t ch = (e & f) ^ (~e & g);
                const uint64_t temp1 = h + s1 + ch + s_K[i] + w[i];
                const uint64_t s0 = Util::RightRotate(a, 28) ^ Util::RightRotate(a, 34) ^ Util::RightRotate(a, 39);
                const uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
                const uint64_t temp2 = s0 + maj;
                h = g;
                g = f;
                f = e;
                e = d + temp1;
                d = c;
                c = b;
                b = a;
                a = temp1 + temp2;
            }
            m_H[0] += a;
            m_H[1] += b;
            m_H[2] += c;
            m_H[3] += d;
            m_H[4] += e;
            m_H[5] += f;
            m_H[6] += g;
            m_H[7] += h;
        }


        inline void Transform()
        {
            static uint64_t w[80];
            for (size_t i = 0; i < 16; ++i)
            {
                uint8_t* c = (uint8_t*)&w[i];
                c[0] = m_Buffer[8 * i];
                c[1] = m_Buffer[8 * i + 1];
                c[2] = m_Buffer[8 * i + 2];
                c[3] = m_Buffer[8 * i + 3];
                c[4] = m_Buffer[8 * i + 4];
                c[5] = m_Buffer[8 * i + 5];
                c[6] = m_Buffer[8 * i + 6];
                c[7] = m_Buffer[8 * i + 7];
                w[i] = Util::IsLittleEndian() ? Util::SwapEndian(w[i]) : w[i];
            }

            for (size_t i = 16; i < 80; ++i) // Extend the first 16 words
            {
                const uint64_t s0 = Util::RightRotate(w[i - 15], 1) ^ Util::RightRotate(w[i - 15], 8) ^ (w[i - 15] >> 7);
                const uint64_t s1 = Util::RightRotate(w[i - 2], 19) ^ Util::RightRotate(w[i - 2], 61) ^ (w[i - 2] >> 6);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            }
            Compress(w);
        }
    public:
        Sha512() = default;
        explicit Sha512(uint64_t h0, uint64_t h1, uint64_t h2, uint64_t h3, uint64_t h4, uint64_t h5, uint64_t h6, uint64_t h7) : m_H{ h0, h1, h2, h3, h4, h5, h6, h7 } {}
        virtual ~Sha512() = default;

        inline void Reset()
        {
            m_Bitlen = 0;
            m_BufferSize = 0;
        }

        inline void Update(const uint8_t* data, std::size_t size)
        {
            for (size_t i = 0; i < size; ++i)
            {
                m_Buffer[m_BufferSize++] = data[i];
                if (m_BufferSize == 128)
                {
                    Transform();
                    m_BufferSize = 0;
                    m_Bitlen += 1024;
                }
            }
        }

        inline void Update(const char* data, std::size_t size)
        {
            Update((const uint8_t*)data, size);
        }

        inline void Update(std::string_view data)
        {
            Update((const uint8_t*)data.data(), data.size());
        }


        inline void Finalize()
        {
            uint8_t start = m_BufferSize;
            uint8_t end = m_BufferSize < 112 ? 120 : 128; // 120 instead of 112 because m_Bitlen is a 64 bit uint

            m_Buffer[start++] = 0b10000000;
            std::memset(&m_Buffer[start], 0, end - start);

            if (m_BufferSize >= 112)
            {
                Transform();
                std::memset(m_Buffer, 0, 120);
            }

            m_Bitlen += m_BufferSize * 8;
            uint64_t* const size = (uint64_t*)&m_Buffer[128 - 8]; // -8 instead of -16 because we use an uint64 instead of uint128
            *size = Util::IsLittleEndian() ? Util::SwapEndian(m_Bitlen) : m_Bitlen;
            Transform();
        }


        inline virtual std::string Hexdigest() const
        {
            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(16) << m_H[0] << std::setw(16) << m_H[1] << std::setw(16) << m_H[2] << std::setw(16) << m_H[3] << std::setw(16) << m_H[4] << std::setw(16) << m_H[5] << std::setw(16) << m_H[6] << std::setw(16) << m_H[7];
            return stream.str();
        }
    };


    // if you have any kind of unicode string, use the Hash::encode functions beforehand to convert the string
    inline std::string sha512(const char* str, std::size_t size)
    {
        Sha512 s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha512(std::string_view str)
    {
        return sha512(str.data(), str.size());
    }

    namespace File
    {
        inline std::string sha512(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha512(Util::LoadFile(path, flag));
        }

        inline std::string sha512(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha512(Util::LoadFile(path.data(), flag));
        }
    }





    class Sha512T : public Sha512
    {
    private:
        size_t m_T;
    private:
        inline std::string HexdigestFull() const
        {
            return Sha512::Hexdigest();
        }
    public:
        inline explicit Sha512T(size_t t) : Sha512(0xcfac43c256196cad, 0x1ec20b20216f029e, 0x99cb56d75b315d8e, 0x00ea509ffab89354, 0xf4abf7da08432774, 0x3ea0cd298e9bc9ba, 0xba267c0e5ee418ce, 0xfe4568bcb6db84dc), m_T(t)
        {
            assert(t != 384 && "t = 384 is not allowed use Sha384 instead!");
            assert(t >= 4 && t <= 2048 && "t must satisfy t >= 4 && t <= 2048!");

            std::string s = "SHA-512/" + std::to_string(m_T);
            Update(s);
            Finalize();
            s = HexdigestFull();
            Reset();

            size_t k = 0;
            for (size_t i = 0; i < s.size(); i += 16)
            {
                std::stringstream ss;
                ss << std::hex << std::string_view(&s.c_str()[i], 16);
                ss >> m_H[k++];
            }
        }

        inline std::string Hexdigest() const override
        {
            return Sha512::Hexdigest().substr(0, m_T / 4);
        }
    };


    template <size_t T>
    class Sha512_T : public Sha512T
    {
        static_assert(T != 384, "T = 384 is not allowed use Sha384 instead!");
        static_assert(T >= 4 && T <= 2048 * 4, "T must satisfy T >= 4 && T <= 2048!");
    public:
        inline Sha512_T() : Sha512T(T) {}
    };
    using Sha512_224 = Sha512_T<224>;
    using Sha512_256 = Sha512_T<256>;


    inline std::string sha512t(size_t t, const char* str, std::size_t size)
    {
        Sha512T s(t);
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha512t(size_t t, std::string_view str)
    {
        return sha512t(t, str.data(), str.size());
    }

    template <size_t T> inline std::string sha512t(const char* str, std::size_t size)
    {
        Sha512_T<T> s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    template <size_t T> inline std::string sha512t(std::string_view str)
    {
        return sha512t<T>(str.data(), str.size());
    }

    inline std::string sha512_224(std::string_view str) { return sha512t<224>(str.data(), str.size()); }
    inline std::string sha512_256(std::string_view str) { return sha512t<256>(str.data(), str.size()); }
    inline std::string sha512_224(const char* str, std::size_t size) { return sha512t<224>(str, size); }
    inline std::string sha512_256(const char* str, std::size_t size) { return sha512t<256>(str, size); }

    namespace File
    {
        inline std::string sha512t(size_t t, const char* path, std::ios::openmode flag = std::ios::binary) { return Hash::sha512t(t, Util::LoadFile(path, flag)); }
        inline std::string sha512t(size_t t, std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha512t(t, Util::LoadFile(path.data(), flag)); }
        template <size_t T> inline std::string sha512t(const char* path, std::ios::openmode flag = std::ios::binary) { return Hash::sha512t<T>(Util::LoadFile(path, flag)); }
        template <size_t T> inline std::string sha512t(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha512t<T>(Util::LoadFile(path.data(), flag)); }

        inline std::string sha512_224(const char* path, std::ios::openmode flag = std::ios::binary) { return sha512t<224>(path, flag); }
        inline std::string sha512_256(const char* path, std::ios::openmode flag = std::ios::binary) { return sha512t<256>(path, flag); }
        inline std::string sha512_224(std::string_view path, std::ios::openmode flag = std::ios::binary) { return sha512t<224>(path, flag); }
        inline std::string sha512_256(std::string_view path, std::ios::openmode flag = std::ios::binary) { return sha512t<256>(path, flag); }
    }





    class Sha384 : public Sha512
    {
    public:
        Sha384() : Sha512(0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939, 0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4) {}
        inline std::string Hexdigest() const override
        {
            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(16) << m_H[0] << std::setw(16) << m_H[1] << std::setw(16) << m_H[2] << std::setw(16) << m_H[3] << std::setw(16) << m_H[4] << std::setw(16) << m_H[5];
            return stream.str();
        }
    };


    // if you have any kind of unicode string, use the Hash::encode functions beforehand to convert the string
    inline std::string sha384(const char* str, std::size_t size)
    {
        Sha384 s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha384(std::string_view str)
    {
        return sha384(str.data(), str.size());
    }

    namespace File
    {
        inline std::string sha384(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha384(Util::LoadFile(path, flag));
        }

        inline std::string sha384(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha384(Util::LoadFile(path.data(), flag));
        }
    }
#endif // HASH_ENABLE_SHA2



#if HASH_ENABLE_SHA1 == 1
    class Sha1
    {
    private:
        uint64_t m_Bitlen = 0;
        uint8_t m_BufferSize = 0;
        uint8_t m_Buffer[64];

        uint32_t m_H[5] =
        {
            0x67452301,
            0xEFCDAB89,
            0x98BADCFE,
            0x10325476,
            0xC3D2E1F0
        };
    private:
        inline void Transform()
        {
            uint32_t w[80] = { 0 };
            for (size_t i = 0; i < 16; ++i)
            {
                uint8_t* ptr = (uint8_t*)&w[i];
                ptr[0] = m_Buffer[4 * i];
                ptr[1] = m_Buffer[4 * i + 1];
                ptr[2] = m_Buffer[4 * i + 2];
                ptr[3] = m_Buffer[4 * i + 3];
                w[i] = Util::IsLittleEndian() ? Util::SwapEndian<uint32_t>(w[i]) : w[i];
            }

            for (size_t i = 16; i < 80; ++i)
            {
                w[i] = (Util::LeftRotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1));
            }

            uint32_t a = m_H[0];
            uint32_t b = m_H[1];
            uint32_t c = m_H[2];
            uint32_t d = m_H[3];
            uint32_t e = m_H[4];
            uint32_t k, f;

            for (size_t i = 0; i <= 79; ++i)
            {
                if (i <= 19)
                {
                    f = (b & c) | ((~b) & d);
                    k = 0x5A827999;
                }
                else if (i >= 20 && i <= 39)
                {
                    f = b ^ c ^ d;
                    k = 0x6ED9EBA1;
                }
                else if (i >= 40 && i <= 59)
                {
                    f = (b & c) | (b & d) | (c & d);
                    k = 0x8F1BBCDC;
                }
                else
                    //else if (i >= 60 && i <= 79)
                {
                    f = b ^ c ^ d;
                    k = 0xCA62C1D6;
                }

                const uint32_t tmp = Util::LeftRotate(a, 5) + f + e + k + w[i];
                e = d;
                d = c;
                c = Util::LeftRotate(b, 30);
                b = a;
                a = tmp;
            }

            m_H[0] = m_H[0] + a;
            m_H[1] = m_H[1] + b;
            m_H[2] = m_H[2] + c;
            m_H[3] = m_H[3] + d;
            m_H[4] = m_H[4] + e;
        }
    public:
        inline void Update(const uint8_t* data, std::size_t size)
        {
            for (size_t i = 0; i < size; ++i)
            {
                m_Buffer[m_BufferSize++] = data[i];
                if (m_BufferSize == 64)
                {
                    Transform();
                    m_BufferSize = 0;
                    m_Bitlen += 512;
                }
            }
        }

        inline void Update(const char* data, std::size_t size)
        {
            Update((const uint8_t*)data, size);
        }

        inline void Update(std::string_view data)
        {
            Update((const uint8_t*)data.data(), data.size());
        }

        inline void Finalize()
        {
            uint8_t start = m_BufferSize;
            uint8_t end = m_BufferSize < 56 ? 56 : 64;

            m_Buffer[start++] = 0b10000000;
            std::memset(&m_Buffer[start], 0, end - start);

            if (m_BufferSize >= 56)
            {
                Transform();
                std::memset(m_Buffer, 0, 56);
            }

            m_Bitlen += m_BufferSize * 8;
            uint64_t* const size = (uint64_t*)&m_Buffer[64 - 8];
            *size = Util::IsLittleEndian() ? Util::SwapEndian(m_Bitlen) : m_Bitlen;
            Transform();
        }


        inline std::string Hexdigest() const
        {
            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(8) << m_H[0] << std::setw(8) << m_H[1] << std::setw(8) << m_H[2] << std::setw(8) << m_H[3] << std::setw(8) << m_H[4];
            return stream.str();
        }
    };

    inline std::string sha1(const char* str, std::size_t size)
    {
        Sha1 s;
        s.Update(str, size);
        s.Finalize();
        return s.Hexdigest();
    }

    inline std::string sha1(std::string_view str)
    {
        return sha1(str.data(), str.size());
    }

    namespace File
    {
        inline std::string sha1(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha1(Util::LoadFile(path, flag));
        }

        inline std::string sha1(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::sha1(Util::LoadFile(path.data(), flag));
        }
    }
#endif // HASH_ENABLE_SHA1



#if HASH_ENABLE_MD5 == 1
    //=============================================================================
    /* MD5
     converted to C++ class by Frank Thilo (thilo@unix-ag.org)
     for bzflag (http://www.bzflag.org)

       based on:

       md5.h and md5.c
       reference implemantion of RFC 1321

       Copyright (C) 1991-2, RSA Data Security, Inc. Created 1991. All
    rights reserved.

    License to copy and use this software is granted provided that it
    is identified as the "RSA Data Security, Inc. MD5 Message-Digest
    Algorithm" in all material mentioning or referencing this software
    or this function.

    License is also granted to make and use derivative works provided
    that such works are identified as "derived from the RSA Data
    Security, Inc. MD5 Message-Digest Algorithm" in all material
    mentioning or referencing the derived work.

    RSA Data Security, Inc. makes no representations concerning either
    the merchantability of this software or the suitability of this
    software for any particular purpose. It is provided "as is"
    without express or implied warranty of any kind.

    These notices must be retained in any copies of any part of this
    documentation and/or software.
    */

    // a small class for calculating MD5 hashes of strings or byte arrays
    // it is not meant to be fast or secure
    //
    // usage: 1) feed it blocks of uchars with update()
    //      2) finalize()
    //      3) get hexdigest() string
    //      or
    //      MD5(std::string).hexdigest()
    //
    // assumes that char is 8 bit and int is 32 bit
    class MD5
    {
    public:
        typedef unsigned int size_type; // must be 32bit
    private:
        typedef unsigned char uint1; //  8bit
        typedef unsigned int uint4;  // 32bit
        enum { blocksize = 64 }; // VC6 won't eat a const static int here

        bool finalized;
        uint1 buffer[blocksize]; // bytes that didn't fit in last 64 byte chunk
        uint4 count[2];   // 64bit counter for number of bits (lo, hi)
        uint4 state[4];   // digest so far
        uint1 digest[16]; // the result
    private:
        // Constants for MD5 Transform routine.
        static constexpr uint4 S11 = 7;
        static constexpr uint4 S12 = 12;
        static constexpr uint4 S13 = 17;
        static constexpr uint4 S14 = 22;
        static constexpr uint4 S21 = 5;
        static constexpr uint4 S22 = 9;
        static constexpr uint4 S23 = 14;
        static constexpr uint4 S24 = 20;
        static constexpr uint4 S31 = 4;
        static constexpr uint4 S32 = 11;
        static constexpr uint4 S33 = 16;
        static constexpr uint4 S34 = 23;
        static constexpr uint4 S41 = 6;
        static constexpr uint4 S42 = 10;
        static constexpr uint4 S43 = 15;
        static constexpr uint4 S44 = 21;
    public:
        // default ctor, just initailize
        MD5()
        {
            init();
        }

        //////////////////////////////////////////////

        // nifty shortcut ctor, compute Hash_MD5 for string and finalize it right away
        MD5(const std::string& text)
        {
            init();
            update(text.c_str(), (size_type)text.length());
            finalize();
        }

        MD5(std::string_view text)
        {
            init();
            update(text.data(), (size_type)text.length());
            finalize();
        }

        //////////////////////////////

        // MD5 block update operation. Continues an Hash_MD5 message-digest
        // operation, processing another message block
        void update(const unsigned char input[], size_type length)
        {
            // compute number of bytes mod 64
            size_type index = count[0] / 8 % blocksize;

            // Update number of bits
            if ((count[0] += (length << 3)) < (length << 3))
                count[1]++;
            count[1] += (length >> 29);

            // number of bytes we need to fill in buffer
            size_type firstpart = 64 - index;

            size_type i;

            // transform as many times as possible.
            if (length >= firstpart)
            {
                // fill buffer first, transform
                memcpy(&buffer[index], input, firstpart);
                transform(buffer);

                // transform chunks of blocksize (64 bytes)
                for (i = firstpart; i + blocksize <= length; i += blocksize)
                    transform(&input[i]);

                index = 0;
            }
            else
                i = 0;

            // buffer remaining input
            memcpy(&buffer[index], &input[i], length - i);
        }

        //////////////////////////////

        // for convenience provide a verson with signed char
        void update(const char input[], size_type length)
        {
            update((const unsigned char*)input, length);
        }

        //////////////////////////////

        // MD5 finalization. Ends an MD5 message-digest operation, writing the
        // the message digest and zeroizing the context.
        MD5& finalize()
        {
            static unsigned char padding[64] = {
              0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            };

            if (!finalized) {
                // Save number of bits
                unsigned char bits[8];
                encode(bits, count, 8);

                // pad out to 56 mod 64.
                size_type index = count[0] / 8 % 64;
                size_type padLen = (index < 56) ? (56 - index) : (120 - index);
                update(padding, padLen);

                // Append length (before padding)
                update(bits, 8);

                // Store state in digest
                encode(digest, state, 16);

                // Zeroize sensitive information.
                memset(buffer, 0, sizeof buffer);
                memset(count, 0, sizeof count);

                finalized = true;
            }

            return *this;
        }

        //////////////////////////////

        // return hex representation of digest as string
        std::string hexdigest() const
        {
            if (!finalized)
                return "";

            char buf[33];
            for (int i = 0; i < 16; i++)
                sprintf(buf + i * 2, "%02x", digest[i]);
            buf[32] = 0;

            return std::string(buf);
        }

        friend std::ostream& operator<<(std::ostream&, const MD5& md5);
    private:
        void init()
        {
            finalized = false;

            count[0] = 0;
            count[1] = 0;

            // load magic initialization constants.
            state[0] = 0x67452301;
            state[1] = 0xefcdab89;
            state[2] = 0x98badcfe;
            state[3] = 0x10325476;
        }

        //////////////////////////////

        // apply MD5 algo on a block
        void transform(const uint1 block[blocksize])
        {
            uint4 a = state[0], b = state[1], c = state[2], d = state[3], x[16];
            decode(x, block, blocksize);

            /* Round 1 */
            FF(a, b, c, d, x[0], S11, 0xd76aa478); /* 1 */
            FF(d, a, b, c, x[1], S12, 0xe8c7b756); /* 2 */
            FF(c, d, a, b, x[2], S13, 0x242070db); /* 3 */
            FF(b, c, d, a, x[3], S14, 0xc1bdceee); /* 4 */
            FF(a, b, c, d, x[4], S11, 0xf57c0faf); /* 5 */
            FF(d, a, b, c, x[5], S12, 0x4787c62a); /* 6 */
            FF(c, d, a, b, x[6], S13, 0xa8304613); /* 7 */
            FF(b, c, d, a, x[7], S14, 0xfd469501); /* 8 */
            FF(a, b, c, d, x[8], S11, 0x698098d8); /* 9 */
            FF(d, a, b, c, x[9], S12, 0x8b44f7af); /* 10 */
            FF(c, d, a, b, x[10], S13, 0xffff5bb1); /* 11 */
            FF(b, c, d, a, x[11], S14, 0x895cd7be); /* 12 */
            FF(a, b, c, d, x[12], S11, 0x6b901122); /* 13 */
            FF(d, a, b, c, x[13], S12, 0xfd987193); /* 14 */
            FF(c, d, a, b, x[14], S13, 0xa679438e); /* 15 */
            FF(b, c, d, a, x[15], S14, 0x49b40821); /* 16 */

            /* Round 2 */
            GG(a, b, c, d, x[1], S21, 0xf61e2562); /* 17 */
            GG(d, a, b, c, x[6], S22, 0xc040b340); /* 18 */
            GG(c, d, a, b, x[11], S23, 0x265e5a51); /* 19 */
            GG(b, c, d, a, x[0], S24, 0xe9b6c7aa); /* 20 */
            GG(a, b, c, d, x[5], S21, 0xd62f105d); /* 21 */
            GG(d, a, b, c, x[10], S22, 0x2441453); /* 22 */
            GG(c, d, a, b, x[15], S23, 0xd8a1e681); /* 23 */
            GG(b, c, d, a, x[4], S24, 0xe7d3fbc8); /* 24 */
            GG(a, b, c, d, x[9], S21, 0x21e1cde6); /* 25 */
            GG(d, a, b, c, x[14], S22, 0xc33707d6); /* 26 */
            GG(c, d, a, b, x[3], S23, 0xf4d50d87); /* 27 */
            GG(b, c, d, a, x[8], S24, 0x455a14ed); /* 28 */
            GG(a, b, c, d, x[13], S21, 0xa9e3e905); /* 29 */
            GG(d, a, b, c, x[2], S22, 0xfcefa3f8); /* 30 */
            GG(c, d, a, b, x[7], S23, 0x676f02d9); /* 31 */
            GG(b, c, d, a, x[12], S24, 0x8d2a4c8a); /* 32 */

            /* Round 3 */
            HH(a, b, c, d, x[5], S31, 0xfffa3942); /* 33 */
            HH(d, a, b, c, x[8], S32, 0x8771f681); /* 34 */
            HH(c, d, a, b, x[11], S33, 0x6d9d6122); /* 35 */
            HH(b, c, d, a, x[14], S34, 0xfde5380c); /* 36 */
            HH(a, b, c, d, x[1], S31, 0xa4beea44); /* 37 */
            HH(d, a, b, c, x[4], S32, 0x4bdecfa9); /* 38 */
            HH(c, d, a, b, x[7], S33, 0xf6bb4b60); /* 39 */
            HH(b, c, d, a, x[10], S34, 0xbebfbc70); /* 40 */
            HH(a, b, c, d, x[13], S31, 0x289b7ec6); /* 41 */
            HH(d, a, b, c, x[0], S32, 0xeaa127fa); /* 42 */
            HH(c, d, a, b, x[3], S33, 0xd4ef3085); /* 43 */
            HH(b, c, d, a, x[6], S34, 0x4881d05); /* 44 */
            HH(a, b, c, d, x[9], S31, 0xd9d4d039); /* 45 */
            HH(d, a, b, c, x[12], S32, 0xe6db99e5); /* 46 */
            HH(c, d, a, b, x[15], S33, 0x1fa27cf8); /* 47 */
            HH(b, c, d, a, x[2], S34, 0xc4ac5665); /* 48 */

            /* Round 4 */
            II(a, b, c, d, x[0], S41, 0xf4292244); /* 49 */
            II(d, a, b, c, x[7], S42, 0x432aff97); /* 50 */
            II(c, d, a, b, x[14], S43, 0xab9423a7); /* 51 */
            II(b, c, d, a, x[5], S44, 0xfc93a039); /* 52 */
            II(a, b, c, d, x[12], S41, 0x655b59c3); /* 53 */
            II(d, a, b, c, x[3], S42, 0x8f0ccc92); /* 54 */
            II(c, d, a, b, x[10], S43, 0xffeff47d); /* 55 */
            II(b, c, d, a, x[1], S44, 0x85845dd1); /* 56 */
            II(a, b, c, d, x[8], S41, 0x6fa87e4f); /* 57 */
            II(d, a, b, c, x[15], S42, 0xfe2ce6e0); /* 58 */
            II(c, d, a, b, x[6], S43, 0xa3014314); /* 59 */
            II(b, c, d, a, x[13], S44, 0x4e0811a1); /* 60 */
            II(a, b, c, d, x[4], S41, 0xf7537e82); /* 61 */
            II(d, a, b, c, x[11], S42, 0xbd3af235); /* 62 */
            II(c, d, a, b, x[2], S43, 0x2ad7d2bb); /* 63 */
            II(b, c, d, a, x[9], S44, 0xeb86d391); /* 64 */

            state[0] += a;
            state[1] += b;
            state[2] += c;
            state[3] += d;

            // Zeroize sensitive information.
            memset(x, 0, sizeof x);
        }

        //////////////////////////////

        // decodes input (unsigned char) into output (uint4). Assumes len is a multiple of 4.
        static void decode(uint4 output[], const uint1 input[], size_type len)
        {
            for (unsigned int i = 0, j = 0; j < len; i++, j += 4)
                output[i] = ((uint4)input[j]) | (((uint4)input[j + 1]) << 8) |
                (((uint4)input[j + 2]) << 16) | (((uint4)input[j + 3]) << 24);
        }

        //////////////////////////////

        // encodes input (uint4) into output (unsigned char). Assumes len is
        // a multiple of 4.
        static void encode(uint1 output[], const uint4 input[], size_type len)
        {
            for (size_type i = 0, j = 0; j < len; i++, j += 4) {
                output[j] = input[i] & 0xff;
                output[j + 1] = (input[i] >> 8) & 0xff;
                output[j + 2] = (input[i] >> 16) & 0xff;
                output[j + 3] = (input[i] >> 24) & 0xff;
            }
        }

        //////////////////////////////

        // low level logic operations
        ///////////////////////////////////////////////
        // F, G, H and I are basic Hash_MD5 functions.
        static inline uint4 F(uint4 x, uint4 y, uint4 z) {
            return x & y | ~x & z;
        }

        static inline uint4 G(uint4 x, uint4 y, uint4 z) {
            return x & z | y & ~z;
        }

        static inline uint4 H(uint4 x, uint4 y, uint4 z) {
            return x ^ y ^ z;
        }

        static inline uint4 I(uint4 x, uint4 y, uint4 z) {
            return y ^ (x | ~z);
        }

        // rotate_left rotates x left n bits.
        static inline uint4 rotate_left(uint4 x, int n) {
            return (x << n) | (x >> (32 - n));
        }


        // FF, GG, HH, and II transformations for rounds 1, 2, 3, and 4.
        // Rotation is separate from addition to prevent recomputation.
        static inline void FF(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + F(b, c, d) + x + ac, s) + b;
        }

        static inline void GG(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + G(b, c, d) + x + ac, s) + b;
        }

        static inline void HH(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + H(b, c, d) + x + ac, s) + b;
        }

        static inline void II(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + I(b, c, d) + x + ac, s) + b;
        }

        //////////////////////////////////////////////
    };

    inline std::ostream& operator<<(std::ostream& out, const MD5& md5)
    {
        return out << md5.hexdigest();
    }

    //////////////////////////////

    inline std::string md5(std::string_view str)
    {
        MD5 md5 = MD5(str);
        return md5.hexdigest();
    }

    namespace File
    {
        inline std::string md5(const char* path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::md5(Util::LoadFile(path, flag));
        }

        inline std::string md5(std::string_view path, std::ios::openmode flag = std::ios::binary)
        {
            return Hash::md5(Util::LoadFile(path.data(), flag));
        }
    }
    //=============================================================================
#endif // HASH_ENABLE_MD5
} // namespace Hash


#if HASH_ENABLE_KECCAK == 1
    //=============================================================================
    // source: https://github.com/XKCP/XKCP/blob/master/Standalone/CompactFIPS202/C/Keccak-readable-and-compact.c
    /*
    Implementation by the Keccak Team, namely, Guido Bertoni, Joan Daemen,
    Michaël Peeters, Gilles Van Assche and Ronny Van Keer,
    hereby denoted as "the implementer".

    For more information, feedback or questions, please refer to our website:
    https://keccak.team/

    To the extent possible under law, the implementer has waived all copyright
    and related or neighboring rights to the source code in this file.
    http://creativecommons.org/publicdomain/zero/1.0/
    */

    /*
    ================================================================
    The purpose of this source file is to demonstrate a readable and compact
    implementation of all the Keccak instances approved in the FIPS 202 standard,
    including the hash functions and the extendable-output functions (XOFs).

    We focused on clarity and on source-code compactness,
    rather than on the performance.

    The advantages of this implementation are:
        + The source code is compact, after removing the comments, that is. :-)
        + There are no tables with arbitrary constants.
        + For clarity, the comments link the operations to the specifications using
            the same notation as much as possible.
        + There is no restriction in cryptographic features. In particular,
            the SHAKE128 and SHAKE256 XOFs can produce any output length.
        + The code does not use much RAM, as all operations are done in place.

    The drawbacks of this implementation are:
        - There is no message queue. The whole message must be ready in a buffer.
        - It is not optimized for performance.

    The implementation is even simpler on a little endian platform. Just define the
    HASH_KECCAK_LITTLE_ENDIAN symbol in that case.

    For a more complete set of implementations, please refer to
    the Keccak Code Package at https://github.com/gvanas/KeccakCodePackage

    For more information, please refer to:
        * [Keccak Reference] https://keccak.team/files/Keccak-reference-3.0.pdf
        * [Keccak Specifications Summary] https://keccak.team/keccak_specs_summary.html

    This file uses UTF-8 encoding, as some comments use Greek letters.
    ================================================================
    */

    /**
      * Function to compute the Keccak[r, c] sponge function over a given input.
      * @param  rate            The value of the rate r.
      * @param  capacity        The value of the capacity c.
      * @param  input           Pointer to the input message.
      * @param  inputByteLen    The number of input bytes provided in the input message.
      * @param  delimitedSuffix Bits that will be automatically appended to the end
      *                         of the input message, as in domain separation.
      *                         This is a byte containing from 0 to 7 bits
      *                         These <i>n</i> bits must be in the least significant bit positions
      *                         and must be delimited with a bit 1 at position <i>n</i>
      *                         (counting from 0=LSB to 7=MSB) and followed by bits 0
      *                         from position <i>n</i>+1 to position 7.
      *                         Some examples:
      *                             - If no bits are to be appended, then @a delimitedSuffix must be 0x01.
      *                             - If the 2-bit sequence 0,1 is to be appended (as for SHA3-*), @a delimitedSuffix must be 0x06.
      *                             - If the 4-bit sequence 1,1,1,1 is to be appended (as for SHAKE*), @a delimitedSuffix must be 0x1F.
      *                             - If the 7-bit sequence 1,1,0,1,0,0,0 is to be absorbed, @a delimitedSuffix must be 0x8B.
      * @param  output          Pointer to the buffer where to store the output.
      * @param  outputByteLen   The number of output bytes desired.
      * @pre    One must have r+c=1600 and the rate a multiple of 8 bits in this implementation.
      */
inline void hash_private_keccak_Keccak(unsigned int rate, unsigned int capacity, const unsigned char* input, unsigned long long int inputByteLen, unsigned char delimitedSuffix, unsigned char* output, unsigned long long int outputByteLen);

namespace Hash
{
    inline std::string shake128(const unsigned char* data, size_t size, size_t outsizeBytes)
    {
        std::string buff(outsizeBytes / 2, ' ');
        hash_private_keccak_Keccak(1344, 256, data, size, 0x1F, (unsigned char*)buff.data(), outsizeBytes / 2);
        return Util::CharArrayToHexString((unsigned char*)buff.data(), outsizeBytes / 2);
    }


    inline std::string shake256(const unsigned char* data, size_t size, size_t outsizeBytes)
    {
        std::string buff(outsizeBytes / 2, ' ');
        hash_private_keccak_Keccak(1088, 512, data, size, 0x1F, (unsigned char*)buff.data(), outsizeBytes / 2);
        return Util::CharArrayToHexString((unsigned char*)buff.data(), outsizeBytes / 2);
    }

    inline std::string shake128(const char* data, size_t size, size_t outsizeBytes) { return shake128((const unsigned char*)data, size, outsizeBytes); }
    inline std::string shake256(const char* data, size_t size, size_t outsizeBytes) { return shake256((const unsigned char*)data, size, outsizeBytes); }
    inline std::string shake128(std::string_view data, size_t outsizeBytes) { return shake128(data.data(), data.size(), outsizeBytes); }
    inline std::string shake256(std::string_view data, size_t outsizeBytes) { return shake256(data.data(), data.size(), outsizeBytes); }


    template <size_t outsizeBytes> inline std::string shake128(const unsigned char* data, size_t size)
    {
        static_assert(outsizeBytes > 0, "outsizeBytes must be greater than 0!");
        unsigned char buff[outsizeBytes / 2];
        hash_private_keccak_Keccak(1344, 256, data, size, 0x1F, buff, outsizeBytes / 2);
        return Util::CharArrayToHexString(buff, outsizeBytes / 2);
    }


    template <size_t outsizeBytes> inline std::string shake256(const unsigned char* data, size_t size)
    {
        static_assert(outsizeBytes > 0, "outsizeBytes must be greater than 0!");
        unsigned char buff[outsizeBytes / 2];
        hash_private_keccak_Keccak(1088, 512, data, size, 0x1F, buff, outsizeBytes / 2);
        return Util::CharArrayToHexString(buff, outsizeBytes / 2);
    }

    template <size_t outsizeBytes> inline std::string shake128(const char* data, size_t size) { return shake128<outsizeBytes>((const unsigned char*)data, size); }
    template <size_t outsizeBytes> inline std::string shake256(const char* data, size_t size) { return shake256<outsizeBytes>((const unsigned char*)data, size); }
    template <size_t outsizeBytes> inline std::string shake128(std::string_view data) { return shake128<outsizeBytes>(data.data(), data.size()); }
    template <size_t outsizeBytes> inline std::string shake256(std::string_view data) { return shake256<outsizeBytes>(data.data(), data.size()); }


    namespace File
    {
        inline std::string shake128(const char* path,      size_t outsizeBytes, std::ios::openmode flag = std::ios::binary) { return Hash::shake128(Util::LoadFile(path, flag),        outsizeBytes); }
        inline std::string shake128(std::string_view path, size_t outsizeBytes, std::ios::openmode flag = std::ios::binary) { return Hash::shake128(Util::LoadFile(path.data(), flag), outsizeBytes); }
        inline std::string shake256(const char* path,      size_t outsizeBytes, std::ios::openmode flag = std::ios::binary) { return Hash::shake256(Util::LoadFile(path, flag),        outsizeBytes); }
        inline std::string shake256(std::string_view path, size_t outsizeBytes, std::ios::openmode flag = std::ios::binary) { return Hash::shake256(Util::LoadFile(path.data(), flag), outsizeBytes); }

        template <size_t outsizeBytes> inline std::string shake128(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::shake128<outsizeBytes>(Util::LoadFile(path,        flag)); }
        template <size_t outsizeBytes> inline std::string shake128(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::shake128<outsizeBytes>(Util::LoadFile(path.data(), flag)); }
        template <size_t outsizeBytes> inline std::string shake256(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::shake256<outsizeBytes>(Util::LoadFile(path,        flag)); }
        template <size_t outsizeBytes> inline std::string shake256(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::shake256<outsizeBytes>(Util::LoadFile(path.data(), flag)); }
    }




    inline std::string sha3_224(const unsigned char* data, size_t size)
    {
        unsigned char buff[28];
        hash_private_keccak_Keccak(1152, 448, data, size, 0x06, buff, 28);
        return Util::CharArrayToHexString(buff, 28);
    }

    inline std::string sha3_256(const unsigned char* data, size_t size)
    {
        unsigned char buff[32];
        hash_private_keccak_Keccak(1088, 512, data, size, 0x06, buff, 32);
        return Util::CharArrayToHexString(buff, 32);
    }

    inline std::string sha3_384(const unsigned char* data, size_t size)
    {
        unsigned char buff[48];
        hash_private_keccak_Keccak(832, 768, data, size, 0x06, buff, 48);
        return Util::CharArrayToHexString(buff, 48);
    }

    inline std::string sha3_512(const unsigned char* data, size_t size)
    {
        unsigned char buff[64];
        hash_private_keccak_Keccak(576, 1024, data, size, 0x06, buff, 64);
        return Util::CharArrayToHexString(buff, 64);
    }

    inline std::string sha3_224(const char* data, size_t size) { return sha3_224((const unsigned char*)data, size); }
    inline std::string sha3_256(const char* data, size_t size) { return sha3_256((const unsigned char*)data, size); }
    inline std::string sha3_384(const char* data, size_t size) { return sha3_384((const unsigned char*)data, size); }
    inline std::string sha3_512(const char* data, size_t size) { return sha3_512((const unsigned char*)data, size); }

    inline std::string sha3_224(std::string_view data) { return sha3_224(data.data(), data.size()); }
    inline std::string sha3_256(std::string_view data) { return sha3_256(data.data(), data.size()); }
    inline std::string sha3_384(std::string_view data) { return sha3_384(data.data(), data.size()); }
    inline std::string sha3_512(std::string_view data) { return sha3_512(data.data(), data.size()); }


    namespace File
    {
        inline std::string sha3_224(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::sha3_224(Util::LoadFile(path,        flag)); }
        inline std::string sha3_224(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha3_224(Util::LoadFile(path.data(), flag)); }
        inline std::string sha3_256(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::sha3_256(Util::LoadFile(path,        flag)); }
        inline std::string sha3_256(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha3_256(Util::LoadFile(path.data(), flag)); }
        inline std::string sha3_384(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::sha3_384(Util::LoadFile(path,        flag)); }
        inline std::string sha3_384(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha3_384(Util::LoadFile(path.data(), flag)); }
        inline std::string sha3_512(const char* path,      std::ios::openmode flag = std::ios::binary) { return Hash::sha3_512(Util::LoadFile(path,        flag)); }
        inline std::string sha3_512(std::string_view path, std::ios::openmode flag = std::ios::binary) { return Hash::sha3_512(Util::LoadFile(path.data(), flag)); }
    }
}
#endif // HASH_ENABLE_KECCAK
#endif // __cplusplus
#if HASH_ENABLE_KECCAK == 1
#if HASH_ENABLE_C_FUNCTIONS == 1
HASH_INLINE void hash_private_keccak_Keccak(unsigned int rate, unsigned int capacity, const unsigned char* input, unsigned long long int inputByteLen, unsigned char delimitedSuffix, unsigned char* output, unsigned long long int outputByteLen);

// heap allocated if outsizeBytes > HASH_SHAKE_128_MALLOC_LIMIT
HASH_INLINE const char* hash_shake128_binary(const char* data, size_t size, size_t outsizeBytes, char* buffer /*outsizeBytes+1*/)
{
    static char hex[HASH_SHAKE_128_MALLOC_LIMIT + 1];
    static unsigned char intBuff[HASH_SHAKE_128_MALLOC_LIMIT / 2];
    char* out = buffer;
    unsigned char* buff = intBuff;

    if (buffer == NULL)
    {
        if (outsizeBytes > HASH_SHAKE_128_MALLOC_LIMIT)
        {
            char* tmp = (char*)malloc(outsizeBytes * 3 + 1);
            buff = (unsigned char*)tmp;
            out = &tmp[outsizeBytes];
        }
        else
            out = hex;
    }

    hash_private_keccak_Keccak(1344, 256, (const unsigned char*)data, size, 0x1F, buff, outsizeBytes / 2);
    hash_util_char_array_to_hex_string(buff, outsizeBytes / 2, out);
    return out;
}

// heap allocated if outsizeBytes > HASH_SHAKE_256_MALLOC_LIMIT
HASH_INLINE const char* hash_shake256_binary(const char* data, size_t size, size_t outsizeBytes, char* buffer /*outsizeBytes+1*/)
{
    static char hex[HASH_SHAKE_256_MALLOC_LIMIT + 1];
    static unsigned char intBuff[HASH_SHAKE_256_MALLOC_LIMIT / 2];
    char* out = buffer;
    unsigned char* buff = intBuff;

    if (buffer == NULL)
    {
        if (outsizeBytes > HASH_SHAKE_256_MALLOC_LIMIT)
        {
            char* tmp = (char*)malloc(outsizeBytes * 3 + 1);
            buff = (unsigned char*)tmp;
            out = &tmp[outsizeBytes];
        }
        else
            out = hex;
    }

    hash_private_keccak_Keccak(1088, 512, (const unsigned char*)data, size, 0x1F, buff, outsizeBytes / 2);
    hash_util_char_array_to_hex_string(buff, outsizeBytes / 2, out);
    return out;
}

HASH_INLINE const char* hash_shake128(const char* data, size_t outsizeBytes, char* buffer) { return hash_shake128_binary(data, strlen(data), outsizeBytes, buffer); }
HASH_INLINE const char* hash_shake256(const char* data, size_t outsizeBytes, char* buffer) { return hash_shake256_binary(data, strlen(data), outsizeBytes, buffer); }

HASH_INLINE const char* hash_shake128_easy(const char* data, size_t outsizeBytes) { return hash_shake128_binary(data, strlen(data), outsizeBytes, NULL); }
HASH_INLINE const char* hash_shake256_easy(const char* data, size_t outsizeBytes) { return hash_shake256_binary(data, strlen(data), outsizeBytes, NULL); }

HASH_INLINE const char* hash_shake128_file(const char* path, const char* mode, size_t outsizeBytes, char* buffer)
{
    long fsize;
    char* content = hash_util_load_file(path, mode, &fsize);
    if (content == NULL) return "";
    const char* hash = hash_shake128_binary(content, fsize, outsizeBytes, buffer);
    if (content != NULL)
        free(content);
    return hash;
}

HASH_INLINE const char* hash_shake256_file(const char* path, const char* mode, size_t outsizeBytes, char* buffer)
{
    long fsize;
    char* content = hash_util_load_file(path, mode, &fsize);
    if (content == NULL) return "";
    const char* hash = hash_shake256_binary(content, fsize, outsizeBytes, buffer);
    if (content != NULL)
        free(content);
    return hash;
}

HASH_INLINE const char* hash_shake128_file_easy(const char* path, const char* mode, size_t outsizeBytes) { return hash_shake128_file(path, mode, outsizeBytes, NULL); }
HASH_INLINE const char* hash_shake256_file_easy(const char* path, const char* mode, size_t outsizeBytes) { return hash_shake256_file(path, mode, outsizeBytes, NULL); }




HASH_INLINE const char* hash_sha3_224_binary(const char* data, size_t size, char* buffer /*57 chars*/)
{
    static char hex[57];
    static unsigned char buff[28];
    char* out = buffer == NULL ? hex : buffer;
    hash_private_keccak_Keccak(1152, 448, (const unsigned char*)data, size, 0x06, buff, 28);
    hash_util_char_array_to_hex_string(buff, 28, out);
    return out;
}

HASH_INLINE const char* hash_sha3_256_binary(const char* data, size_t size, char* buffer /*65 chars*/)
{
    static char hex[65];
    static unsigned char buff[32];
    char* out = buffer == NULL ? hex : buffer;
    hash_private_keccak_Keccak(1088, 512, (const unsigned char*)data, size, 0x06, buff, 32);
    hash_util_char_array_to_hex_string(buff, 32, out);
    return out;
}

HASH_INLINE const char* hash_sha3_384_binary(const char* data, size_t size, char* buffer /*97 chars*/)
{
    static char hex[97];
    static unsigned char buff[48];
    char* out = buffer == NULL ? hex : buffer;
    hash_private_keccak_Keccak(832, 768, (const unsigned char*)data, size, 0x06, buff, 48);
    hash_util_char_array_to_hex_string(buff, 48, out);
    return out;
}

HASH_INLINE const char* hash_sha3_512_binary(const char* data, size_t size, char* buffer /*129 chars*/)
{
    static char hex[129];
    static unsigned char buff[64];
    char* out = buffer == NULL ? hex : buffer;
    hash_private_keccak_Keccak(576, 1024, (const unsigned char*)data, size, 0x06, buff, 64);
    hash_util_char_array_to_hex_string(buff, 64, out);
    return out;
}

HASH_INLINE const char* hash_sha3_224(const char* data, char* buffer) { return hash_sha3_224_binary(data, strlen(data), buffer); }
HASH_INLINE const char* hash_sha3_256(const char* data, char* buffer) { return hash_sha3_256_binary(data, strlen(data), buffer); }
HASH_INLINE const char* hash_sha3_384(const char* data, char* buffer) { return hash_sha3_384_binary(data, strlen(data), buffer); }
HASH_INLINE const char* hash_sha3_512(const char* data, char* buffer) { return hash_sha3_512_binary(data, strlen(data), buffer); }

HASH_INLINE const char* hash_sha3_224_easy(const char* data) { return hash_sha3_224_binary(data, strlen(data), NULL); }
HASH_INLINE const char* hash_sha3_256_easy(const char* data) { return hash_sha3_256_binary(data, strlen(data), NULL); }
HASH_INLINE const char* hash_sha3_384_easy(const char* data) { return hash_sha3_384_binary(data, strlen(data), NULL); }
HASH_INLINE const char* hash_sha3_512_easy(const char* data) { return hash_sha3_512_binary(data, strlen(data), NULL); }

HASH_INLINE const char* hash_sha3_224_file(const char* path, const char* mode, char* buffer) { return hash_util_hash_file(path, mode, hash_sha3_224_binary, buffer); }
HASH_INLINE const char* hash_sha3_256_file(const char* path, const char* mode, char* buffer) { return hash_util_hash_file(path, mode, hash_sha3_256_binary, buffer); }
HASH_INLINE const char* hash_sha3_384_file(const char* path, const char* mode, char* buffer) { return hash_util_hash_file(path, mode, hash_sha3_384_binary, buffer); }
HASH_INLINE const char* hash_sha3_512_file(const char* path, const char* mode, char* buffer) { return hash_util_hash_file(path, mode, hash_sha3_512_binary, buffer); }

HASH_INLINE const char* hash_sha3_224_file_easy(const char* path, const char* mode) { return hash_util_hash_file(path, mode, hash_sha3_224_binary, NULL); }
HASH_INLINE const char* hash_sha3_256_file_easy(const char* path, const char* mode) { return hash_util_hash_file(path, mode, hash_sha3_256_binary, NULL); }
HASH_INLINE const char* hash_sha3_384_file_easy(const char* path, const char* mode) { return hash_util_hash_file(path, mode, hash_sha3_384_binary, NULL); }
HASH_INLINE const char* hash_sha3_512_file_easy(const char* path, const char* mode) { return hash_util_hash_file(path, mode, hash_sha3_512_binary, NULL); }
#endif // HASH_ENABLE_C_FUNCTIONS

/*
================================================================
Technicalities
================================================================
*/

#if HASH_KECCAK_LITTLE_ENDIAN != 1
/** Function to load a 64-bit value using the little-endian (LE) convention.
  * On a LE platform, this could be greatly simplified using a cast.
  */
HASH_INLINE uint64_t hash_private_keccak_load64(const uint8_t* x)
{
    int i;
    uint64_t u = 0;

    for (i = 7; i >= 0; --i) {
        u <<= 8;
        u |= x[i];
    }
    return u;
}

/** Function to store a 64-bit value using the little-endian (LE) convention.
  * On a LE platform, this could be greatly simplified using a cast.
  */
HASH_INLINE void hash_private_keccak_store64(uint8_t* x, uint64_t u)
{
    unsigned int i;

    for (i = 0; i < 8; ++i) {
        x[i] = (uint8_t)u;
        u >>= 8;
    }
}

/** Function to XOR into a 64-bit value using the little-endian (LE) convention.
  * On a LE platform, this could be greatly simplified using a cast.
  */
HASH_INLINE void hash_private_keccak_xor64(uint8_t* x, uint64_t u)
{
    unsigned int i;

    for (i = 0; i < 8; ++i) {
        x[i] ^= u;
        u >>= 8;
    }
}
#endif



#define HASH_PRIVATE_KECCAK_ROL64(a, offset) ((((uint64_t)a) << offset) ^ (((uint64_t)a) >> (64-offset)))
#define HASH_PRIVATE_KECCAK_I(x, y) ((x)+5*(y))

#if HASH_KECCAK_LITTLE_ENDIAN == 1
#define HASH_PRIVATE_KECCAK_READLANE(x, y)          (((uint64_t*)state)[HASH_PRIVATE_KECCAK_I(x, y)])
#define hash_private_keccak_WRITELANE(x, y, lane)   (((uint64_t*)state)[HASH_PRIVATE_KECCAK_I(x, y)]) = (lane)
#define hash_private_keccak_XORLANE(x, y, lane)     (((uint64_t*)state)[HASH_PRIVATE_KECCAK_I(x, y)]) ^= (lane)
#else
#define HASH_PRIVATE_KECCAK_READLANE(x, y)          hash_private_keccak_load64((uint8_t*)state+sizeof(uint64_t)*HASH_PRIVATE_KECCAK_I(x, y))
#define hash_private_keccak_WRITELANE(x, y, lane)   hash_private_keccak_store64((uint8_t*)state+sizeof(uint64_t)*HASH_PRIVATE_KECCAK_I(x, y), lane)
#define hash_private_keccak_XORLANE(x, y, lane)     hash_private_keccak_xor64((uint8_t*)state+sizeof(uint64_t)*HASH_PRIVATE_KECCAK_I(x, y), lane)
#endif

/**
  * Function that computes the linear feedback shift register (LFSR) used to
  * define the round constants (see [Keccak Reference, Section 1.2]).
  */
HASH_INLINE int hash_private_keccak_LFSR86540(uint8_t* LFSR)
{
    int result = ((*LFSR) & 0x01) != 0;
    if (((*LFSR) & 0x80) != 0)
        /* Primitive polynomial over GF(2): x^8+x^6+x^5+x^4+1 */
        (*LFSR) = ((*LFSR) << 1) ^ 0x71;
    else
        (*LFSR) <<= 1;
    return result;
}

/**
 * Function that computes the Keccak-f[1600] permutation on the given state.
 */
HASH_INLINE void hash_private_keccak_KeccakF1600_StatePermute(void* state)
{
    unsigned int round, x, y, j, t;
    uint8_t LFSRstate = 0x01;

    for (round = 0; round < 24; round++) {
        {   /* === θ step (see [Keccak Reference, Section 2.3.2]) === */
            uint64_t C[5], D;

            /* Compute the parity of the columns */
            for (x = 0; x < 5; x++)
                C[x] = HASH_PRIVATE_KECCAK_READLANE(x, 0) ^ HASH_PRIVATE_KECCAK_READLANE(x, 1) ^ HASH_PRIVATE_KECCAK_READLANE(x, 2) ^ HASH_PRIVATE_KECCAK_READLANE(x, 3) ^ HASH_PRIVATE_KECCAK_READLANE(x, 4);
            for (x = 0; x < 5; x++) {
                /* Compute the θ effect for a given column */
                D = C[(x + 4) % 5] ^ HASH_PRIVATE_KECCAK_ROL64(C[(x + 1) % 5], 1);
                /* Add the θ effect to the whole column */
                for (y = 0; y < 5; y++)
                    hash_private_keccak_XORLANE(x, y, D);
            }
        }

        {   /* === ρ and π steps (see [Keccak Reference, Sections 2.3.3 and 2.3.4]) === */
            uint64_t current, temp;
            /* Start at coordinates (1 0) */
            x = 1; y = 0;
            current = HASH_PRIVATE_KECCAK_READLANE(x, y);
            /* Iterate over ((0 1)(2 3))^t * (1 0) for 0 ≤ t ≤ 23 */
            for (t = 0; t < 24; t++) {
                /* Compute the rotation constant r = (t+1)(t+2)/2 */
                unsigned int r = ((t + 1) * (t + 2) / 2) % 64;
                /* Compute ((0 1)(2 3)) * (x y) */
                unsigned int Y = (2 * x + 3 * y) % 5; x = y; y = Y;
                /* Swap current and state(x,y), and rotate */
                temp = HASH_PRIVATE_KECCAK_READLANE(x, y);
                hash_private_keccak_WRITELANE(x, y, HASH_PRIVATE_KECCAK_ROL64(current, r));
                current = temp;
            }
        }

        {   /* === χ step (see [Keccak Reference, Section 2.3.1]) === */
            uint64_t temp[5];
            for (y = 0; y < 5; y++) {
                /* Take a copy of the plane */
                for (x = 0; x < 5; x++)
                    temp[x] = HASH_PRIVATE_KECCAK_READLANE(x, y);
                /* Compute χ on the plane */
                for (x = 0; x < 5; x++)
                    hash_private_keccak_WRITELANE(x, y, temp[x] ^ ((~temp[(x + 1) % 5]) & temp[(x + 2) % 5]));
            }
        }

        {   /* === ι step (see [Keccak Reference, Section 2.3.5]) === */
            for (j = 0; j < 7; j++) {
                unsigned int bitPosition = (1 << j) - 1; /* 2^j-1 */
                if (hash_private_keccak_LFSR86540(&LFSRstate))
                    hash_private_keccak_XORLANE(0, 0, (uint64_t)1 << bitPosition);
            }
        }
    }
}

/*
================================================================
A readable and compact implementation of the Keccak sponge functions
that use the Keccak-f[1600] permutation.
================================================================
*/

#define HASH_PRIVATE_KECCAK_MIN(a, b) ((a) < (b) ? (a) : (b))
HASH_INLINE void hash_private_keccak_Keccak(unsigned int rate, unsigned int capacity, const unsigned char* input, unsigned long long int inputByteLen, unsigned char delimitedSuffix, unsigned char* output, unsigned long long int outputByteLen)
{
    uint8_t state[200];
    unsigned int rateInBytes = rate / 8;
    unsigned int blockSize = 0;
    unsigned int i;

    if (((rate + capacity) != 1600) || ((rate % 8) != 0))
        return;

    /* === Initialize the state === */
    memset(state, 0, sizeof(state));

    /* === Absorb all the input blocks === */
    while (inputByteLen > 0) {
        blockSize = (unsigned int)HASH_PRIVATE_KECCAK_MIN(inputByteLen, rateInBytes);
        for (i = 0; i < blockSize; i++)
            state[i] ^= input[i];
        input += blockSize;
        inputByteLen -= blockSize;

        if (blockSize == rateInBytes) {
            hash_private_keccak_KeccakF1600_StatePermute(state);
            blockSize = 0;
        }
    }

    /* === Do the padding and switch to the squeezing phase === */
    /* Absorb the last few bits and add the first bit of padding (which coincides with the delimiter in delimitedSuffix) */
    state[blockSize] ^= delimitedSuffix;
    /* If the first bit of padding is at position rate-1, we need a whole new block for the second bit of padding */
    if (((delimitedSuffix & 0x80) != 0) && (blockSize == (rateInBytes - 1)))
        hash_private_keccak_KeccakF1600_StatePermute(state);
    /* Add the second bit of padding */
    state[rateInBytes - 1] ^= 0x80;
    /* Switch to the squeezing phase */
    hash_private_keccak_KeccakF1600_StatePermute(state);

    /* === Squeeze out all the output blocks === */
    while (outputByteLen > 0) {
        blockSize = (unsigned int)HASH_PRIVATE_KECCAK_MIN(outputByteLen, rateInBytes);
        memcpy(output, state, blockSize);
        output += blockSize;
        outputByteLen -= blockSize;

        if (outputByteLen > 0)
            hash_private_keccak_KeccakF1600_StatePermute(state);
    }
}
#undef HASH_PRIVATE_KECCAK_I
#undef HASH_PRIVATE_KECCAK_MIN
#undef HASH_PRIVATE_KECCAK_ROL64
#undef hash_private_keccak_XORLANE
#undef HASH_PRIVATE_KECCAK_READLANE
#undef hash_private_keccak_WRITELANE
//=============================================================================
#endif // HASH_ENABLE_KECCAK
#endif // HASH_H

#undef HASH_ENABLE_MD5
#undef HASH_ENABLE_SHA1
#undef HASH_ENABLE_SHA2
#undef HASH_ENABLE_KECCAK
#undef HASH_ENABLE_C_FUNCTIONS
#undef HASH_KECCAK_LITTLE_ENDIAN
#undef HASH_SHAKE_128_MALLOC_LIMIT
#undef HASH_SHAKE_256_MALLOC_LIMIT
#undef HASH_INLINE
#undef HASH_DEFINE_UTIL_SWAP_ENDIAN

#ifdef _MSC_VER
#pragma warning( pop ) // 4996
#endif