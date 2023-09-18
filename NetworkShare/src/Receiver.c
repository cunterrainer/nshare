#include <stdint.h>
#include <stdbool.h>

#include "SFML/Network.h"

#include "Log.h"
#include "Hash.h"
#include "Sender.h"


bool check_integrity(const char* received_hashes, const char* own_hash_data)
{
    ver("Checking integrity...");
    if (strcmp(own_hash_data, received_hashes) != 0)
    {
        err("Sha256 hash doesn't match, integrity compromised\nExpected hash:   %s\nCalculated hash: %s", received_hashes, own_hash_data);
        return false;
    }
    if (strcmp(&own_hash_data[65], &received_hashes[65]) != 0)
    {
        err("MD5 hash doesn't match, integrity compromised\nExpected hash:   %s\nCalculated hash: %s", &received_hashes[65], &own_hash_data[65]);
        return false;
    }
    suc("Passed integrity check\nSha256: %s\nMD5: %s", own_hash_data, &own_hash_data[65]);
    return true;
}


void receive_bytes(sfTcpSocket* socket, char* data, size_t bytes)
{
    size_t received = 0;
    while (bytes > 0)
    {
        if (sfTcpSocket_receive(socket, &data[received], bytes, &received) != sfSocketDone)
        {
            err("Error receiving bytes %u remaining", bytes);
            return;
        }
        bytes -= received;
    }
}


bool receive_file(sfTcpSocket* socket, size_t fsize, char* hash_data)
{
    FILE* fp = fopen("path", "wb");
    if (!fp)
    {
        err("Failed to open file [%s]", "path");
        return false;
    }

    Hash_MD5 md5 = hash_md5_init();
    Hash_Sha256 sha256 = hash_sha256_init();

    size_t remaining = fsize;
    while (remaining > 0)
    {
        size_t received;
        char buffer[BYTES_PER_SEND];

        if (sfTcpSocket_receive(socket, buffer, BYTES_PER_SEND, &received) != sfSocketDone)
        {
            fclose(fp);
            err("Error receiving bytes %u remaining from file", remaining);
            return false;
        }

        if (fwrite(buffer, 1, received, fp) != received)
        {
            fclose(fp);
            err("Error writing to file %u remaining", remaining);
            return false;
        }

        remaining -= received;
        hash_md5_update_binary(&md5, buffer, received);
        hash_sha256_update_binary(&sha256, buffer, received);
    }

    fclose(fp);
    hash_md5_finalize(&md5);
    hash_sha256_finalize(&sha256);
    hash_md5_hexdigest(&md5, &hash_data[65]);
    hash_sha256_hexdigest(&sha256, hash_data);
    return true;
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

    char path[100]; // TODO: might not be big enough
    sfPacket* packet = sfPacket_create();
    sfTcpSocket_receivePacket(socket, packet);
    sfPacket_readString(packet, path);
    sfUint32 fsize = sfPacket_readUint32(packet);
    sfPacket_destroy(packet);

    char own_hash_data[65 + 33];
    if (!receive_file(socket, fsize, own_hash_data)) return;
    sfTcpSocket_send(socket, own_hash_data, 1); // sent confirmation bit to tell the sender we're ready to get the checksums

    char hashData[65 + 33]; // first 64 bytes sha256 next 32 bytes md5 + null term char
    receive_bytes(socket, hashData, 98);

    if (!check_integrity(hashData, own_hash_data))
    {
        // TODO: ask user if we should remove file
    }
    sfTcpSocket_destroy(socket);
    ver("Receiver done");
}