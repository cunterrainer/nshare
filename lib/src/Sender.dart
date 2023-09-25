import "dart:async";
import "dart:io";
import "dart:convert";
import "dart:typed_data";

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';

import "Log.dart";
import "FileIO.dart";
import "ProgressBar.dart";

Future<void> SendFile(Socket socket, String path, int pathStart, int fileNum, int numOfFiles) async
{
  ProgressBar.Init();
  final FileIO file = FileIO();
  if (!file.Open(path, FileMode.read)) return;
  final int totalSize = file.Size();
  int bytes = totalSize;
  socket.add(ascii.encode("${path.substring(pathStart)}|$bytes|"));
  Ver("Bytes to send: $totalSize");

  AccumulatorSink<Digest> hashOut = AccumulatorSink<Digest>();
  final ByteConversionSink hashIn = md5.startChunkedConversion(hashOut);
  while (bytes > 0)
  {
    Uint8List buffer = file.ReadChunk(FileIO.Threshold);
    ProgressBar.Show(totalSize - bytes, totalSize);
    hashIn.add(buffer);
    socket.add(buffer);
    await socket.flush();
    bytes -= buffer.length;
  }

  file.Close();
  hashIn.close();
  final hashString = hashOut.events.single.toString();
  Log("($fileNum|$numOfFiles) $hashString '${path.substring(pathStart)}'");
  socket.add(ascii.encode(hashString));
}


Future<void> SendDirectory(Socket socket, List<List<dynamic>> files, int pathStart) async
{
  bool finished = false;
  socket.listen((event) { finished = true; }, onError: (error){}, onDone: (){finished = true;} ); // receiver writes one byte to indicate it's ready for the next send

  try
  {
    int idx = 0;
    for (List<dynamic> path in files)
    {
      ++idx;
      if (path[1] == false) await SendFile(socket, path[0], pathStart, idx, files.length);
      else // is an empty folder
      {
        Ver("Sending empty folder: ${path[0]}");
        socket.add(ascii.encode("${path[0].substring(pathStart)}|-1|d41d8cd98f00b204e9800998ecf8427e")); // empty MD5 hash
      }
      await socket.flush();
      while (!finished) await Future.delayed(Duration(milliseconds: 200));
      finished = false;
    }
  }
  on SocketException catch(e)
  {
    Err("Failed to send data (${e.message})");
    if (e.osError != null) VerErr("${e.osError}");
  }
}


Future<void> Send(String ip, int port, String path, bool skipLookup, int discoveryPort, int bindPort) async
{
  // structure: 13|filename|10|ooooooooood41d8cd98f00b204e9800998ecf8427e
  //            ^ 1 = folder, 0 = single file
  //             ^ number of files (will be 1 if not a folder) (These two are only on the first send)
  //                        ^ bytes in next file (if -1 it's an empty directory)
  //                           ^ start of bytes
  //                                         ^ start of hash (32 bytes)
  // if it's a folder then filename is relative to the folder
  if (FileIO.IsEmptyDir(path))
  {
    Err("Can't send an empty directory");
    return;
  }

  String seperator = path.contains("/") ? "/" : "\\";
  path = path.endsWith(seperator) ? path.substring(0, path.length-1) : path;
  final parts = path.split(seperator);
  String tmp = parts.lastWhere((element) => element.isNotEmpty);

  if (!skipLookup)
  {
    ip = await FindReceiver(ip, discoveryPort, bindPort);
    if (ip == "") return;
  }
  Socket? socket = await SetupSocketSender(ip, port);
  if (socket == null) return;

  if (FileIO.IsDirectory(path))
  {
    final list = FileIO.GetDirectoryContent(path);
    socket.add(ascii.encode("1${list.length}|"));
    await SendDirectory(socket, list, path.length-tmp.length);
  }
  else
  {
    socket.add(ascii.encode("01|"));
    final List<List<dynamic>> list = [[path.replaceAll("\\", "/"), false]]; // create dummy directory list
    await SendDirectory(socket, list, path.length-tmp.length);
  }
  socket.destroy();
}


Future<String> FindReceiver(String ipOut, int discoveryPort, int bindPort) async
{
  Ver("Find receiver, discovery port: $discoveryPort, bind port: $bindPort");
  try
  {
    final broadcastAddress = InternetAddress(ipOut.isEmpty ? '255.255.255.255' : ipOut);
    final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, bindPort);

    String ip = "";
    bool finished = false;
    udpSocket.listen((event)
    {
      if (event != RawSocketEvent.read) return;
      final datagram = udpSocket.receive();
      if (datagram == null) return;

      final response = String.fromCharCodes(datagram.data).split(":");
      final ipAddress = datagram.address;

      if (response[0] == "NSHARE_ACCEPT")
      {
        Ver('Discovered device at $ipAddress offering: ${response[0]}');
        ip = ipAddress.address == response[1] ? "127.0.0.1" : ipAddress.address;
        finished = true;
      }
    }, onDone: () => finished = true);

    udpSocket.broadcastEnabled = ipOut.isEmpty;
    while (!finished)
    {
      udpSocket.send(ascii.encode("NSHARE_DISCOVER"), broadcastAddress, discoveryPort);
      await Future.delayed(Duration(milliseconds: 200));
    }
    udpSocket.close();
    return ip;
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
  return "";
}


Future<Socket?> SetupSocketSender(String ip, int port) async
{
  Ver("Sender");
  try
  {
    Socket socket = await Socket.connect(ip, port);
    Ver("Connected");
    return socket;
  }
  on SocketException catch(e)
  {
    Err("Failed to connect to $ip on port $port reason: ${e.message}");
    if (e.osError != null) VerErr("${e.osError}");
  }
  on ArgumentError catch(e)
  {
    Err(e.toString());
  }
  catch(e)
  {
    Err("Unknown exception: $e");
  }
  return null;
}