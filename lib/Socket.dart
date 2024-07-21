library Socket;

import "dart:io";

class Socket
{
  String? Connect(String ipAddress, String portString)
  {
    InternetAddress ip;
    int port;

    try
    {
      ip = InternetAddress(ipAddress.trim());
    }
    catch (e)
    {
      return "Invalid IP address: '" + ipAddress + "'";
    }

    try
    {
      port = int.parse(portString);
    }
    catch (e)
    {
      return "Invalid port number: '" + portString + "'";
    }

    return null;
  }
}