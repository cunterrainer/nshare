#include <iostream>

#include "SFML/Network.hpp"
#include "SFML/Network/IpAddress.hpp"

void Sender()
{
    std::cout << "Sender " << std::endl;
    sf::TcpSocket socket;
    sf::Socket::Status status = socket.connect(sf::IpAddress::LocalHost, 53000);
    if (status != sf::Socket::Done)
    {
        std::cerr << "Connection failed" << std::endl;
    }
    std::cout << "Connected\n";

    char data[100] = "Hello Connection";

    // TCP socket:
    if (socket.send(data, 100) != sf::Socket::Done)
    {
        // error...
    }
}

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

    char data[100];
    std::size_t received;
    
    // TCP socket:
    if (client.receive(data, 100, received) != sf::Socket::Done)
    {
        // error...
    }
    std::cout << "Received " << received << " bytes" << std::endl;
    std::cout << data << std::endl;
}

int main(int argc, char** argv)
{
    if (argc == 1)
        return 1;
    if(argv[1][0] == 's')
        Sender();
    else
        Receiver();
}
