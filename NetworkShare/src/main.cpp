#include <iostream>

#include "SFML/Network.hpp"
#include "SFML/Network/IpAddress.hpp"

#include "Sender.h"
#include "Receiver.h"
#include "Log.h"

int main(int argc, const char** argv)
{
    Ver.SetOn();
    if (argc == 1)
        //Receiver();
        //Sender("../vendor/premake5.exe");
        Sender("../ubuntu-22.04.2-desktop-amd64.iso");
    else if(argv[1][0] == 's')
        Sender(std::string(argv[2]));
    else
        Receiver();
    std::cin.get();
}
