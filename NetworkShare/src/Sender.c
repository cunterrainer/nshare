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
        err("Failed to get file size");
        return 0;
    }
    return buf.st_size;
#else
    struct stat st;
    stat(path, &st);
    size = st.st_size;
#endif
}


typedef struct
{
    char* data;
    sfUint32 size;
    const char* sha256; // 64 chars
    const char* md5;    // 32 chars
}FileData;


FileData LoadFile(const char* path)
{
    FileData f = { .data = NULL, .size = 0, .sha256 = NULL, .md5 = NULL };
    FILE* fp = fopen(path, "rb");
    if (!fp)
    {
        err("Failed to open file [%s]", path);
        return f;
    }

    fseek(fp, 0, SEEK_END);
    f.size = ftell(fp);
    rewind(fp);

    f.data = malloc(f.size);
    if (f.data == NULL)
    {
        fclose(fp);
        err("Failed to allocate memory for file content");
        return f;
    }

    /* copy the file into the buffer */
    if (1 != fread(f.data, f.size, 1, fp))
    {
        fclose(fp);
        free(f.data);
        err("Failed to read file content");
        return f;
    }
    fclose(fp);

    f.sha256 = hash_sha256_binary(f.data, f.size, NULL);
    f.md5 = hash_md5_binary(f.data, f.size, NULL);
    printf("%s\n%s\n", f.sha256, f.md5);
    return f;
}



bool send_file(sfTcpSocket* socket, const char* path, char* hash_data)
{
    FILE* fp = fopen(path, "rb");
    if (!fp)
    {
        err("Failed to open file [%s]", path);
        return false;
    }

    Hash_MD5 md5 = hash_md5_init();
    Hash_Sha256 sha256 = hash_sha256_init();
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
        if (sfTcpSocket_sendPartial(socket, buffer, bytes2send, &sent) == sfSocketError)
        {
            fclose(fp);
            err("Error sending bytes %u remaining", bytesRemaining);
            return false;
        }

        bytesRemaining -= bytes2send;
        hash_md5_update_binary(&md5, buffer, bytes2send);
        hash_sha256_update_binary(&sha256, buffer, bytes2send);
    }

    fclose(fp);
    hash_md5_finalize(&md5);
    hash_sha256_finalize(&sha256);
    hash_md5_hexdigest(&md5, &hash_data[65]);
    hash_sha256_hexdigest(&sha256, hash_data);
    return true;
}


void sender(const char* path)
{
    ver("Sender");
    sfTcpSocket* socket = sfTcpSocket_create();
    if (sfTcpSocket_connect(socket, sfIpAddress_LocalHost, 5300, sfTime_Zero) != sfSocketDone)
    {
        sfTcpSocket_destroy(socket);
        err("Failed to establish a connection");
        return;
    }
    ver("Sender connected");

    FileData fdata = LoadFile(path);
    if (fdata.sha256 == NULL) return;

    {
        char hashData[65 + 33];
        memcpy(hashData, fdata.sha256, 64);
        memcpy(&hashData[64], fdata.md5, 32);
        sfTcpSocket_send(socket, hashData, 64+32);
    }

    sfPacket* packet = sfPacket_create();
    sfPacket_writeString(packet, path);
    sfPacket_writeUint32(packet, fdata.size);
    sfTcpSocket_sendPacket(socket, packet);
    sfPacket_destroy(packet);

    char hash_data[65 + 33];
    send_file(socket, path, hash_data);
    Log("%s\n%s", hash_data, &hash_data[65]);
     
    free(fdata.data);
    sfTcpSocket_destroy(socket);
    ver("Sender done");
}