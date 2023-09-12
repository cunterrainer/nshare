#pragma once
#include <string>
#include <cstdint>

void Sender(const std::string& path);
inline constexpr size_t BytesPerSend = 1000;

inline float ByteToMB(uint64_t bytes)
{
    return (float)bytes / (1024 * 1024);
}