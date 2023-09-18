#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "SFML/Network.h"

#include "Log.h"
#include "Hash.h"

#define BytesPerSend 1024

inline float ByteToMB(uint64_t bytes)
{
    return (float)bytes / (1024 * 1024);
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


void Sender(const char* path)
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
        char hashData[64 + 32];
        memcpy(hashData, fdata.sha256, 64);
        memcpy(&hashData[64], fdata.md5, 32);
        sfTcpSocket_send(socket, hashData, 64+32);
    }

    sfPacket* packet = sfPacket_create();
    sfPacket_writeString(packet, path);
    sfPacket_writeUint32(packet, fdata.size);
    sfTcpSocket_sendPacket(socket, packet);
    sfPacket_destroy(packet);

    uint64_t bytesRemaining = fdata.size;
    while (bytesRemaining > 0)
    {
        size_t sent;
        const size_t bytes2send = bytesRemaining < BytesPerSend ? (size_t)bytesRemaining : BytesPerSend;

        if (sfTcpSocket_sendPartial(socket, &fdata.data[fdata.size - bytesRemaining], bytes2send, &sent) != sfSocketDone)
        {
            err("Error sending bytes %u remaining", bytesRemaining);
        }
        bytesRemaining -= sent;
    }
    free(fdata.data);
    sfTcpSocket_destroy(socket);
    ver("Sender done");
}