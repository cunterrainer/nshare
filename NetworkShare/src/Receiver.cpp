#include <iostream>
#include <ostream>
#include <sstream>
#include <cstdint>
#include <string>
#include <memory>
#include <fstream>

#include "SFML/Config.hpp"
#include "SFML/Network.hpp"
#include "SFML/Network/Packet.hpp"

#include "Receiver.h"
#include "Sender.h"
#include "Hash.h"
#include "MD5.h"
#include "Log.h"
#include "ProgressBar.h"


bool CheckIntegrity(std::string_view sha256, std::string_view md5, std::string_view data)
{
    Ver << "Checking integrity..." << Endl;
    std::string sha256Received = hash::sha256(data); 
    std::string md5Received = hash::md5(data);
    if (sha256Received != sha256)
    {
        Err << "Sha256 hash doesn't match, integrity compromised\nExpected hash:   " << sha256 << "\nCalculated hash: " << sha256Received << Endl;
        return false;
    }
    if (md5Received != md5)
    {
        Err << "MD5 hash doesn't match, integrity compromised\nExpected hash:   " << md5 << "\nCalculated hash: " << md5Received << Endl;
        return false;
    }
    Suc << "Passed integrity check\nSha256: " << sha256 << "\nMD5: " << md5 << Endl;
    return true;
}


void Receiver()
{
    Ver << "Receiver" << Endl;
    sf::TcpListener listener;

    // bind the listener to a port
    if (listener.listen(53000) != sf::Socket::Done)
    {
        Err << "Failed listening to port " << Endl;
        return;
    }

    // accept a new connection
    sf::TcpSocket client;
    if (listener.accept(client) != sf::Socket::Done)
    {
        Err << "Failed to accept connection" << Endl;
        return;
    }
    Ver << "Receiver connected" << Endl;
    

    size_t got;
    char hashData[64+32]; // first 64 bytes sha256 next 32 bytes md5
    client.receive(hashData, 64+32, got);
    std::string_view sha256(hashData, 64);
    std::string_view md5(&hashData[64], 32);

    sf::Packet fileInfo;
    sf::Uint64 fileSize;
    client.receive(fileInfo);
    fileInfo >> fileSize;


    ProgressBarInit();
    std::unique_ptr<char[]> data = std::make_unique<char[]>(fileSize);
    uint64_t remainingBytes = fileSize;
    while (remainingBytes > 0)
    {
        size_t received = 0;
        if (client.receive(&data.get()[fileSize-remainingBytes], BytesPerSend, received) != sf::Socket::Done)
        {
            Err << "Error receiving " << received << Endl;
        }
        remainingBytes -= received;
        ProgressBar((float)(fileSize-remainingBytes), (float)fileSize);
    }
    CheckIntegrity(sha256, md5, std::string_view(data.get(), fileSize));
    //std::ofstream os("a.txt", std::ios::binary);
    //os << d;
    //system("sha256sum a.txt");
}

