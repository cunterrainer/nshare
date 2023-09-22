import "dart:typed_data";
import 'dart:convert';
import "dart:async";
import "dart:core";
import "dart:io";

import "Log.dart";
import "Hash.dart";

bool CheckIntegrity(String receivedHash, String hash)
{
  Ver("Checking file integrity...");
  if (receivedHash != hash)
  {
    Hint("Sha256 hash doesn't match, integrity compromised\nExpected hash:   $receivedHash\nCalculated hash: $hash");
    return false;
  }
  Suc("Passed integrity check Sha256: $hash");
  return true;
}

bool Promt(String msg)
{
  do {
    stdout.write(msg);
    String input = stdin.readLineSync()?.toLowerCase().trim() ?? "";

    if (input == "y" || input == "yes") return true;
    else if (input == "n" || input == "no") return false;
  } while(true);
}

void OnReceiverError(Object error, StackTrace st)
{
  Err('Error receiving bytes: $error');
  VerErr('Stack Trace:\n$st');
}

void ReceiveFile()
{
  
}

Future<void> Receive(String ip, int port, void Function(Uint8List, int) fileWriteChunkCallback, void Function() fileDeleteCallback) async
{
  Ver("Receiver");
  bool finished = false;
  ServerSocket? server;

  try
  {
    server = await ServerSocket.bind(ip, port);

    int bytes = 0;
    int remaining = 1;
    String receivedHash = ""; // will be used to store the initial bytes value as well but then cleared
    Sha256 sha = Sha256();
    server.listen((Socket socket)
    {
      socket.listen((Uint8List data)
      {
        if (bytes == 0)
        {
          receivedHash += ascii.decode(data);
          if (!receivedHash.contains ('|')) return;

          data = data.sublist(data.indexOf(124) + 1); // '|'
          try { bytes = int.parse(receivedHash.substring(0, receivedHash.indexOf("|"))) + 64; }
          on FormatException catch(e) { Err("Failed to parse size header of message \"${e.source}\" at character ${e.offset} reason: ${e.message}"); }
          remaining = bytes;
          receivedHash = "";
          Ver("Bytes to receive: $bytes");
        }

        int toReceive = remaining - data.length < 0 ? remaining : data.length;
        if (remaining - toReceive < 64) // receiving hash in total or at least partially
        {
          int dataSize = toReceive > 64 ? toReceive - 64 : remaining - 64;
          sha.UpdateBinary(data, dataSize);
          fileWriteChunkCallback(data, dataSize);
          receivedHash += String.fromCharCodes(data, dataSize); // might cause errors
        }
        else
        {
          sha.UpdateBinary(data, toReceive);
          fileWriteChunkCallback(data, toReceive);
        }
        remaining -= toReceive;

        if (remaining <= 0) // less than should never be the case but just in case
        {
          receivedHash = receivedHash.substring(receivedHash.length - 64);
          sha.Finalize();
          finished = true;
          socket.destroy();
        }
      }, onError: OnReceiverError);
    }, onError: OnReceiverError);

    Ver("Server socket is set up and listening");
    while (!finished) await Future.delayed(Duration(milliseconds: 100));

    if (!CheckIntegrity(receivedHash, sha.Hexdigest()) && Promt("Checksums don't match do you want to delete the file? [Y|N]: "))
      fileDeleteCallback();
  }
  on SocketException catch(e)
  {
    Err("Failed to bind socket to $ip on port $port reason: ${e.message}");
    if (e.osError != null) VerErr("${e.osError}");
  }
  on ArgumentError catch(e)
  {
    Err(e.toString());
  }
  catch (e)
  {
    Err("Unhandled exception: $e");
  }
  finally
  {
    await server?.close();
  }
}