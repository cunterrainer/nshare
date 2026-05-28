import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:crypto/crypto.dart";
import "package:path/path.dart" as path;

import "Config.dart";
import "FileIO.dart";
import "Log.dart";
import "ProgressBar.dart";
import "Protocol.dart";
import "Hashing.dart";

bool checkIntegrity(String receivedHash, String hash, String fileName)
{
  Ver("Checking file integrity...");
  if (receivedHash != hash)
  {
    Hint("'$fileName' MD5 hash doesn't match, integrity compromised\nExpected hash:   $receivedHash\nCalculated hash: $hash");
    return false;
  }
  Suc("Passed integrity check MD5: $hash '$fileName'");
  return true;
}

bool promptYesNo(String msg)
{
  do
  {
    stdout.write(msg);
    final input = stdin.readLineSync()?.toLowerCase().trim() ?? "";
    if (input == "y" || input == "yes") return true;
    if (input == "n" || input == "no") return false;
  } while (true);
}

Future<ServerSocket?> setupSocketReceiver(int port) async
{
  Ver("Receiver");
  try
  {
    final server = await ServerSocket.bind(InternetAddress.anyIPv6, port);
    Ver("Connected");
    return server;
  }
  on SocketException catch (e)
  {
    Err("Failed to bind socket to port $port reason: ${e.message}");
    if (e.osError != null) VerErr("${e.osError}");
  }
  on ArgumentError catch (e)
  {
    Err(e.toString());
  }
  catch (e)
  {
    Err("Unknown exception: $e");
  }
  return null;
}

Future<void> FindSender(int discoveryPort, int bindPort) async
{
  Log("Find sender, discovery port: $discoveryPort, bind port: $bindPort");
  try
  {
    final udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, bindPort);

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
        Log('Discovered device at $ipAddress offering: $response');
        udpSocket.send(ascii.encode("NSHARE_ACCEPT:${ipAddress.address}"), ipAddress, discoveryPort);
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

Future<void> Receive(int port, String outputPath, KeepFilesMode keepFiles, bool verifyWrittenFiles, bool skipLookup, int discoveryPort, int bindPort) async
{
  if (!skipLookup) await FindSender(discoveryPort, bindPort);
  final server = await setupSocketReceiver(port);
  if (server == null) return;

  final fileHashes = <List<String>>[];
  try
  {
    final socket = await server.first;
    await _receiveStream(socket, outputPath, keepFiles, fileHashes);
  }
  finally
  {
    await server.close();
  }

  if (verifyWrittenFiles) await verifyFiles(fileHashes);
}

Future<void> _receiveStream(Socket socket, String outputPath, KeepFilesMode keepFiles, List<List<String>> fileHashes) async
{
  final parser = FrameParser();
  final session = _ReceiverSession(outputPath, keepFiles, fileHashes);

  try
  {
    await for (final data in socket)
    {
      final frames = parser.add(data);
      for (final frame in frames)
      {
        if (frame.version != kProtocolVersion)
        {
          throw StateError("Unsupported protocol version: ${frame.version}");
        }

        await session.handleFrame(frame);
        if (session.isComplete)
        {
          socket.destroy();
          return;
        }
      }
    }
  }
  catch (e, st)
  {
    Err("Error receiving bytes: $e");
    VerErr("Stack Trace:\n$st");
  }
}

Future<void> verifyFiles(List<List<String>> fileHashValues) async
{
  int idx = 0;
  int correctFiles = fileHashValues.length;
  Log("\n=======================Verifying=======================");

  for (final pair in fileHashValues)
  {
    ProgressBar.Init();
    idx++;
    final file = File(pair[0]);
    if (await FileSystemEntity.isDirectory(pair[0]) || !await file.exists()) continue;

    final totalSize = await file.length();
    int bytesRead = 0;
    final hashOut = DigestAccumulator();
    final hashIn = md5.startChunkedConversion(hashOut);

    await for (final chunk in file.openRead())
    {
      hashIn.add(chunk);
      bytesRead += chunk.length;
      ProgressBar.Show(bytesRead, totalSize);
    }

    hashIn.close();
    final hashString = hashOut.events.single.toString();
    if (!checkIntegrity(pair[1], hashString, pair[0])) correctFiles--;
  }

  Log("Correct files: $correctFiles, corrupted files ${fileHashValues.length - correctFiles}");
}

class _ReceiverSession
{
  _ReceiverSession(this.outputRoot, this.keepFiles, this.fileHashes);

  final String outputRoot;
  final KeepFilesMode keepFiles;
  final List<List<String>> fileHashes;

  FileWriter? _writer;
  String _currentPath = "";
  bool _currentIsDir = false;
  int _currentSize = 0;
  int _bytesReceived = 0;
  DigestAccumulator? _hashOut;
  ByteConversionSink? _hashIn;
  bool isComplete = false;

  Future<void> handleFrame(ProtocolFrame frame) async
  {
    switch (frame.type)
    {
      case MessageType.fileStart:
        await _handleFileStart(Protocol.decodeFileStart(frame.payload));
        break;
      case MessageType.fileChunk:
        await _handleFileChunk(frame.payload);
        break;
      case MessageType.fileEnd:
        await _handleFileEnd(Protocol.decodeFileEnd(frame.payload));
        break;
      case MessageType.transferComplete:
        isComplete = true;
        break;
    }
  }

  Future<void> _handleFileStart(FileStartMessage msg) async
  {
    _currentPath = _resolveOutputPath(outputRoot, msg.relativePath);
    _currentIsDir = msg.isDirectory;
    _currentSize = msg.size;
    _bytesReceived = 0;
    ProgressBar.Init();

    _hashOut = DigestAccumulator();
    _hashIn = md5.startChunkedConversion(_hashOut!);

    if (_currentIsDir)
    {
      await FileIO.ensureDir(_currentPath);
      return;
    }

    await FileIO.ensureParentDir(_currentPath);
    _writer = await FileWriter.open(_currentPath);
  }

  Future<void> _handleFileChunk(Uint8List data) async
  {
    if (_currentIsDir) return;
    if (_hashIn == null || _writer == null)
    {
      throw StateError("Received file chunk without active file");
    }

    _hashIn!.add(data);
    await _writer!.write(data, data.length);
    _bytesReceived += data.length;
    ProgressBar.Show(_bytesReceived, _currentSize);
  }

  Future<void> _handleFileEnd(String receivedHash) async
  {
    _hashIn?.close();
    final computedHash = _hashOut?.events.single.toString() ?? "";

    final integrityOk = checkIntegrity(receivedHash, computedHash, _currentPath);
    if (!_currentIsDir)
    {
      if (!integrityOk)
      {
        final shouldDelete = keepFiles == KeepFilesMode.delete ||
            (keepFiles == KeepFilesMode.ask &&
                promptYesNo("Checksums don't match. Delete the file? [Y|N]: "));
        if (shouldDelete) await _deleteCurrentFile();
      }

      if (File(_currentPath).existsSync())
      {
        await _writer?.close();
        fileHashes.add([_currentPath, receivedHash]);
      }
    }

    _resetState();
  }

  Future<void> _deleteCurrentFile() async
  {
    if (_writer == null) return;
    await _writer!.delete();
  }

  void _resetState()
  {
    _writer = null;
    _currentPath = "";
    _currentIsDir = false;
    _currentSize = 0;
    _bytesReceived = 0;
    _hashOut = null;
    _hashIn = null;
  }

  String _resolveOutputPath(String outputRoot, String relativePath)
  {
    final safeRelative = FileIO.sanitizeRelativePath(relativePath);
    if (outputRoot.isEmpty) return safeRelative;
    return path.join(outputRoot, safeRelative);
  }
}
