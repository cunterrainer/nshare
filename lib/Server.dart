library Socket;

import "dart:io";

class ReceiverServer
{
  late ServerSocket _Server;
  bool _Connected = false;

  Future<String?> Connect(String portString) async
  {
    int? port = _StringToInt(portString);
    if (port == null)
    {
      return "Invalid port: '$portString'";
    }

    try
    {
      _Server = await ServerSocket.bind(InternetAddress.anyIPv6, port);
      _Connected = true;
    }
    on SocketException catch(e)
    {
      return "Failed to bind socket to port $port, reason: ${e.message}";
    }
    on ArgumentError catch(e)
    {
      return e.toString();
    }
    catch(e)
    {
      return "Unknown exception occurred: $e";
    }
    return null;
  }


  void Disconnect()
  {
    _Server.close();
    _Connected = false;
  }


  bool IsConnected()
  {
    return _Connected;
  }
}


class SenderSocket
{
  late Socket _Socket;
  bool _Connected = false;

  Future<String?> Connect(String ipAddress, String portString) async
  {
    int? port = _StringToInt(portString);
    InternetAddress? ip = _StringToIP(ipAddress);
    if (ip == null)
      return "Invalid ip address: '$ipAddress'";
    else if (port == null)
      return "Invalid port: '$portString'";

    try
    {
      _Socket = await Socket.connect(ip, port);
      _Connected = true;
    }
    on SocketException catch(e)
    {
      return "Failed to connect to $ip on port $port reason: ${e.message}";
    }
    on ArgumentError catch(e)
    {
      return e.toString();
    }
    catch(e)
    {
      return "Unknown exception occurred: $e";
    }
    return null;
  }


  void Disconnect()
  {
    _Socket.close();
    _Connected = false;
  }


  bool IsConnected()
  {
    return _Connected;
  }
}


int? _StringToInt(String str)
{
  try
  {
    int num = int.parse(str.trim());
    return num;
  }
  catch (e)
  {
    return null;
  }
}


InternetAddress? _StringToIP(String str)
{
  try
  {
    InternetAddress ip = InternetAddress(str.trim());
    return ip;
  }
  catch (e)
  {
    return null;
  }
}