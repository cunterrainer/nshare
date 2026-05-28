import "dart:async";
import "dart:io";
import "dart:typed_data";
import "dart:convert";

import "package:crypto/crypto.dart";

import "FileIO.dart";
import "Log.dart";
import "ProgressBar.dart";
import "Protocol.dart";
import "Hashing.dart";
import "package:path/path.dart" as path;

Future<void> Send(String ip, int port, String inputPath, bool skipLookup, int discoveryPort, int bindPort) async
{
  final absoluteRoot = File(inputPath).absolute.path;
  final basePath = path.dirname(absoluteRoot);
  final entries = await FileIO.collectEntries(absoluteRoot, basePath: basePath);

  if (!skipLookup)
  {
    ip = await FindReceiver(ip, discoveryPort, bindPort);
    if (ip.isEmpty) return;
  }

  final socket = await SetupSocketSender(ip, port);
  if (socket == null) return;

  try
  {
    for (final entry in entries)
    {
      await _sendEntry(socket, entry);
    }

    socket.add(Protocol.encodeFrame(MessageType.transferComplete, Uint8List(0)));
    await socket.flush();
  }
  finally
  {
    socket.destroy();
  }
}

Future<void> _sendEntry(Socket socket, FileEntry entry) async
{
  ProgressBar.Init();
  final fileStart = FileStartMessage(
    relativePath: entry.relativePath,
    size: entry.size,
    isDirectory: entry.isDirectory,
  );

  socket.add(Protocol.encodeFrame(MessageType.fileStart, Protocol.encodeFileStart(fileStart)));

  if (entry.isDirectory)
  {
    Ver("Sending empty folder: ${entry.relativePath}");
    socket.add(Protocol.encodeFrame(
      MessageType.fileEnd,
      Protocol.encodeFileEnd(md5.convert([]).toString()),
    ));
    await socket.flush();
    return;
  }

  final file = File(entry.absolutePath);
  final hashOut = DigestAccumulator();
  final hashIn = md5.startChunkedConversion(hashOut);
  int bytesSent = 0;

  await for (final chunk in file.openRead())
  {
    final bytes = Uint8List.fromList(chunk);
    hashIn.add(bytes);
    bytesSent += chunk.length;
    ProgressBar.Show(bytesSent, entry.size);
    socket.add(Protocol.encodeFrame(MessageType.fileChunk, bytes));
  }

  hashIn.close();
  final hashString = hashOut.events.single.toString();
  Log("${hashString} '${entry.relativePath}'");
  socket.add(Protocol.encodeFrame(MessageType.fileEnd, Protocol.encodeFileEnd(hashString)));
  await socket.flush();
}


Future<String> FindReceiver(String ipOut, int discoveryPort, int bindPort) async
{
  Log("Find receiver, discovery port: $discoveryPort, bind port: $bindPort");
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
        Log('Discovered device at $ipAddress offering: ${response[0]}');
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
