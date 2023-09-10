#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>

#include "SFML/Config.hpp"
#include "SFML/Network.hpp"

#include "SFML/Network/Packet.hpp"
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
    std::cout << "Sha256: " << f.sha256 << std::endl;
    std::cout << "MD5:    " << f.md5 << std::endl;
    return f;
}


void Sender(const std::string& path)
{
    std::cout << "Sender" << std::endl;
    sf::TcpSocket socket;
    sf::Socket::Status status = socket.connect(sf::IpAddress::LocalHost, 53000);
    if (status != sf::Socket::Done)
    {
        Err << "Failed to establish a connection" << Endl;
        return;
    }
    std::cout << "Connected\n";


    FileData f = LoadFile(path.c_str());
    {
        char hashData[64 + 32];
        std::memcpy(hashData, f.sha256.c_str(), 64);
        std::memcpy(&hashData[64], f.md5.c_str(), 32);
        socket.send(hashData, 64+32);
    }
    /* socket.send(f.sha256.c_str(), 64); */
    /* socket.send(f.md5.c_str(), 32); */
    sf::Packet fileInfo;
    fileInfo << sf::Uint64(f.size);
    socket.send(fileInfo);

    size_t bytesRemaining = f.size;
    std::cout << ": " << f.size << std::endl;
    for (size_t i = 0; i < f.size; i += 100)
    {
        const size_t bytes2send = bytesRemaining < 100 ? bytesRemaining : 100;
        bytesRemaining -= 100;
        std::cout << i << " " << bytes2send << std::endl;

        if (socket.send(&f.data[i], bytes2send) != sf::Socket::Done)
        {
            // error...
        }
    }
    free(f.data);
}
