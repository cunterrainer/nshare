import "dart:typed_data";
import 'dart:convert';
import "dart:async";
import "dart:core";
import "dart:io";

import "Log.dart";
import "Hash.dart";

void OnReceiverError(Object error, StackTrace st)
{
  Err('$error');
  Err('Stack Trace:\n$st');
}

Future<void> Receive() async
{
  Ver("Receiver");
  bool finished = false;

  try
  {
    ServerSocket server = await ServerSocket.bind("127.0.0.1", 5300);

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
          bytes = int.parse(str.substring(0, str.indexOf("|")));
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
    await server.close();
  } catch (e) {
    Err("$e");
  }
}