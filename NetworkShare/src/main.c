#include <stdio.h>

#include "SFML/Network.h"
#include "Hash.h"
void sender(const char* path);
void receive();

int main()
{
    printf("%s\n", hash_sha224_easy("Hello"));
    //Ver.SetOn();
    //if (argc == 1)
    //    receive();
    //    //send("../vendor/premake5.exe");
    //    //send("../ubuntu-22.04.2-desktop-amd64.iso");
    //else if(argv[1][0] == 's')
    //    sender(argv[2]);
    //else
    //    receive();
    getchar();
}
