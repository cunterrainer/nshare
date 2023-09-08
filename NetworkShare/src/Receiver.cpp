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
#include "Hash.h"

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

    sf::Packet fileInfo;
    sf::Uint64 fileSize;
    client.receive(fileInfo);
    fileInfo >> fileSize;
    std::cout << "Fileinfo: " <<  fileSize << std::endl;


    std::string d;
    char data[100];
    size_t bytesRemaining = fileSize;
    for(size_t i = 0; i < fileSize; i += 100)
    {
        std::size_t received;
        const size_t bytes2receive = bytesRemaining < 100 ? bytesRemaining : 100;
        bytesRemaining -= 100;
        
        // TCP socket:
        if (client.receive(data, bytes2receive, received) != sf::Socket::Done)
        {
            // error...
        }
        d.append(data, bytes2receive);
        std::cout << "Received " << received << " bytes" << std::endl;
    }
    std::cout << d << std::endl;
    std::cout << hash::sha256(d) << std::endl;
    //std::ofstream os("a.txt", std::ios::binary);
    //os << d;
    //system("sha256sum a.txt");
}

