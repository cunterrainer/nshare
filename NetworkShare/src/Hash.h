#pragma once
#include <vector>
#include <string>
#include <locale>
#include <climits>
#include <cstdint>
#include <cstring>
#include <codecvt>
#include <sstream>
#include <iomanip>
#include <type_traits>
#include <string_view>

namespace hash
{
    namespace encode
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


    namespace util
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
            *end = util::IsLittleEndian() ? util::SwapEndian(strSize) : strSize;
            return binRep;
        }


        inline void CreateMessageSchedule(uint32_t* const w) const
        {
            if (util::IsLittleEndian())
            {
                for (size_t i = 0; i < 64; ++i)
                    w[i] = util::SwapEndian(w[i]);
            }

            for (size_t i = 16; i < 64; ++i)
            {
                const uint32_t s0 = util::RightRotate32(w[i - 15], 7) ^ util::RightRotate32(w[i - 15], 18) ^ (w[i - 15] >> 3);
                const uint32_t s1 = util::RightRotate32(w[i - 2], 17) ^ util::RightRotate32(w[i - 2], 19) ^ (w[i - 2] >> 10);
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
                const uint32_t s1 = util::RightRotate32(e, 6) ^ util::RightRotate32(e, 11) ^ util::RightRotate32(e, 25);
                const uint32_t ch = (e & f) ^ (~e & g);
                const uint32_t temp1 = h + s1 + ch + s_K[i] + w[i];
                const uint32_t s0 = util::RightRotate32(a, 2) ^ util::RightRotate32(a, 13) ^ util::RightRotate32(a, 22);
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
    inline std::string sha256(const std::string_view& str)
    {
        Sha256 s256;
        return s256.Generate(str);
    }
}
