#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

#include "ProgressBar.h"
#include "SFML/Config.hpp"
#include "SFML/Network.hpp"

#include "SFML/Network/IpAddress.hpp"
#include "SFML/Network/Packet.hpp"
#include "SFML/System/Sleep.hpp"
#include "Sender.h"
#include "Hash.h"
#include "MD5.h"
#include "Log.h"

struct FileData
{
    char* data;
    size_t size;
    std::string sha256; // 64 chars
    std::string md5;    // 32 chars
};

FileData LoadFile(const char* path)
{
    FileData f;
    system((std::string("sha256sum -b ") + path).c_str());
    system((std::string("md5sum ") + path).c_str());
    FILE* fileptr = fopen(path, "rb");
    fseek(fileptr, 0, SEEK_END);
    f.size = ftell(fileptr);
    rewind(fileptr);

    f.data = (char *)malloc(f.size * sizeof(char));
    fread(f.data, f.size, 1, fileptr);
    fclose(fileptr);

    std::string_view view(f.data, f.size);
    f.sha256 = hash::sha256(view);
    f.md5 = hash::md5(view);
    Ver << "Sha256: " << f.sha256 << Endl;
    Ver << "MD5: " << f.md5 << Endl;
    return f;
}


void Sender(const std::string& path)
{
    Ver << "Sender" << Endl;
    sf::TcpSocket socket;
    if (socket.connect(sf::IpAddress::LocalHost, 53000) != sf::Socket::Done)
    {
        Err << "Failed to establish a connection" << Endl;
        return;
    }
    Ver << "Sender connected" << Endl;

    FileData f = LoadFile(path.c_str());
    {
        char hashData[64 + 32];
        std::memcpy(hashData, f.sha256.c_str(), 64);
        std::memcpy(&hashData[64], f.md5.c_str(), 32);
        socket.send(hashData, 64+32);
    }
    sf::Packet fileInfo;
    fileInfo << path << sf::Uint64(f.size);
    socket.send(fileInfo);

    ProgressBarInit();
    uint64_t bytesRemaining = f.size;
    while (bytesRemaining > 0)
    {
        size_t sent;
        const size_t bytes2send = bytesRemaining < BytesPerSend ? bytesRemaining : BytesPerSend;

        if (socket.send(&f.data[f.size-bytesRemaining], bytes2send, sent) != sf::Socket::Done)
        {
            Err << "Error sending bytes" << Endl;
        }
        bytesRemaining -= sent;
        ProgressBar((float)(f.size-bytesRemaining), (float)f.size);
    }
    free(f.data);
}
