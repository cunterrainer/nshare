#include <iostream>

#include "SFML/Network.hpp"
#include "SFML/Network/IpAddress.hpp"

#include "Sender.h"
#include "Receiver.h"


int main(int argc, const char** argv)
{
    if (argc == 1)
        return 1;
    if(argv[1][0] == 's')
        Sender(std::string(argv[2]));
    else
        Receiver();
}
