import "dart:typed_data";
import 'dart:convert';
import "dart:async";
import "dart:core";
import "dart:io";

import "Log.dart";
import "Hash.dart";
import "FileIO.dart";
import "ProgressBar.dart";

bool CheckIntegrity(String receivedHash, String hash, String fileName)
{
  Ver("Checking file integrity...");
  if (receivedHash != hash)
  {
    Hint("'$fileName' Sha256 hash doesn't match, integrity compromised\nExpected hash:   $receivedHash\nCalculated hash: $hash");
    return false;
  }
  Suc("Passed integrity check Sha256: $hash '$fileName'");
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

String GetFileName(String received, String outpath, bool isFolder)
{
  if (isFolder) return FileIO.ReplaceRootDir(received.substring(0, received.indexOf("|")), outpath, outpath.isNotEmpty);
  if (outpath.isEmpty) return received.substring(0, received.indexOf("|"));
  return outpath;
}

Future<void> ReceiveFile(ServerSocket server, String path) async
{
  ProgressBar.Init();
  FileIO file = FileIO();
  bool finished = false;
  bool isFolder = false;
  int bytes = 0;
  int remaining = 1;
  int numOfFiles = 0;
  String receivedHash = ""; // will be used to store some other stuff as well
  String fileName = "";
  final Sha256 sha = Sha256();
  server.listen((Socket socket)
  {
    socket.listen((Uint8List data) async
    {
      if (numOfFiles == 0)
      {
        receivedHash += ascii.decode(data, allowInvalid: true);
        if (!receivedHash.contains ('|')) return;

        data = data.sublist(data.indexOf(124) + 1); // '|'
        isFolder = receivedHash[0] == "1";
        try { numOfFiles = int.parse(receivedHash.substring(1, receivedHash.indexOf("|"))); }
        on FormatException catch(e) { Err("Failed to parse files header of message \"${e.source}\" at character ${e.offset} reason: ${e.message}"); }
        receivedHash = "";
        Ver("Is folder: $isFolder");
        Ver("Number of files: $numOfFiles");
      }

      if (fileName.isEmpty)
      {
        receivedHash += ascii.decode(data, allowInvalid: true);
        if (!receivedHash.contains ('|')) return;

        data = data.sublist(data.indexOf(124) + 1); // '|'
        fileName = GetFileName(receivedHash, path, isFolder);
        FileIO.CreateParentDirs(fileName);
        receivedHash = "";
        Ver("File name: $fileName");
      }

      if (bytes == 0)
      {
        receivedHash += ascii.decode(data, allowInvalid: true);
        if (!receivedHash.contains ('|')) return;

        data = data.sublist(data.indexOf(124) + 1); // '|'
        try { bytes = int.parse(receivedHash.substring(0, receivedHash.indexOf("|"))) + 64; } // -1 = empty folder
        on FormatException catch(e) { Err("Failed to parse size header of message \"${e.source}\" at character ${e.offset} reason: ${e.message}"); }
        remaining = bytes;
        receivedHash = "";
        if (bytes == 63)
        {
          FileIO.CreateDirs(fileName);
          remaining++;
        }
        else if (!file.Open(fileName, FileMode.write)) remaining = 0;
        Ver("Bytes to receive: $remaining");
      }


      int toReceive = remaining - data.length < 0 ? remaining : data.length;
      if (remaining - toReceive < 64) // receiving hash in total or at least partially
      {
        if (toReceive > 64)
        {
          int dataSize = toReceive - 64;
          sha.UpdateBinary(data, dataSize);
          file.WriteChunk(data, dataSize);
          receivedHash += String.fromCharCodes(data, dataSize); // might cause errors
        }
        else
        {
          receivedHash += String.fromCharCodes(data); // might cause errors
        }
      }
      else
      {
        sha.UpdateBinary(data, toReceive);
        file.WriteChunk(data, toReceive);
      }
      remaining -= toReceive;
      ProgressBar.Show(bytes - remaining, bytes);


      if (remaining <= 0) // less than should never happen but just in case
      {
        ProgressBar.Init();
        file.Close();
        receivedHash = receivedHash.substring(receivedHash.length - 64);
        sha.Finalize();
        if (!CheckIntegrity(receivedHash, sha.Hexdigest(), fileName) && Promt("Checksums don't match do you want to delete the file? [Y|N]: ")) file.Delete();
        --numOfFiles;
        if (numOfFiles == 0)
        {
          finished = true;
          socket.add([1]);
          await socket.flush();
          socket.destroy();
        }
        else
        {
          bytes = 0;
          remaining = 1;
          receivedHash = "";
          fileName = "";
          sha.Reset();
          socket.add([1]);
          await socket.flush();
        }
      }
    }, onError: OnReceiverError, onDone: (){ socket.destroy(); finished = true; });
  }, onError: OnReceiverError);

  while (!finished) await Future.delayed(Duration(milliseconds: 200));
}

Future<ServerSocket?> SetupSocketReceiver(String ip, int port) async
{
  Ver("Receiver");
  try
  {
    ServerSocket server = await ServerSocket.bind(ip, port);
    Ver("Connected");
    return server;
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
    Err("Unknown exception: $e");
  }
  return null;
}

Future<void> Receive(String ip, int port, String path) async
{
  final ServerSocket? server = await SetupSocketReceiver(ip, port);
  if (server == null) return;

  await ReceiveFile(server, path);
  server.close();
}