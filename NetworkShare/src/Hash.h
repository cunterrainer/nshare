#pragma once
#include <vector>
#include <string>
#include <locale>
#include <cstdio>
#include <climits>
#include <cstdint>
#include <cstring>
#include <codecvt>
#include <sstream>
#include <iomanip>
#include <type_traits>
#include <string_view>

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


        constexpr bool IsLittleEndian()
        {
            int32_t num = 1;
            return *(char*)&num == 1;
        }

        constexpr uint32_t RightRotate32(uint32_t n, unsigned int c)
        {
            const unsigned int mask = (CHAR_BIT * sizeof(n) - 1);
            c &= mask;
            return (n >> c) | (n << ((-c) & mask));
        }
    }


    class Sha256
    {
    private:
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
        inline std::vector<unsigned char> SplitIntoChunks(const std::string_view& str) const
        {
            std::vector<unsigned char> binRep(str.begin(), str.end());
            const uint8_t chunkBytesLeft = binRep.size() % 64;
            binRep.push_back(0b10000000);
            if (chunkBytesLeft >= 56)
            {
                for (size_t i = 0; i < 64 - chunkBytesLeft; ++i)
                    binRep.push_back(0);
            }

            // add padding bits
            while ((binRep.size() * 8) % 512 != 0)
                binRep.push_back(0);

            const uint64_t strSize = str.size() * 8;
            uint64_t* const end = (uint64_t*)&binRep.data()[binRep.size() - 8];
            *end = Util::IsLittleEndian() ? Util::SwapEndian(strSize) : strSize;
            return binRep;
        }


        inline void CreateMessageSchedule(uint32_t* const w) const
        {
            if (Util::IsLittleEndian())
            {
                for (size_t i = 0; i < 64; ++i)
                    w[i] = Util::SwapEndian(w[i]);
            }

            for (size_t i = 16; i < 64; ++i)
            {
                const uint32_t s0 = Util::RightRotate32(w[i - 15], 7) ^ Util::RightRotate32(w[i - 15], 18) ^ (w[i - 15] >> 3);
                const uint32_t s1 = Util::RightRotate32(w[i - 2], 17) ^ Util::RightRotate32(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            }
        }


        inline void Compression(const uint32_t* const w)
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
                const uint32_t s1 = Util::RightRotate32(e, 6) ^ Util::RightRotate32(e, 11) ^ Util::RightRotate32(e, 25);
                const uint32_t ch = (e & f) ^ (~e & g);
                const uint32_t temp1 = h + s1 + ch + s_K[i] + w[i];
                const uint32_t s0 = Util::RightRotate32(a, 2) ^ Util::RightRotate32(a, 13) ^ Util::RightRotate32(a, 22);
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
    public:
        inline std::string Generate(const std::string_view& str)
        {
            std::vector<unsigned char> binRep = SplitIntoChunks(str);
             
            uint32_t chunk[64] = {0};
            for (size_t i = 0; i < binRep.size() / 64; ++i)
            {
                std::memcpy(chunk, &binRep.data()[64*i], 64);
                CreateMessageSchedule(chunk);
                Compression(chunk);
            }

            std::stringstream stream;
            stream << std::hex << std::setfill('0') << std::setw(8) << m_H[0] << std::setw(8) << m_H[1] << std::setw(8) << m_H[2] << std::setw(8) << m_H[3] << std::setw(8)<< m_H[4] << std::setw(8) << m_H[5] << std::setw(8) << m_H[6] << std::setw(8) << m_H[7];
            return stream.str();
        }
    };


    // if you have any kind of unicode string, use the hash::encode functions beforehand for converting the string
    inline std::string sha256(std::string_view str)
    {
        Sha256 s256;
        return s256.Generate(str);
    }




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
        // Constants for MD5Transform routine.
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
        MD5::MD5()
        {
            init();
        }

        //////////////////////////////////////////////

        // nifty shortcut ctor, compute MD5 for string and finalize it right away
        MD5::MD5(const std::string& text)
        {
            init();
            update(text.c_str(), (size_type)text.length());
            finalize();
        }

        MD5::MD5(std::string_view text)
        {
            init();
            update(text.data(), (size_type)text.length());
            finalize();
        }

        //////////////////////////////

        // MD5 block update operation. Continues an MD5 message-digest
        // operation, processing another message block
        void MD5::update(const unsigned char input[], size_type length)
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
        void MD5::update(const char input[], size_type length)
        {
            update((const unsigned char*)input, length);
        }

        //////////////////////////////

        // MD5 finalization. Ends an MD5 message-digest operation, writing the
        // the message digest and zeroizing the context.
        MD5& MD5::finalize()
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
        std::string MD5::hexdigest() const
        {
            if (!finalized)
                return "";

            char buf[33];
            for (int i = 0; i < 16; i++)
                sprintf(buf + i * 2, "%02x", digest[i]);
            buf[32] = 0;

            return std::string(buf);
        }

        friend std::ostream& operator<<(std::ostream&, MD5 md5);
    private:
        void MD5::init()
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
        void MD5::transform(const uint1 block[blocksize])
        {
          uint4 a = state[0], b = state[1], c = state[2], d = state[3], x[16];
          decode (x, block, blocksize);
 
          /* Round 1 */
          FF (a, b, c, d, x[ 0], S11, 0xd76aa478); /* 1 */
          FF (d, a, b, c, x[ 1], S12, 0xe8c7b756); /* 2 */
          FF (c, d, a, b, x[ 2], S13, 0x242070db); /* 3 */
          FF (b, c, d, a, x[ 3], S14, 0xc1bdceee); /* 4 */
          FF (a, b, c, d, x[ 4], S11, 0xf57c0faf); /* 5 */
          FF (d, a, b, c, x[ 5], S12, 0x4787c62a); /* 6 */
          FF (c, d, a, b, x[ 6], S13, 0xa8304613); /* 7 */
          FF (b, c, d, a, x[ 7], S14, 0xfd469501); /* 8 */
          FF (a, b, c, d, x[ 8], S11, 0x698098d8); /* 9 */
          FF (d, a, b, c, x[ 9], S12, 0x8b44f7af); /* 10 */
          FF (c, d, a, b, x[10], S13, 0xffff5bb1); /* 11 */
          FF (b, c, d, a, x[11], S14, 0x895cd7be); /* 12 */
          FF (a, b, c, d, x[12], S11, 0x6b901122); /* 13 */
          FF (d, a, b, c, x[13], S12, 0xfd987193); /* 14 */
          FF (c, d, a, b, x[14], S13, 0xa679438e); /* 15 */
          FF (b, c, d, a, x[15], S14, 0x49b40821); /* 16 */
 
          /* Round 2 */
          GG (a, b, c, d, x[ 1], S21, 0xf61e2562); /* 17 */
          GG (d, a, b, c, x[ 6], S22, 0xc040b340); /* 18 */
          GG (c, d, a, b, x[11], S23, 0x265e5a51); /* 19 */
          GG (b, c, d, a, x[ 0], S24, 0xe9b6c7aa); /* 20 */
          GG (a, b, c, d, x[ 5], S21, 0xd62f105d); /* 21 */
          GG (d, a, b, c, x[10], S22,  0x2441453); /* 22 */
          GG (c, d, a, b, x[15], S23, 0xd8a1e681); /* 23 */
          GG (b, c, d, a, x[ 4], S24, 0xe7d3fbc8); /* 24 */
          GG (a, b, c, d, x[ 9], S21, 0x21e1cde6); /* 25 */
          GG (d, a, b, c, x[14], S22, 0xc33707d6); /* 26 */
          GG (c, d, a, b, x[ 3], S23, 0xf4d50d87); /* 27 */
          GG (b, c, d, a, x[ 8], S24, 0x455a14ed); /* 28 */
          GG (a, b, c, d, x[13], S21, 0xa9e3e905); /* 29 */
          GG (d, a, b, c, x[ 2], S22, 0xfcefa3f8); /* 30 */
          GG (c, d, a, b, x[ 7], S23, 0x676f02d9); /* 31 */
          GG (b, c, d, a, x[12], S24, 0x8d2a4c8a); /* 32 */
 
          /* Round 3 */
          HH (a, b, c, d, x[ 5], S31, 0xfffa3942); /* 33 */
          HH (d, a, b, c, x[ 8], S32, 0x8771f681); /* 34 */
          HH (c, d, a, b, x[11], S33, 0x6d9d6122); /* 35 */
          HH (b, c, d, a, x[14], S34, 0xfde5380c); /* 36 */
          HH (a, b, c, d, x[ 1], S31, 0xa4beea44); /* 37 */
          HH (d, a, b, c, x[ 4], S32, 0x4bdecfa9); /* 38 */
          HH (c, d, a, b, x[ 7], S33, 0xf6bb4b60); /* 39 */
          HH (b, c, d, a, x[10], S34, 0xbebfbc70); /* 40 */
          HH (a, b, c, d, x[13], S31, 0x289b7ec6); /* 41 */
          HH (d, a, b, c, x[ 0], S32, 0xeaa127fa); /* 42 */
          HH (c, d, a, b, x[ 3], S33, 0xd4ef3085); /* 43 */
          HH (b, c, d, a, x[ 6], S34,  0x4881d05); /* 44 */
          HH (a, b, c, d, x[ 9], S31, 0xd9d4d039); /* 45 */
          HH (d, a, b, c, x[12], S32, 0xe6db99e5); /* 46 */
          HH (c, d, a, b, x[15], S33, 0x1fa27cf8); /* 47 */
          HH (b, c, d, a, x[ 2], S34, 0xc4ac5665); /* 48 */
 
          /* Round 4 */
          II (a, b, c, d, x[ 0], S41, 0xf4292244); /* 49 */
          II (d, a, b, c, x[ 7], S42, 0x432aff97); /* 50 */
          II (c, d, a, b, x[14], S43, 0xab9423a7); /* 51 */
          II (b, c, d, a, x[ 5], S44, 0xfc93a039); /* 52 */
          II (a, b, c, d, x[12], S41, 0x655b59c3); /* 53 */
          II (d, a, b, c, x[ 3], S42, 0x8f0ccc92); /* 54 */
          II (c, d, a, b, x[10], S43, 0xffeff47d); /* 55 */
          II (b, c, d, a, x[ 1], S44, 0x85845dd1); /* 56 */
          II (a, b, c, d, x[ 8], S41, 0x6fa87e4f); /* 57 */
          II (d, a, b, c, x[15], S42, 0xfe2ce6e0); /* 58 */
          II (c, d, a, b, x[ 6], S43, 0xa3014314); /* 59 */
          II (b, c, d, a, x[13], S44, 0x4e0811a1); /* 60 */
          II (a, b, c, d, x[ 4], S41, 0xf7537e82); /* 61 */
          II (d, a, b, c, x[11], S42, 0xbd3af235); /* 62 */
          II (c, d, a, b, x[ 2], S43, 0x2ad7d2bb); /* 63 */
          II (b, c, d, a, x[ 9], S44, 0xeb86d391); /* 64 */
 
          state[0] += a;
          state[1] += b;
          state[2] += c;
          state[3] += d;
 
          // Zeroize sensitive information.
          memset(x, 0, sizeof x);
        }
 
        //////////////////////////////

        // decodes input (unsigned char) into output (uint4). Assumes len is a multiple of 4.
        static void MD5::decode(uint4 output[], const uint1 input[], size_type len)
        {
            for (unsigned int i = 0, j = 0; j < len; i++, j += 4)
                output[i] = ((uint4)input[j]) | (((uint4)input[j + 1]) << 8) |
                (((uint4)input[j + 2]) << 16) | (((uint4)input[j + 3]) << 24);
        }

        //////////////////////////////

        // encodes input (uint4) into output (unsigned char). Assumes len is
        // a multiple of 4.
        static void MD5::encode(uint1 output[], const uint4 input[], size_type len)
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
        // F, G, H and I are basic MD5 functions.
        static inline MD5::uint4 MD5::F(uint4 x, uint4 y, uint4 z) {
            return x & y | ~x & z;
        }

        static inline MD5::uint4 MD5::G(uint4 x, uint4 y, uint4 z) {
            return x & z | y & ~z;
        }

        static inline MD5::uint4 MD5::H(uint4 x, uint4 y, uint4 z) {
            return x ^ y ^ z;
        }

        static inline MD5::uint4 MD5::I(uint4 x, uint4 y, uint4 z) {
            return y ^ (x | ~z);
        }

        // rotate_left rotates x left n bits.
        static inline MD5::uint4 MD5::rotate_left(uint4 x, int n) {
            return (x << n) | (x >> (32 - n));
        }


        // FF, GG, HH, and II transformations for rounds 1, 2, 3, and 4.
        // Rotation is separate from addition to prevent recomputation.
        static inline void MD5::FF(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + F(b, c, d) + x + ac, s) + b;
        }

        static inline void MD5::GG(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + G(b, c, d) + x + ac, s) + b;
        }

        static inline void MD5::HH(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + H(b, c, d) + x + ac, s) + b;
        }

        static inline void MD5::II(uint4& a, uint4 b, uint4 c, uint4 d, uint4 x, uint4 s, uint4 ac) {
            a = rotate_left(a + I(b, c, d) + x + ac, s) + b;
        }

        //////////////////////////////////////////////
    };

    inline std::ostream& operator<<(std::ostream& out, MD5 md5)
    {
        return out << md5.hexdigest();
    }

    //////////////////////////////

    inline std::string md5(const std::string& str)
    {
        MD5 md5 = MD5(str);
        return md5.hexdigest();
    }

    inline std::string md5(std::string_view str)
    {
        MD5 md5 = MD5(str);
        return md5.hexdigest();
    }
}
