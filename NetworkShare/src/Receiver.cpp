#include <iostream>
#include <ostream>
#include <sstream>
#include <cstdint>
#include <string>
#include <fstream>

#include "SFML/Config.hpp"
#include "SFML/Network.hpp"
#include "SFML/Network/Packet.hpp"

#include "Receiver.h"
#include "Sender.h"
#include "Hash.h"
#include "MD5.h"
#include "Log.h"

void Receiver()
{
    std::cout << "Receiver " << std::endl;
    sf::TcpListener listener;

    // bind the listener to a port
    if (listener.listen(53000) != sf::Socket::Done)
    {
        std::cerr << "Listen failed\n";
        // error...
    }

    // accept a new connection
    sf::TcpSocket client;
    if (listener.accept(client) != sf::Socket::Done)
    {
        std::cerr << "Accept failed\n";
        // error...
    }
    std::cout << "Connected\n";
    

    size_t got;
    char hashData[64+32];
    client.receive(hashData, 64+32, got);
    std::string_view sha256(hashData, 64);
    std::string_view md5(&hashData[64], 32);
    std::cout << "Sha256: " << sha256 << std::endl;
    std::cout << "MD5:    " << md5 << std::endl;

    sf::Packet fileInfo;
    sf::Uint64 fileSize;
    client.receive(fileInfo);
    fileInfo >> fileSize;
    std::cout << "Fileinfo: " <<  fileSize << std::endl;


    std::string d;
    char data[BytesPerSend];
    /* size_t bytesRemaining = fileSize; */
    size_t remaining = fileSize;
    while (remaining > 0)
    {
        size_t received = 0;
        if (client.receive(data, BytesPerSend, received) != sf::Socket::Done)
        {
            Err << "Error receiving " << received << Endl;
            // error...
        }
        remaining -= received;
        d.append(data, received);
    }
    Log << "Received " << fileSize << " bytes" << Endl;

    std::cout << "Checking integrity..." << std::endl;
    std::string sha256Received = hash::sha256(d); 
    std::string md5Received = hash::md5(d);
    /* if (sha256Received != sha256) */
    /* { */
    /*     Err << "Sha256 hash doesn't match, integrity compromised\nExpected hash:   " << sha256 << "\nCalculated hash: " << sha256Received << Endl; */
    /*     return; */
    /* } */
    std::cout << d.size() << std::endl;
    if (md5Received != md5)
    {
        Err << "MD5 hash doesn't match, integrity compromised\nExpected hash:   " << md5 << "\nCalculated hash: " << md5Received << Endl;
        return;
    }
    Suc << "Passed integrity check\nSha256: " << sha256 << "\nMD5: " << md5 << Endl;
    //std::ofstream os("a.txt", std::ios::binary);
    //os << d;
    //system("sha256sum a.txt");
}

