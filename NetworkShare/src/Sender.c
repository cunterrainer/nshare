#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <sys/stat.h>

#include "SFML/Network.h"

#include "Log.h"
#include "Hash.h"
#include "Sender.h"

inline float ByteToMB(uint64_t bytes)
{
    return (float)bytes / (1024 * 1024);
}


uint64_t get_file_size(const char* path)
{
#ifdef WINDOWS
    struct _stat64 buf;
    if (_stat64(path, &buf) != 0)
    {
        err("Failed to get file size [%s]", path);
        return 0;
    }
    return buf.st_size;
#else
    struct stat st;
    stat(path, &st);
    size = st.st_size;
#endif
}


void send_receive_confirmation(sfTcpSocket* socket)
{
    char data[1];
    size_t rec;
    sfTcpSocket_receive(socket, data, 1, &rec);
}


sfTcpSocket* sender_connect()
{
    sfTcpSocket* socket = sfTcpSocket_create();
    if (sfTcpSocket_connect(socket, sfIpAddress_LocalHost, 5300, sfTime_Zero) != sfSocketDone)
    {
        sfTcpSocket_destroy(socket);
        err("Failed to establish a connection");
        return NULL;
    }
    ver("Sender connected");
    return socket;
}


bool send_file(sfTcpSocket* socket, const char* path, char* hash_data)
{
    FILE* fp = fopen(path, "rb");
    if (!fp)
    {
        err("Failed to open file [%s]", path);
        return false;
    }

    Hash_MD5 md5;
    hash_md5_init(md5);
    Hash_Sha256 sha256;
    hash_sha256_init(sha256);
    uint64_t bytesRemaining = get_file_size(path);

    while (bytesRemaining > 0)
    {
        char buffer[BYTES_PER_SEND];
        const size_t bytes2send = bytesRemaining < BYTES_PER_SEND ? (size_t)bytesRemaining : BYTES_PER_SEND;

        if (fread(buffer, 1, bytes2send, fp) != 0 && ferror(fp) != 0)
        {
            fclose(fp);
            err("Error reading from file [%s] remaining %u bytes", path, bytesRemaining);
            return false;
        }

        size_t sent;
        if (sfTcpSocket_sendPartial(socket, buffer, bytes2send, &sent) != sfSocketDone)
        {
            fclose(fp);
            err("Error sending bytes %u remaining", bytesRemaining);
            return false;
        }

        bytesRemaining -= bytes2send;
        hash_md5_update_binary(md5, buffer, bytes2send);
        hash_sha256_update_binary(sha256, buffer, bytes2send);
    }

    fclose(fp);
    hash_md5_finalize(md5);
    hash_sha256_finalize(sha256);
    hash_md5_hexdigest(md5, &hash_data[65]);
    hash_sha256_hexdigest(sha256, hash_data);
    return true;
}


void sender(const char* path)
{
    ver("Sender");
    sfTcpSocket* socket = sender_connect();
    if (socket == NULL) return;

    sfPacket* packet = sfPacket_create();
    sfPacket_writeString(packet, path);
    sfPacket_writeUint32(packet, (sfUint32)get_file_size(path));
    sfTcpSocket_sendPacket(socket, packet);
    sfPacket_destroy(packet);

    char hash_data[65 + 33];
    if (!send_file(socket, path, hash_data)) return;
    send_receive_confirmation(socket);
    sfTcpSocket_send(socket, hash_data, 65 + 33);
    ver("Sha256: %s\n[INFO]    MD5: %s", hash_data, &hash_data[65]);

    sfTcpSocket_destroy(socket);
    ver("Sender done");
}