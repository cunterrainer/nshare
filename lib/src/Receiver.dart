import "dart:typed_data";
import 'dart:convert';
import "dart:async";
import "dart:core";
import "dart:io";

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';

import "Log.dart";
import "FileIO.dart";
import "ProgressBar.dart";

bool CheckIntegrity(String receivedHash, String hash, String fileName, int fileNum, int numOfFiles)
{
  Ver("Checking file integrity...");
  if (receivedHash != hash)
  {
    Hint("($fileNum|$numOfFiles) '$fileName' MD5 hash doesn't match, integrity compromised\nExpected hash:   $receivedHash\nCalculated hash: $hash");
    return false;
  }
  Suc("($fileNum|$numOfFiles) Passed integrity check MD5: $hash '$fileName'");
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

Future<List<List<String>>> ReceiveFile(ServerSocket server, String path, int keepFiles) async
{
  ProgressBar.Init();
  FileIO file = FileIO();
  bool finished = false;
  bool isFolder = false;
  int bytes = 0;
  int remaining = 1;
  int numOfFiles = 0;
  int numOfFilesTotal = 0;
  const int hashSize = 32;
  String receivedHash = ""; // will be used to store some other stuff as well
  String fileName = "";
  AccumulatorSink<Digest> hashOut = AccumulatorSink<Digest>();
  ByteConversionSink hashIn = md5.startChunkedConversion(hashOut);
  List<List<String>> fileHashValues = [];

  server.listen((Socket socket) async
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
        numOfFilesTotal = numOfFiles;
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
        try { bytes = int.parse(receivedHash.substring(0, receivedHash.indexOf("|"))) + hashSize; } // -1 = empty folder
        on FormatException catch(e) { Err("Failed to parse size header of message \"${e.source}\" at character ${e.offset} reason: ${e.message}"); }
        remaining = bytes;
        receivedHash = "";
        if (bytes == hashSize-1)
        {
          FileIO.CreateDirs(fileName);
          remaining = hashSize;
        }
        else if (!file.Open(fileName, FileMode.write)) remaining = 0;
        Ver("Bytes to receive: $remaining");
      }


      int toReceive = remaining - data.length < 0 ? remaining : data.length;
      if (remaining - toReceive < hashSize) // receiving hash in total or at least partially
      {
        if (toReceive > hashSize)
        {
          int dataSize = toReceive - hashSize;
          hashIn.addSlice(data, 0, dataSize, false);
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
        hashIn.addSlice(data, 0, toReceive, false);
        file.WriteChunk(data, toReceive);
      }
      remaining -= toReceive;
      ProgressBar.Show(bytes - remaining, bytes);


      if (remaining <= 0) // less than should never happen but just in case
      {
        ProgressBar.Init();
        receivedHash = receivedHash.substring(receivedHash.length - hashSize);
        hashIn.close();
        if (!CheckIntegrity(receivedHash, hashOut.events.single.toString(), fileName, fileHashValues.length+1, numOfFilesTotal))
        {
          // 0 ask, 1 keep, 2 delete
          if ((keepFiles == 0 && Promt("Checksums don't match do you want to delete the file? [Y|N]: "))) file.Delete();
          else if (keepFiles == 2) file.Delete();
        }
        else file.Close();
        if (file.Exists()) fileHashValues.add([fileName, receivedHash]);

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
          hashOut = AccumulatorSink<Digest>();
          hashIn = md5.startChunkedConversion(hashOut);
          socket.add([1]);
          await socket.flush();
        }
      }
    }, onError: OnReceiverError, onDone: (){ socket.destroy(); finished = true; });
  }, onError: OnReceiverError);

  while (!finished) await Future.delayed(Duration(milliseconds: 200));
  return fileHashValues;
}

Future<void> VerifyWrittenFiles(List<List<String>> fileHashValues) async
{
  int idx = 0;
  int correctFiles = fileHashValues.length;
  Log("\n=======================Verifying=======================");
  for (var pair in fileHashValues)
  {
    ProgressBar.Init();
    idx++;
    FileIO file = FileIO();
    if(FileIO.IsDirectory(pair[0]) || !file.Open(pair[0], FileMode.read)) continue;

    final int totalSize = file.Size();
    int bytes = totalSize;

    AccumulatorSink<Digest> hashOut = AccumulatorSink<Digest>();
    final ByteConversionSink hashIn = md5.startChunkedConversion(hashOut);
    while (bytes > 0)
    {
      Uint8List buffer = file.ReadChunk(FileIO.Threshold);
      ProgressBar.Show(totalSize - bytes, totalSize);
      hashIn.add(buffer);
      bytes -= buffer.length;
    }

    file.Close();
    hashIn.close();
    final hashString = hashOut.events.single.toString();
    if(!CheckIntegrity(pair[1], hashString, pair[0], idx, fileHashValues.length)) correctFiles--;
  }
  Log("Correct files: $correctFiles, corrupted files ${fileHashValues.length - correctFiles}");
}

Future<ServerSocket?> SetupSocketReceiver(int port) async
{
  Ver("Receiver");
  try
  {
    ServerSocket server = await ServerSocket.bind(InternetAddress.anyIPv6, port);
    Ver("Connected");
    return server;
  }
  on SocketException catch(e)
  {
    Err("Failed to bind socket to port $port reason: ${e.message}");
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

Future<void> FindSender() async
{
  try
  {
    final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 30000);

    bool finished = false;
    udpSocket.listen((event)
    {
      if (event != RawSocketEvent.read) return;
      final datagram = udpSocket.receive();
      if (datagram == null) return;

      final response = String.fromCharCodes(datagram.data);
      final ipAddress = datagram.address;

      if (response == "NSHARE_DISCOVER")
      {
        Ver('Discovered device at $ipAddress offering: $response');
        udpSocket.send(ascii.encode("NSHARE_ACCEPT:${ipAddress.address}"), ipAddress, 31000);
        finished = true;
      }
    }, onDone: () => finished = true);

    while (!finished) await Future.delayed(Duration(milliseconds: 200));
    udpSocket.close();
  }
  on SocketException catch(e)
  {
    Err("Failed to bind socket, reason: ${e.message}");
    if (e.osError != null) VerErr("${e.osError}");
  }
  on ArgumentError catch(e)
  {
    Err(e.toString());
  }
}

Future<void> Receive(int port, String path, int keepFiles, bool verifyWrittenFiles, bool skipLookup) async
{
  if (!skipLookup) await FindSender();
  final ServerSocket? server = await SetupSocketReceiver(port);
  if (server == null) return;

  List<List<String>> fileHashValues = await ReceiveFile(server, path, keepFiles);
  server.close();
  if (verifyWrittenFiles) await VerifyWrittenFiles(fileHashValues);
}