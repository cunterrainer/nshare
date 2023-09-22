import "dart:typed_data";
import 'dart:convert';
import "dart:async";
import "dart:core";
import "dart:io";

import "Log.dart";
import "Hash.dart";

void OnReceiverError(Object error, StackTrace st)
{
  Err('Error receiving bytes: $error');
  VerErr('Stack Trace:\n$st');
}

Future<void> Receive(String ip, int port) async
{
  Ver("Receiver");
  bool finished = false;
  ServerSocket? server;

  try
  {
    server = await ServerSocket.bind(ip, port);

    int bytes = 0;
    int remaining = 1;
    String str = "";
    Sha256 sha = Sha256();
    server.listen((Socket socket)
    {
      socket.listen((Uint8List data)
      {
        if (bytes == 0)
        {
          str += ascii.decode(data);
          if (!str.contains ('|')) return;

          data = data.sublist(data.indexOf(124) + 1); // '|'
          try { bytes = int.parse(str.substring(0, str.indexOf("|"))); }
          on FormatException catch(e) { Err("Failed to parse size header of message \"${e.source}\" reason: ${e.message} (at character ${e.offset})"); }
          remaining = bytes;
          str = "";
        }

        int toReceive = remaining - data.length < 0 ? remaining : data.length;
        sha.UpdateBinary(data, toReceive);
        remaining -= toReceive;

        if (remaining == 0)
        {
          sha.Finalize();
          print(sha.Hexdigest());
          finished = true;
          socket.destroy();
        }
      }, onError: OnReceiverError);
    }, onError: OnReceiverError);

    Ver("Server socket is set up and listening");
    while (!finished) await Future.delayed(Duration(milliseconds: 100));
  }
  on SocketException catch(e)
  {
    Err("Failed to bind socket to $ip on port $port reason: ${e.message} ${e.osError ?? ""}");
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