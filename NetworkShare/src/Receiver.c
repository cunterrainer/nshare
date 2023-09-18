#include <stdint.h>
#include <stdbool.h>

#include "SFML/Network.h"

#include "Log.h"
#include "Hash.h"


bool check_integrity(const char* hashes, const char* data, size_t size)
{
    ver("Checking integrity...");
    const char* data_md5 = hash_md5_binary(data, size, NULL);
    const char* data_sha256 = hash_sha256_binary(data, size, NULL);

    if (strcmp(data_sha256, hashes) != 0)
    {
        err("Sha256 hash doesn't match, integrity compromised\nExpected hash:   %s\nCalculated hash: %s", hashes, data_sha256);
        return false;
    }
    if (strcmp(data_sha256, hashes) != 0)
    {
        err("MD5 hash doesn't match, integrity compromised\nExpected hash:   %s\nCalculated hash: %s", &hashes[65], data_md5);
        return false;
    }
    suc("Passed integrity check\nSha256: %s\nMD5: %s", data_sha256, data_md5);
    return true;
}


void receive_bytes(sfTcpSocket* socket, void* data, size_t bytes)
{
    size_t received;
    while (bytes > 0)
    {
        if (sfTcpSocket_receive(socket, data, bytes, &received) != sfSocketDone)
        {
            err("Error receiving bytes %u remaining", bytes);
        }
        bytes -= received;
    }
}


void receive()
{
    ver("Receiver");
    sfTcpListener* listener = sfTcpListener_create();
    if (sfTcpListener_listen(listener, 5300, sfIpAddress_Any) != sfSocketDone)
    {
        sfTcpListener_destroy(listener);
        err("Failed listening to port");
        return;
    }

    sfTcpSocket* socket = sfTcpSocket_create();
    if (sfTcpListener_accept(listener, &socket) != sfSocketDone)
    {
        sfTcpSocket_destroy(socket);
        sfTcpListener_destroy(listener);
        err("Failed to accept connection");
        return;
    }
    sfTcpListener_destroy(listener);
    ver("Receiver connected");

    char hashData[65 + 33]; // first 64 bytes sha256 next 32 bytes md5
    receive_bytes(socket, hashData, 96);
    memmove(&hashData[65], &hashData[64], 32);
    hashData[64] = 0;
    hashData[97] = 0;
    printf("%s\n%s\n", hashData, &hashData[65]);

    char path[100]; // TODO: might not be big enough
    sfPacket* packet = sfPacket_create();
    sfTcpSocket_receivePacket(socket, packet);
    sfPacket_readString(packet, path);
    sfUint32 fsize = sfPacket_readUint32(packet);

    char* content = malloc(fsize);
    receive_bytes(socket, content, fsize);
    ver("Receiver done");

    if (check_integrity(hashData, content, fsize))
    {
        ver("Writing to file [%s] (not yet implemented)", path);
    }
    free(content);
    sfTcpSocket_destroy(socket);


    //ProgressBarInit();
    //std::unique_ptr<char[]> data = std::make_unique<char[]>((size_t)fileSize);
    //size_t received = 0;
    //size_t remainingBytes = (size_t)fileSize;
    //while (remainingBytes > 0)
    //{
    //    if (client.receive(&data.get()[fileSize - remainingBytes], std::min(remainingBytes, (size_t)65535/*max tcp packet size*/), received) != sf::Socket::Done)
    //    {
    //        Err << "Error receiving " << fileSize - remainingBytes << Endl;
    //    }
    //    remainingBytes -= received;
    //    //ProgressBar((float)(fileSize-remainingBytes), (float)fileSize);
    //}
}