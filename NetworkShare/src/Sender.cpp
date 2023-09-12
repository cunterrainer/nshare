#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#include <iostream>

#include "SFML/Network/IpAddress.hpp"
#include "SFML/Network/Packet.hpp"
#include "SFML/System/Sleep.hpp"
#include "SFML/Config.hpp"
#include "SFML/Network.hpp"

#include "ProgressBar.h"
#include "Sender.h"
#include "Hash.h"
#include "Log.h"

struct FileData
{
    std::vector<char> data;
    size_t size;
    std::string sha256; // 64 chars
    std::string md5;    // 32 chars
};

FileData LoadFile(const std::string& path)
{
    FileData f;
    std::ifstream infile(path, std::ios::in | std::ios::binary);
    if (!infile.is_open())
    {
        Err << "Failed to open file [" << path << ']' << Endl;
    }

    infile.seekg(0, std::ios::end);
    f.size = infile.tellg();
    infile.seekg(0, std::ios::beg);

    f.data.reserve(f.size);
    infile.read(f.data.data(), f.size);

    std::string_view view(f.data.data(), f.size);
    f.sha256 = Hash::sha256(view);
    Ver << "Sha256: " << f.sha256 << Endl;
    f.md5 = Hash::md5(view);
    Ver << "MD5: " << f.md5 << Endl;
    return f;
}


void Sender(const std::string& path)
{
    Ver << "Sender" << Endl;
    sf::TcpSocket socket;
    FileData f = LoadFile(path.c_str());
    if (socket.connect(sf::IpAddress::LocalHost, 5300) != sf::Socket::Done)
    {
        Err << "Failed to establish a connection" << Endl;
        return;
    }
    Ver << "Sender connected" << Endl;

    {
        char hashData[64 + 32];
        std::memcpy(hashData, f.sha256.c_str(), 64);
        std::memcpy(&hashData[64], f.md5.c_str(), 32);
        socket.send(hashData, 64+32);
    }
    sf::Packet fileInfo;
    std::cout << f.size << std::endl;
    fileInfo << path << sf::Uint64(f.size);
    socket.send(fileInfo);

    ProgressBarInit();
    uint64_t bytesRemaining = f.size;
    while (bytesRemaining > 0)
    {
        size_t sent;
        const size_t bytes2send = bytesRemaining < BytesPerSend ? (size_t)bytesRemaining : BytesPerSend;

        if (socket.send(&f.data[f.size-bytesRemaining], bytes2send, sent) != sf::Socket::Done)
        {
            Err << "Error sending bytes" << Endl;
        }

        bytesRemaining -= sent;
        //ProgressBar((float)(ByteToMB(f.size - bytesRemaining)), ByteToMB(f.size));
    }
    std::cout << "Done\n";
}
